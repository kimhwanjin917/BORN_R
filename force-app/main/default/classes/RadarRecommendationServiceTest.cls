/**
 * Covers RadarScoreService + RadarRecommendationService: score components, cross-sell/upsell/rollover
 * rules, ranking, persistence and replacement of stale proposals.
 */
@IsTest
private class RadarRecommendationServiceTest {
    private static final Decimal EOK = RadarTestDataFactory.EOK;

    @TestSetup
    static void setup() {
        RadarTestDataFactory.createProducts();
        List<Account> accounts = RadarTestDataFactory.createAccounts(2, true);
        // account 0: reported cash wallet 1,000억 → addressable 200억 (RP deal 100억 → 50% share),
        // reported bonds 500억 → addressable 100억 with no deal
        RadarTestDataFactory.createStatements(accounts, 2026, 2, 5000 * EOK, 500 * EOK, 0, 600 * EOK, 400 * EOK);
        Map<String, Product2> products = new Map<String, Product2>();
        for (Product2 product : [SELECT Id, Name, Family FROM Product2]) {
            products.put(product.Family, product);
        }
        Date today = Date.today();
        List<Opportunity> opportunities = new List<Opportunity>{
            // maturity deliberately outside the rollover window so this deal reads as a plain upsell;
            // the rollover cases set their own maturities
            RadarTestDataFactory.buildOpportunity(accounts[0], products.get('RP'), 100 * EOK, today.addDays(-30), today.addDays(200), true),
            // closed history in the same industry for the similar-won rate: 채권 2 won / 1 lost
            RadarTestDataFactory.buildOpportunity(accounts[1], products.get('채권'), 10 * EOK, today.addYears(-2), null, true),
            RadarTestDataFactory.buildOpportunity(accounts[1], products.get('채권'), 10 * EOK, today.addYears(-2), null, true),
            RadarTestDataFactory.buildOpportunity(accounts[1], products.get('채권'), 10 * EOK, today.addYears(-2), null, false)
        };
        insert opportunities;
    }

    // Name is selected because RadarTestDataFactory.buildOpportunity names the deal after the account.
    private static Account accountZero() {
        return [SELECT Id, Name FROM Account WHERE Name = 'Radar Test Account 0' LIMIT 1];
    }

    /** Has the same wallet as account 0 but no cash deal of its own. */
    private static Account accountOne() {
        return [SELECT Id, Name FROM Account WHERE Name = 'Radar Test Account 1' LIMIT 1];
    }

    // Name is selected for the same reason as on the account: the factory builds the deal name from both.
    private static Product2 product(String family) {
        return [SELECT Id, Name FROM Product2 WHERE Family = :family LIMIT 1];
    }

    private static Map<String, Recommendation__c> recsByFamily(Id accountId) {
        Map<String, Recommendation__c> byFamily = new Map<String, Recommendation__c>();
        for (Recommendation__c rec : [
            SELECT Type__c, Product__r.Family, Expected_Amount__c, Rank__c, Reason__c
            FROM Recommendation__c WHERE Account__c = :accountId
        ]) {
            byFamily.put(rec.Product__r.Family, rec);
        }
        return byFamily;
    }

    @IsTest
    static void shouldScoreSimilarWonFinancialPriority_WhenHistoryExists() {
        Account account = accountZero();
        Map<Id, WalletShareService.AccountWallet> wallets = WalletShareService.compute(new Set<Id>{ account.Id }, Date.today());

        Test.startTest();
        Map<String, RadarScoreService.Score> scores = RadarScoreService.compute(wallets).get(account.Id);
        Test.stopTest();

        RadarScoreService.Score bond = scores.get('채권');
        Assert.areEqual(67, bond.similarWon, '채권 won rate = 2/3 → 67');
        Assert.areEqual(0, bond.signal, 'no signals');
        Assert.areEqual(50, bond.financial, 'single statement → no prior → 50');
        Assert.areEqual(50, bond.priority, 'no Priority_Score__c → 50');
        Assert.isNull(bond.lastContactDays, 'no meeting notes or events');
        // 67*30 + 0*30 + 50*20 + 50*20 = 4010 / 100 = 40.1 → 40
        Assert.areEqual(40, bond.total, 'weighted total');
        // RP has fewer than 3 closed deals in the industry → industry-wide fallback 3/4 = 75
        Assert.areEqual(75, scores.get('RP').similarWon, 'RP falls back to industry rate 3/4');
    }

