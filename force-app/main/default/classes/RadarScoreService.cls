/**
 * Computes the 0-100 "성공 가능성" score per account × product family from org data only
 * (docs/55 §3.2, revised 2026-08-27). Components and default weights:
 *  - similarWon 30 : closed-opportunity win rate for industry × family (fallback industry, fallback 50)
 *  - signal     30 : recent funding-demand signals (ExternalSignal 수주/공시 = 100, 뉴스 = 50) or a maturity
 *                    inside the window (Asset / signal maturity) = 100 — maturity only counts for cash families
 *  - financial  20 : year-over-year growth of the family wallet (cash for RP/자금운용, debt for 채권);
 *                    −20% → 0, +20% → 100, linear in between, 50 when no prior statement
 *  - priority   20 : Account.Priority_Score__c (RM priority, 0-100; 50 when empty)
 * Contact recency is NOT scored; it is exposed as lastContactDays for display only.
 *
 * Read-only: no DML. All SOQL in USER_MODE, bulk over the given accounts.
 */
public with sharing class RadarScoreService {
    private static final Integer CONTACT_WINDOW_DAYS = 90;
    private static final Decimal NO_DATA_SCORE = 50;
    private static final Decimal GROWTH_FLOOR = -0.50;
    private static final Decimal GROWTH_CEILING = 0.50;
    private static final Decimal PRIORITY_FLOOR = 40;          // Priority_Score__c seeds range 40..100 → rescale to 0..100
    private static final Map<String, Decimal> SIGNAL_BASE = new Map<String, Decimal>{ '수주' => 100, '공시' => 70, '뉴스' => 40 };
    private static final Integer MIN_SAMPLE = 3;
    private static final Decimal SHRINK_K = 2;   // pseudo-count pulling small samples toward the parent rate
    private static final Map<String, Integer> SIZE_QUARTER = new Map<String, Integer>{ '1분기' => 1, '2분기' => 2, '3분기' => 3, '4분기' => 4 };

    /** Score breakdown for one account × family. */
    public class Score {
        @AuraEnabled public Decimal total = 0;
        @AuraEnabled public Decimal similarWon = 0;
        @AuraEnabled public Decimal signal = 0;
        @AuraEnabled public Decimal financial = 0;
        @AuraEnabled public Decimal priority = 0;
        @AuraEnabled public String similarWonNote;   // e.g. '제조업×채권 Won 4/6 (67%)'
        @AuraEnabled public String signalNote;       // e.g. '9/8 RP 만기 도래'
        @AuraEnabled public String financialNote;    // e.g. '현금성 자산 전년 대비 +12%'
        @AuraEnabled public Date maturingOn;         // nearest maturity inside the window, if any
        @AuraEnabled public Integer lastContactDays; // days since last meeting note / event (null = none)
    }

    /** Pre-fetched context for one account, shared across families. */
    private class AccountContext {
        String industry;
        Decimal priorityScore;
        Date lastContact;
        Decimal bestSignal = 0;      // strongest decayed signal score in the window
        String bestSignalNote;
        Date nearestMaturity;
        WalletShareService.AccountWallet wallet;
    }

    /**
     * @param wallets output of WalletShareService.compute
     * @return scores keyed by accountId, then family
     */
    public static Map<Id, Map<String, Score>> compute(Map<Id, WalletShareService.AccountWallet> wallets) {
        Map<Id, Map<String, Score>> result = new Map<Id, Map<String, Score>>();
        if (wallets == null || wallets.isEmpty()) {
            return result;
        }
        Map<Id, AccountContext> contexts = loadContexts(wallets);
        Map<String, WonStat> wonStats = loadWonStats(contexts);

        for (Id accountId : wallets.keySet()) {
            AccountContext context = contexts.get(accountId);
            Map<String, Score> byFamily = new Map<String, Score>();
            for (String family : WalletShareService.WALLET_FAMILIES) {
                byFamily.put(family, scoreFor(context, family, wonStats));
            }
            result.put(accountId, byFamily);
        }
        return result;
    }

    /**
     * @param accountIds accounts to look up
     * @return days since the latest meeting note or event per account (absent when none)
     */
    public static Map<Id, Integer> lastContactDays(Set<Id> accountIds) {
        Map<Id, Integer> result = new Map<Id, Integer>();
        if (accountIds == null || accountIds.isEmpty()) {
            return result;
        }
        Map<Id, Date> lastByAccount = loadLastContacts(accountIds);
        for (Id accountId : lastByAccount.keySet()) {
            result.put(accountId, lastByAccount.get(accountId).daysBetween(Date.today()));
        }
        return result;
    }

    private static Score scoreFor(AccountContext context, String family, Map<String, WonStat> wonStats) {
        Score score = new Score();
        applySimilarWon(score, context, family, wonStats);
        applySignal(score, context, family);
        applyFinancial(score, context, family);
        score.priority = context.priorityScore == null ? NO_DATA_SCORE
            : (Math.min(Math.max(context.priorityScore - PRIORITY_FLOOR, 0), 100 - PRIORITY_FLOOR) / (100 - PRIORITY_FLOOR) * 100).setScale(0, RoundingMode.HALF_UP);
        score.lastContactDays = context.lastContact == null ? null : context.lastContact.daysBetween(Date.today());
        score.total = ((score.similarWon * RadarSettings.weightSimilarWon()
            + score.signal * RadarSettings.weightSignal()
            + score.financial * RadarSettings.weightFinancial()
            + score.priority * RadarSettings.weightPriority()) / 100).setScale(0, RoundingMode.HALF_UP);
        return score;
    }

    /**
     * Ladder: 업종×상품×규모 → 업종×상품 → 상품×규모 → 업종 → 전체 → 50.
     * The first level with >= MIN_SAMPLE closed deals is used; its rate is shrunk toward the next
     * populated level below it (pseudo-count SHRINK_K) so small samples avoid 0%/100% extremes.
     */
    private static void applySimilarWon(Score score, AccountContext context, String family, Map<String, WonStat> wonStats) {
        String size = context.wallet.segment;
        List<String> ladder = new List<String>{
            key3(context.industry, family, size), key3(context.industry, family, null), key3(null, family, size),
            key3(context.industry, null, null), key3(null, null, null)
        };
        Integer chosen = -1;
        for (Integer i = 0; i < ladder.size(); i++) {
            WonStat candidate = wonStats.get(ladder[i]);
            if (candidate != null && candidate.total >= MIN_SAMPLE) {
                chosen = i;
                break;
            }
        }
        if (chosen < 0) {
            score.similarWon = NO_DATA_SCORE;
            score.similarWonNote = '유사 종결 건 없음(기본 50)';
            return;
        }
        WonStat stat = wonStats.get(ladder[chosen]);
        Decimal parentRate = NO_DATA_SCORE;
        for (Integer j = chosen + 1; j < ladder.size(); j++) {
            WonStat parent = wonStats.get(ladder[j]);
            if (parent != null && parent.total > 0) {
                parentRate = parent.won * 100.0 / parent.total;
                break;
            }
        }
        Decimal shrunk = (stat.won * 100.0 + SHRINK_K * parentRate) / (stat.total + SHRINK_K);
        score.similarWon = shrunk.setScale(0, RoundingMode.HALF_UP);
        score.similarWonNote = stat.label + ' Won ' + stat.won + '/' + stat.total + ' (' + score.similarWon + '%)';
    }

    private static void applySignal(Score score, AccountContext context, String family) {
        Boolean isCashFamily = family == WalletShareService.FAMILY_RP || family == WalletShareService.FAMILY_CASH_MGMT;
        if (isCashFamily && context.nearestMaturity != null) {
            score.signal = 100;
            score.signalNote = context.nearestMaturity.format() + ' 만기 도래';
            score.maturingOn = context.nearestMaturity;
        } else if (context.bestSignal > 0) {
            score.signal = context.bestSignal;
            score.signalNote = context.bestSignalNote;
        }
    }

    private static void applyFinancial(Score score, AccountContext context, String family) {
        WalletShareService.AccountWallet wallet = context.wallet;
        Boolean isCashFamily = family == WalletShareService.FAMILY_RP || family == WalletShareService.FAMILY_CASH_MGMT;
        Decimal latest;
        Decimal prior;
        String label;
        if (isCashFamily) {
            WalletShareService.FamilyWallet cash = wallet.byFamily.get(WalletShareService.FAMILY_RP);
            latest = cash?.wallet;
            prior = wallet.priorCashWallet;
            label = '현금성 자산';
        } else if (family == WalletShareService.FAMILY_BOND) {
            latest = wallet.latestDebtWallet;
            prior = wallet.priorDebtWallet;
            label = '사채·장기차입';
        }
        if (latest == null || prior == null || prior <= 0) {
            score.financial = NO_DATA_SCORE;
            score.financialNote = label == null ? '재무 추세 미적용' : label + ' 전년 비교 불가(기본 50)';
            return;
        }
        Decimal growth = (latest - prior) / prior;
        Decimal clamped = Math.min(Math.max(growth, GROWTH_FLOOR), GROWTH_CEILING);
        score.financial = ((clamped - GROWTH_FLOOR) / (GROWTH_CEILING - GROWTH_FLOOR) * 100).setScale(0, RoundingMode.HALF_UP);
        String sign = growth >= 0 ? '+' : '';
        score.financialNote = label + ' 전년 대비 ' + sign + (growth * 100).setScale(0, RoundingMode.HALF_UP) + '%';
    }

    private static Map<Id, AccountContext> loadContexts(Map<Id, WalletShareService.AccountWallet> wallets) {
        Map<Id, AccountContext> contexts = new Map<Id, AccountContext>();
        for (WalletShareService.AccountWallet wallet : wallets.values()) {
            AccountContext context = new AccountContext();
            context.industry = wallet.industry;
            context.priorityScore = wallet.priorityScore;
            context.wallet = wallet;
            contexts.put(wallet.accountId, context);
        }
        Set<Id> accountIds = contexts.keySet();
        Date windowStart = Date.today().addDays(-CONTACT_WINDOW_DAYS);
        Date maturityEnd = Date.today().addDays(RadarSettings.maturityWindowDays());

        Map<Id, Date> lastContacts = loadLastContacts(accountIds);
        for (Id accountId : lastContacts.keySet()) {
            contexts.get(accountId).lastContact = lastContacts.get(accountId);
        }
        for (ExternalSignal__c signal : [
            SELECT Account__c, Signal_Type__c, Signal_Date__c, Maturity_Date__c
            FROM ExternalSignal__c
            WHERE Account__c IN :accountIds AND Signal_Date__c >= :windowStart
            WITH USER_MODE
            LIMIT 5000
        ]) {
            AccountContext context = contexts.get(signal.Account__c);
            Decimal base = SIGNAL_BASE.get(signal.Signal_Type__c);
            if (base != null) {
                // linear decay: today = 100% of base, CONTACT_WINDOW_DAYS ago = 50%
                Integer age = signal.Signal_Date__c == null ? CONTACT_WINDOW_DAYS : signal.Signal_Date__c.daysBetween(Date.today());
                Decimal decayed = (base * (1 - 0.5 * Math.min(Math.max(age, 0), CONTACT_WINDOW_DAYS) / CONTACT_WINDOW_DAYS)).setScale(0, RoundingMode.HALF_UP);
                if (decayed > context.bestSignal) {
                    context.bestSignal = decayed;
                    context.bestSignalNote = age + '일 전 ' + signal.Signal_Type__c + ' 신호(' + decayed + ')';
                }
            }
            if (signal.Maturity_Date__c != null && signal.Maturity_Date__c >= Date.today() && signal.Maturity_Date__c <= maturityEnd) {
                context.nearestMaturity = nearer(context.nearestMaturity, signal.Maturity_Date__c);
            }
        }
        for (Asset asset : [
            SELECT AccountId, UsageEndDate
            FROM Asset
            WHERE AccountId IN :accountIds AND UsageEndDate >= :Date.today() AND UsageEndDate <= :maturityEnd
            WITH USER_MODE
            LIMIT 5000
        ]) {
            AccountContext context = contexts.get(asset.AccountId);
            context.nearestMaturity = nearer(context.nearestMaturity, asset.UsageEndDate);
        }
        return contexts;
    }

    /** Latest meeting-note or event date per account. */
    private static Map<Id, Date> loadLastContacts(Set<Id> accountIds) {
        Map<Id, Date> lastByAccount = new Map<Id, Date>();
        for (AggregateResult row : [
            SELECT Opportunity__r.AccountId accountId, MAX(CreatedDate) latest
            FROM Meeting_Note__c
            WHERE Opportunity__r.AccountId IN :accountIds
            WITH USER_MODE
            GROUP BY Opportunity__r.AccountId
        ]) {
            Datetime latest = (Datetime) row.get('latest');
            lastByAccount.put((Id) row.get('accountId'), latest.date());
        }
        for (AggregateResult row : [
            SELECT AccountId accountId, MAX(ActivityDateTime) latest
            FROM Event
            WHERE AccountId IN :accountIds AND ActivityDateTime <= :System.now()
            WITH USER_MODE
            GROUP BY AccountId
        ]) {
            Id accountId = (Id) row.get('accountId');
            Datetime latestDt = (Datetime) row.get('latest');
            Date latest = latestDt == null ? null : latestDt.date();
            Date current = lastByAccount.get(accountId);
            if (latest != null && (current == null || latest > current)) {
                lastByAccount.put(accountId, latest);
            }
        }
        return lastByAccount;
    }

    private static Date nearer(Date current, Date candidate) {
        return current == null || candidate < current ? candidate : current;
    }

    private class WonStat {
        String label;
        Integer total = 0;
        Integer won = 0;
    }

    /** Closed-opportunity counts (org-wide, USER_MODE) keyed by every ladder combination of industry × family × size. */
    private static Map<String, WonStat> loadWonStats(Map<Id, AccountContext> contexts) {
        Map<String, WonStat> stats = new Map<String, WonStat>();
        List<Opportunity> closed = [
            SELECT AccountId, Account.Industry, Primary_Product__r.Family, IsWon
            FROM Opportunity WHERE IsClosed = true AND Primary_Product__c != null
            WITH USER_MODE LIMIT 10000
        ];
        if (closed.isEmpty()) {
            return stats;
        }
        Set<Id> accountIds = new Set<Id>();
        for (Opportunity opportunity : closed) {
            accountIds.add(opportunity.AccountId);
        }
        Map<Id, String> sizeByAccount = loadSizeBuckets(accountIds);
        for (Opportunity opportunity : closed) {
            String industry = opportunity.Account.Industry;
            String family = opportunity.Primary_Product__r.Family;
            String size = sizeByAccount.get(opportunity.AccountId);
            accumulate(stats, industry, family, size, opportunity.IsWon);
            accumulate(stats, industry, family, null, opportunity.IsWon);
            accumulate(stats, null, family, size, opportunity.IsWon);
            accumulate(stats, industry, null, null, opportunity.IsWon);
            accumulate(stats, null, null, null, opportunity.IsWon);
        }
        return stats;
    }

    /** Size bucket (대기업/성장기업/중견기업) from each account's latest statement total assets. */
    private static Map<Id, String> loadSizeBuckets(Set<Id> accountIds) {
        Map<Id, Long> bestRank = new Map<Id, Long>();
        Map<Id, Decimal> assets = new Map<Id, Decimal>();
        for (CorporateFinancialStatement__c statement : [
            SELECT Account__c, Fiscal_Year__c, Period_Type__c, Total_Assets__c
            FROM CorporateFinancialStatement__c
            WHERE Account__c IN :accountIds AND Fiscal_Year__c != null AND Period_Type__c != null
            WITH USER_MODE LIMIT 10000
        ]) {
            Long rank = (Long) statement.Fiscal_Year__c.intValue() * 10 + (SIZE_QUARTER.get(statement.Period_Type__c) ?? 0);
            Long current = bestRank.get(statement.Account__c);
            if (current == null || rank > current) {
                bestRank.put(statement.Account__c, rank);
                assets.put(statement.Account__c, statement.Total_Assets__c);
            }
        }
        Map<Id, String> buckets = new Map<Id, String>();
        for (Id accountId : accountIds) {
            buckets.put(accountId, RadarSettings.segmentFor(assets.get(accountId)));
        }
        return buckets;
    }

    private static void accumulate(Map<String, WonStat> stats, String industry, String family, String size, Boolean isWon) {
        String statKey = key3(industry, family, size);
        WonStat stat = stats.get(statKey);
        if (stat == null) {
            stat = new WonStat();
            List<String> parts = new List<String>();
            if (industry != null) { parts.add(industry); }
            if (family != null) { parts.add(family); }
            if (size != null) { parts.add(size); }
            stat.label = parts.isEmpty() ? '전체' : String.join(parts, '×');
            stats.put(statKey, stat);
        }
        stat.total++;
        if (isWon) {
            stat.won++;
        }
    }

    private static String key3(String industry, String family, String size) {
        return (industry ?? '*') + '|' + (family ?? '*') + '|' + (size ?? '*');
    }
}