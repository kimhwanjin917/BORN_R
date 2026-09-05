/**
 * Builds and persists Recommendation__c rows for accounts (docs/55 §3.3):
 *  - 크로스셀: family with no deal and wallet > 0 → expected = wallet × target share
 *  - 업셀: family with a deal and share below the upsell threshold → expected = wallet × (threshold − share)
 *  - 만기차환: a family that already holds a deal whose money matures inside the window (or matured
 *    inside the trailing window) is promoted to rank 1, and its expected amount is the maturing
 *    balance itself. This outranks the upsell threshold — a customer we already serve well is still
 *    the one to call when their money comes due.
 * Ranking key = maturity deadline for rollovers, then whitespace × score. Max 3 per account.
 * Reasons are template-assembled (no LLM).
 *
 * Persistence keeps history: open '제안됨' rows generated today are replaced; rows in any other
 * status (기회생성/수주/실패/보류) are never touched. Only Recommendation__c is written.
 */
public with sharing class RadarRecommendationService {
    public static final String TYPE_UPSELL = '업셀';
    public static final String TYPE_CROSS = '크로스셀';
    public static final String TYPE_ROLLOVER = '만기차환';
    public static final String STATUS_PROPOSED = '제안됨';
    public static final String SOURCE_RADAR = '레이더';
    private static final Integer MAX_PER_ACCOUNT = 3;
    private static final Map<String, String> PRODUCT_LABELS = new Map<String, String>{
        'RP' => 'RP', '자금운용' => '법인 자금운용', '채권' => '회사채', '퇴직연금' => '퇴직연금', 'IPO' => 'IPO 주선'
    };

    /** In-memory recommendation before persistence. */
    public class Candidate implements Comparable {
        public Id accountId;
        public String family;
        public String type;
        public Decimal score;
        public Decimal wallet;
        public Decimal ourBalance;
        public Decimal share;
        public Decimal whitespace;
        public Decimal expectedAmount;
        public String basis;
        public String reason;
        public String scoreDetail;
        public Boolean promoted = false;
        public Integer maturityDays;   // days until maturity; negative once it has passed

        public Integer compareTo(Object other) {
            Candidate that = (Candidate) other;
            if (this.promoted != that.promoted) {
                return this.promoted ? -1 : 1;
            }
            // Among rollovers the deadline decides, not the size: a maturity we already missed comes
            // first, then the nearest one. Amount only breaks ties between equally urgent deals.
            if (this.maturityDays != null && that.maturityDays != null && this.maturityDays != that.maturityDays) {
                return this.maturityDays < that.maturityDays ? -1 : 1;
            }
            Decimal mine = this.whitespace * this.score;
            Decimal theirs = that.whitespace * that.score;
            return mine == theirs ? 0 : (mine > theirs ? -1 : 1);
        }
    }

    /**
     * Regenerates today's proposals for the accounts and returns the persisted rows.
     * @param accountIds accounts to (re)score
     * @return inserted Recommendation__c records (with Ids)
     */
    public static List<Recommendation__c> regenerate(Set<Id> accountIds) {
        if (accountIds == null || accountIds.isEmpty()) {
            return new List<Recommendation__c>();
        }
        Map<Id, WalletShareService.AccountWallet> wallets = WalletShareService.compute(accountIds, Date.today());
        Map<Id, Map<String, RadarScoreService.Score>> scores = RadarScoreService.compute(wallets);
        Map<String, Id> productIdByFamily = loadProductIds();
        Set<String> inProgress = loadInProgressFamilies(accountIds);
        Map<Id, Id> ownerByAccount = loadAccountOwners(accountIds);

        List<Recommendation__c> toInsert = new List<Recommendation__c>();
        for (Id accountId : wallets.keySet()) {
            List<Candidate> candidates = buildCandidates(wallets.get(accountId), scores.get(accountId));
            candidates.sort();
            Integer rank = 0;
            for (Candidate candidate : candidates) {
                if (rank >= MAX_PER_ACCOUNT) {
                    break;
                }
                if (inProgress.contains(accountId + '|' + candidate.family)) {
                    continue; // an opportunity was already created from an earlier proposal for this family
                }
                rank++;
                toInsert.add(toRecord(candidate, rank, productIdByFamily.get(candidate.family), ownerByAccount.get(accountId)));
            }
        }
        persist(accountIds, toInsert);
        return toInsert;
    }

    /** Builds unsorted candidates for one account from its wallet and scores. */
    public static List<Candidate> buildCandidates(WalletShareService.AccountWallet wallet, Map<String, RadarScoreService.Score> scoresByFamily) {
        List<Candidate> candidates = new List<Candidate>();
        if (wallet == null || scoresByFamily == null) {
            return candidates;
        }
        // familyWallet.wallet is already the addressable slice (reported × Target_Share_Pct), so the
        // target share must NOT be applied a second time here: a cross-sell aims at that whole slice.
        Decimal upsellThreshold = RadarSettings.upsellFillTargetPct() / 100;

        for (WalletShareService.FamilyWallet familyWallet : wallet.byFamily.values()) {
            if (familyWallet.wallet == null || familyWallet.wallet <= 0) {
                continue;
            }
            RadarScoreService.Score score = scoresByFamily.get(familyWallet.family);
            Candidate candidate = new Candidate();
            candidate.accountId = wallet.accountId;
            candidate.family = familyWallet.family;
            candidate.score = score.total;
            candidate.wallet = familyWallet.wallet;
            candidate.ourBalance = familyWallet.ourBalance;
            candidate.share = familyWallet.share ?? 0;
            candidate.whitespace = Math.max(familyWallet.wallet - familyWallet.ourBalance, 0);
            candidate.basis = familyWallet.basis;
            candidate.scoreDetail = JSON.serialize(score);

            // A rollover needs money of ours to roll: the family must already hold a deal.
            Boolean isRollover = familyWallet.hasDeal && (score.maturingOn != null || score.maturedOn != null);

            if (!familyWallet.hasDeal) {
                candidate.type = TYPE_CROSS;
                candidate.expectedAmount = candidate.whitespace;
            } else if (candidate.share < upsellThreshold) {
                candidate.type = TYPE_UPSELL;
                candidate.expectedAmount = familyWallet.wallet * (upsellThreshold - candidate.share);
            } else if (isRollover) {
                // Our share is already past the upsell bar, but the money is coming due. Dropping the
                // candidate here would hide exactly the customer we most need to re-approach.
                // Type and amount are both set by the rollover block below.
                candidate.expectedAmount = 0;
            } else {
                continue;
            }

            if (isRollover) {
                candidate.type = TYPE_ROLLOVER;
                candidate.promoted = true;
                candidate.maturityDays = score.maturityDays;
                // Roll over what is actually maturing rather than a share-gap the customer never had.
                Decimal rollover = (familyWallet.maturingAmount ?? 0) + (familyWallet.maturedAmount ?? 0);
                if (rollover > 0) {
                    candidate.expectedAmount = rollover;
                }
            }
            candidate.reason = buildReason(wallet, familyWallet, score, candidate);
            candidates.add(candidate);
        }
        return dedupeCashWallet(candidates);
    }

    /**
     * RP and 자금운용 draw on the same cash wallet, so at most one of them is proposed:
     * a maturing family wins first, then the family that already has a deal, otherwise RP.
     */
    private static List<Candidate> dedupeCashWallet(List<Candidate> candidates) {
        Candidate rp;
        Candidate cashMgmt;
        for (Candidate candidate : candidates) {
            if (candidate.family == WalletShareService.FAMILY_RP) {
                rp = candidate;
            } else if (candidate.family == WalletShareService.FAMILY_CASH_MGMT) {
                cashMgmt = candidate;
            }
        }
        if (rp == null || cashMgmt == null) {
            return candidates;
        }
        Candidate loser;
        if (rp.promoted != cashMgmt.promoted) {
            loser = rp.promoted ? cashMgmt : rp;   // never discard the family whose money is coming due
        } else {
            loser = (cashMgmt.type != TYPE_CROSS && rp.type == TYPE_CROSS) ? rp : cashMgmt;
        }
        List<Candidate> kept = new List<Candidate>();
        for (Candidate candidate : candidates) {
            if (candidate !== loser) {
                kept.add(candidate);
            }
        }
        return kept;
    }

    private static String buildReason(WalletShareService.AccountWallet wallet, WalletShareService.FamilyWallet familyWallet,
                                      RadarScoreService.Score score, Candidate candidate) {
        List<String> parts = new List<String>();
        parts.add(score.similarWonNote);
        parts.add(familyWallet.basis + ' ' + toEok(familyWallet.reportedWallet) + '억 → 접근가능 ' + toEok(familyWallet.wallet) +
            '억 중 우리 ' + toEok(familyWallet.ourBalance) + '억(' + (candidate.share * 100).setScale(1) + '%)');
        if (score.signalNote != null) {
            parts.add(score.signalNote);
        }
        if (score.financialNote != null) {
            parts.add(score.financialNote);
        }
        String label = PRODUCT_LABELS.get(candidate.family);
        String action;
        if (candidate.type == TYPE_ROLLOVER) {
            action = (candidate.maturityDays != null && candidate.maturityDays < 0)
                ? '만기 자금 재유치(' + label + ') 제안'
                : '만기 자금 재예치(' + label + ') 제안';
        } else {
            action = candidate.type == TYPE_CROSS ? label + ' 신규 제안' : label + ' 비중 확대 제안';
        }
        return String.join(parts, ' · ') + ' → ' + action + ', 예상 ' + toEok(candidate.expectedAmount) + '억';
    }

    private static String toEok(Decimal amount) {
        return amount == null ? '0' : (amount / 100000000).setScale(0, RoundingMode.HALF_UP).format();
    }

    /**
     * 고객사 담당자를 추천 이력의 소유자로 쓰기 위해 미리 읽어둔다.
     *
     * 소유자를 지정하지 않으면 Salesforce 가 "레이더를 실행한 사람"을 소유자로 넣는다.
     * 레이더는 전체 고객을 훑을 수 있어서, 그러면 남의 고객 추천이 실행자 소유가 되고
     * 소유권이 담당 관계를 전혀 반영하지 못한다. 추천은 그 고객에 대한 정보이므로
     * 담당 RM 이 소유해야 한다.
     */
    private static Map<Id, Id> loadAccountOwners(Set<Id> accountIds) {
        Map<Id, Id> ownerByAccount = new Map<Id, Id>();
        for (Account account : [SELECT Id, OwnerId FROM Account WHERE Id IN :accountIds]) {
            ownerByAccount.put(account.Id, account.OwnerId);
        }
        return ownerByAccount;
    }

    private static Recommendation__c toRecord(Candidate candidate, Integer rank, Id productId, Id accountOwnerId) {
        Recommendation__c record = buildRecord(candidate, rank, productId);
        // 담당자를 못 찾은 경우에는 손대지 않는다 — null 을 넣으면 삽입 자체가 실패한다
        if (accountOwnerId != null) {
            record.OwnerId = accountOwnerId;
        }
        return record;
    }

    private static Recommendation__c buildRecord(Candidate candidate, Integer rank, Id productId) {
        return new Recommendation__c(
            Account__c = candidate.accountId,
            Product__c = productId,
            Type__c = candidate.type,
            Status__c = STATUS_PROPOSED,
            Source__c = SOURCE_RADAR,
            Score__c = candidate.score,
            Score_Detail__c = candidate.scoreDetail,
            Wallet_Amount__c = candidate.wallet,
            Our_Balance__c = candidate.ourBalance,
            Wallet_Share__c = (candidate.share * 100).setScale(1),
            Whitespace_Amount__c = candidate.whitespace,
            Expected_Amount__c = candidate.expectedAmount,
            Wallet_Basis__c = candidate.basis,
            Reason__c = candidate.reason,
            Rank__c = rank,
            Generated_At__c = System.now()
        );
    }

    /** account|family pairs that already have a radar recommendation converted into an open opportunity. */
    private static Set<String> loadInProgressFamilies(Set<Id> accountIds) {
        Set<String> keys = new Set<String>();
        for (Recommendation__c rec : [
            SELECT Account__c, Product__r.Family FROM Recommendation__c
            WHERE Account__c IN :accountIds AND Source__c = :SOURCE_RADAR
              AND Status__c = :RecommendationOutcomeService.STATUS_CREATED
            WITH USER_MODE LIMIT 10000
        ]) {
            keys.add(rec.Account__c + '|' + rec.Product__r.Family);
        }
        return keys;
    }

    /** Representative product per family: the generic product (PRODUCT_LABELS name) if it exists, else the first active one by name. */
    private static Map<String, Id> loadProductIds() {
        Map<String, Id> productIdByFamily = new Map<String, Id>();
        Map<String, String> preferredNameByFamily = new Map<String, String>{
            'RP' => 'RP (환매조건부채권)', '자금운용' => '법인 자금운용', '채권' => '회사채', '퇴직연금' => '퇴직연금', 'IPO' => 'IPO 주선'
        };
        for (Product2 product : [
            SELECT Id, Name, Family FROM Product2 WHERE IsActive = true AND Family != null WITH USER_MODE ORDER BY Name LIMIT 500
        ]) {
            if (product.Name == preferredNameByFamily.get(product.Family)) {
                productIdByFamily.put(product.Family, product.Id);
            } else if (!productIdByFamily.containsKey(product.Family)) {
                productIdByFamily.put(product.Family, product.Id);
            }
        }
        return productIdByFamily;
    }

    private static void persist(Set<Id> accountIds, List<Recommendation__c> toInsert) {
        List<Recommendation__c> stale = [
            SELECT Id FROM Recommendation__c
            WHERE Account__c IN :accountIds AND Status__c = :STATUS_PROPOSED AND Source__c = :SOURCE_RADAR
            WITH USER_MODE
            LIMIT 10000
        ];
        try {
            if (!stale.isEmpty()) {
                Database.delete(stale, true, AccessLevel.USER_MODE);
            }
            if (!toInsert.isEmpty()) {
                Database.insert(toInsert, true, AccessLevel.USER_MODE);
            }
        } catch (DmlException e) {
            throw new RadarException('추천 이력 저장 실패: ' + e.getDmlMessage(0), e);
        }
    }
}