    @IsTest
    static void shouldRaiseSignalScoreAndPromoteRollover_WhenMaturityInsideWindow() {
        Account account = accountZero();
        insert RadarTestDataFactory.buildSignal(account, '공시', Date.today().addDays(-5), Date.today().addDays(30));

        Test.startTest();
        List<Recommendation__c> recs = RadarRecommendationService.regenerate(new Set<Id>{ account.Id });
        Test.stopTest();

        Recommendation__c first = recs[0];
        Assert.areEqual(1, first.Rank__c, 'promoted candidate is rank 1');
        Assert.areEqual(RadarRecommendationService.TYPE_ROLLOVER, first.Type__c, 'cash family with maturity becomes 만기차환');
        Assert.isTrue(first.Reason__c.contains('만기 도래'), 'reason mentions maturity: ' + first.Reason__c);
    }

    @IsTest
    static void shouldBuildCrossSellForBondAndUpsellForRp() {
        Account account = accountZero();

        Test.startTest();
        List<Recommendation__c> recs = RadarRecommendationService.regenerate(new Set<Id>{ account.Id });
        Test.stopTest();

        Map<String, Recommendation__c> byType = new Map<String, Recommendation__c>();
        for (Recommendation__c rec : [SELECT Type__c, Product__r.Family, Expected_Amount__c, Wallet_Share__c, Whitespace_Amount__c, Status__c, Source__c
                                      FROM Recommendation__c WHERE Account__c = :account.Id]) {
            byType.put(rec.Type__c + '|' + rec.Product__r.Family, rec);
        }
        Assert.areEqual(2, recs.size(), 'RP upsell + 채권 cross (자금운용 deduped against RP cash wallet)');
        Recommendation__c bondCross = byType.get('크로스셀|채권');
        Assert.isNotNull(bondCross, 'bond family without deal → cross-sell');
        Assert.areEqual(100 * EOK, bondCross.Expected_Amount__c, 'expected = the whole addressable bond wallet (500억 × 20%)');
        Recommendation__c rpUpsell = byType.get('업셀|RP');
        Assert.isNotNull(rpUpsell, 'RP holds half its addressable wallet (< 100% fill target) → upsell');
        Assert.areEqual(100 * EOK, rpUpsell.Expected_Amount__c, 'expected = addressable 200억 × (100% − 50%)');
        Assert.areEqual(50.0, rpUpsell.Wallet_Share__c, 'share is measured against the addressable wallet: 100 / 200');
        Assert.areEqual('제안됨', rpUpsell.Status__c, 'new rows are proposals');
        Assert.areEqual('레이더', rpUpsell.Source__c, 'source is radar');
    }

    @IsTest
    static void shouldReplaceStaleProposals_ButKeepActedOnes() {
        Account account = accountZero();
        RadarRecommendationService.regenerate(new Set<Id>{ account.Id });
        Recommendation__c acted = [SELECT Id FROM Recommendation__c WHERE Account__c = :account.Id LIMIT 1];
        acted.Status__c = '보류';
        update acted;

        Test.startTest();
        RadarRecommendationService.regenerate(new Set<Id>{ account.Id });
        Test.stopTest();

        Integer proposed = [SELECT COUNT() FROM Recommendation__c WHERE Account__c = :account.Id AND Status__c = '제안됨'];
        Integer held = [SELECT COUNT() FROM Recommendation__c WHERE Account__c = :account.Id AND Status__c = '보류'];
        Assert.areEqual(2, proposed, 'proposals regenerated');
        Assert.areEqual(1, held, 'acted row untouched');
    }

    @IsTest
    static void shouldScoreFinancialGrowthAndPriority_WhenPriorStatementExists() {
        Account account = accountZero();
        account.Priority_Score__c = 90;
        update account;
        // prior year Q2: cash 800억 vs latest 1,000억 → +25% on a ±50% scale → 75
        RadarTestDataFactory.createStatements(new List<Account>{ account }, 2025, 2, 4000 * EOK, 500 * EOK, 0, 500 * EOK, 300 * EOK);
        Map<Id, WalletShareService.AccountWallet> wallets = WalletShareService.compute(new Set<Id>{ account.Id }, Date.today());

        Test.startTest();
        Map<String, RadarScoreService.Score> scores = RadarScoreService.compute(wallets).get(account.Id);
        Test.stopTest();

        RadarScoreService.Score rp = scores.get('RP');
        Assert.areEqual(75, rp.financial, 'cash wallet grew 25% → 75 on ±50% scale');
        Assert.areEqual(83, rp.priority, 'priority 90 rescaled from 40..100 → 83');
        Assert.isTrue(rp.financialNote.contains('+25%'), 'note shows growth: ' + rp.financialNote);
        RadarScoreService.Score bond = scores.get('채권');
        Assert.areEqual(50, bond.financial, 'debt wallet unchanged 500억 → 0% growth → 50');
    }

    @IsTest
    static void shouldReturnEmpty_WhenNoAccounts() {
        Test.startTest();
        List<Recommendation__c> recs = RadarRecommendationService.regenerate(new Set<Id>());
        Test.stopTest();
        Assert.areEqual(0, recs.size(), 'nothing to do');
    }

    @IsTest
    static void shouldHandleBulkAccounts() {
        List<Account> accounts = RadarTestDataFactory.createAccounts(251, true);
        RadarTestDataFactory.createStatements(accounts, 2026, 1, 800 * EOK, 100 * EOK, 0, 50 * EOK, 50 * EOK);
        Set<Id> ids = new Map<Id, Account>(accounts).keySet();

        Test.startTest();
        List<Recommendation__c> recs = RadarRecommendationService.regenerate(ids);
        Test.stopTest();

        Assert.areEqual(251 * 2, recs.size(), 'RP cross + 채권 cross per account (자금운용 deduped)');
    }

    /**
     * 추천 이력의 소유자는 레이더를 실행한 사람이 아니라 고객사 담당자여야 한다.
     * 실행자로 남으면 담당이 아닌 사람이 남의 고객 지갑·잔액을 보게 된다.
     */
    @IsTest
    static void shouldOwnRecommendationsByAccountOwner() {
        Profile standard = [SELECT Id FROM Profile WHERE UserType = 'Standard' LIMIT 1];
        String stamp = String.valueOf(Datetime.now().getTime());
        User coverer = new User(
            FirstName = 'Radar', LastName = 'Coverer',
            Alias = 'rdcv', Email = 'radarcoverer@example.com',
            Username = 'radarcoverer.' + stamp + '@example.com.rdtest',
            ProfileId = standard.Id, TimeZoneSidKey = 'Asia/Seoul',
            LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US'
        );
        insert coverer;
        Assert.areNotEqual(UserInfo.getUserId(), coverer.Id, '사전 조건: 실행자와 담당자가 달라야 한다');

        Account account = accountZero();
        // 고객사를 다른 사람에게 넘긴다 — 레이더는 여전히 현재 사용자가 돌린다
        update new Account(Id = account.Id, OwnerId = coverer.Id);

        Test.startTest();
        List<Recommendation__c> recs = RadarRecommendationService.regenerate(new Set<Id>{ account.Id });
        Test.stopTest();

        Assert.isFalse(recs.isEmpty(), '사전 조건: 추천이 생성되어야 한다');
        for (Recommendation__c rec : [
            SELECT OwnerId FROM Recommendation__c WHERE Account__c = :account.Id
        ]) {
            Assert.areEqual(coverer.Id, rec.OwnerId, '실행자가 아니라 고객사 담당자가 소유자여야 한다');
        }
    }

    /**
     * 우리 비중이 업셀 기준(30%)을 넘은 고객이야말로 만기 때 반드시 다시 찾아가야 한다.
     * 예전에는 이 지점에서 후보가 통째로 탈락해, 지킬 가치가 가장 큰 고객이 레이더에서 사라졌다.
     */
    @IsTest
    static void shouldProposeRollover_WhenShareExceedsUpsellThresholdButMoneyMatures() {
        Account account = accountZero();
        Date today = Date.today();
        // 기존 100억(만기 창 밖) + 300억(20일 뒤 만기) → 점유율 40%, 업셀 기준 초과
        insert RadarTestDataFactory.buildOpportunity(account, product('RP'), 300 * EOK, today.addDays(-10), today.addDays(20), true);

        Test.startTest();
        RadarRecommendationService.regenerate(new Set<Id>{ account.Id });
        Test.stopTest();

        Recommendation__c rp = recsByFamily(account.Id).get('RP');
        Assert.isNotNull(rp, '점유율이 업셀 기준을 넘어도 만기가 오면 후보로 남아야 한다');
        Assert.areEqual(RadarRecommendationService.TYPE_ROLLOVER, rp.Type__c, '만기차환으로 분류되어야 한다');
        Assert.areEqual(1, rp.Rank__c, '만기 건이 1순위');
        Assert.areEqual(300 * EOK, rp.Expected_Amount__c, '예상 금액은 지갑 여백이 아니라 실제 만기 도래 금액');
    }

    /** 만기가 이미 지난 자금도 차환 대상이다 — 놓친 만큼 더 급하다. */
    @IsTest
    static void shouldProposeRollover_WhenMaturityAlreadyPassed() {
        Account account = accountZero();
        Date today = Date.today();
        insert RadarTestDataFactory.buildOpportunity(account, product('RP'), 250 * EOK, today.addDays(-120), today.addDays(-20), true);

        Test.startTest();
        RadarRecommendationService.regenerate(new Set<Id>{ account.Id });
        Test.stopTest();

        Recommendation__c rp = recsByFamily(account.Id).get('RP');
        Assert.areEqual(RadarRecommendationService.TYPE_ROLLOVER, rp.Type__c, '만기 경과 건도 만기차환');
        Assert.areEqual(250 * EOK, rp.Expected_Amount__c, '경과한 만기 금액이 재유치 목표');
        Assert.isTrue(rp.Reason__c.contains('만기 경과'), '사유에 만기 경과가 드러나야 함: ' + rp.Reason__c);
        Assert.isTrue(rp.Reason__c.contains('재유치'), '이미 빠져나간 자금은 재예치가 아니라 재유치: ' + rp.Reason__c);
    }

    /** 우리 자금이 없는 고객은 차환할 것이 없다 — 만기 신호가 있어도 신규 제안이어야 한다. */
    @IsTest
    static void shouldStayCrossSell_WhenMaturitySignalButNoDealOfOurs() {
        Account account = accountOne();
        insert RadarTestDataFactory.buildSignal(account, '공시', Date.today().addDays(-5), Date.today().addDays(30));

        Test.startTest();
        RadarRecommendationService.regenerate(new Set<Id>{ account.Id });
        Test.stopTest();

        Recommendation__c rp = recsByFamily(account.Id).get('RP');
        Assert.isNotNull(rp, 'RP 후보는 나와야 한다');
        Assert.areEqual(RadarRecommendationService.TYPE_CROSS, rp.Type__c, '거래 이력이 없으면 만기 신호가 있어도 크로스셀');
    }

    /** 차환끼리는 금액이 아니라 만기 기한이 순서를 정한다. */
    @IsTest
    static void shouldRankRolloversByDeadline_NotByAmount() {
        RadarRecommendationService.Candidate urgentSmall = new RadarRecommendationService.Candidate();
        urgentSmall.promoted = true;
        urgentSmall.maturityDays = -5;      // 이미 5일 지남
        urgentSmall.whitespace = 10 * EOK;
        urgentSmall.score = 50;

        RadarRecommendationService.Candidate laterLarge = new RadarRecommendationService.Candidate();
        laterLarge.promoted = true;
        laterLarge.maturityDays = 45;
        laterLarge.whitespace = 5000 * EOK;
        laterLarge.score = 90;

        List<RadarRecommendationService.Candidate> candidates =
            new List<RadarRecommendationService.Candidate>{ laterLarge, urgentSmall };

        Test.startTest();
        candidates.sort();
        Test.stopTest();

        Assert.areEqual(-5, candidates[0].maturityDays, '금액이 훨씬 커도 기한이 급한 쪽이 먼저');
    }
}