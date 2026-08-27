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
        // account 0: cash wallet 1,000억 (RP deal 100억 → 10% share), bonds 500억 with no deal
        RadarTestDataFactory.createStatements(accounts, 2026, 2, 5000 * EOK, 500 * EOK, 0, 600 * EOK, 400 * EOK);
        Map<String, Product2> products = new Map<String, Product2>();
        for (Product2 product : [SELECT Id, Name, Family FROM Product2]) {
            products.put(product.Family, product);
        }
        Date today = Date.today();
        List<Opportunity> opportunities = new List<Opportunity>{
            RadarTestDataFactory.buildOpportunity(accounts[0], products.get('RP'), 100 * EOK, today.addDays(-30), today.addDays(61), true),
            // closed history in the same industry for the similar-won rate: 채권 2 won / 1 lost
            RadarTestDataFactory.buildOpportunity(accounts[1], products.get('채권'), 10 * EOK, today.addYears(-2), null, true),
            RadarTestDataFactory.buildOpportunity(accounts[1], products.get('채권'), 10 * EOK, today.addYears(-2), null, true),
            RadarTestDataFactory.buildOpportunity(accounts[1], products.get('채권'), 10 * EOK, today.addYears(-2), null, false)
        };
        insert opportunities;
    }

    private static Account accountZero() {
        return [SELECT Id FROM Account WHERE Name = 'Radar Test Account 0' LIMIT 1];
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
        Assert.areEqual(100 * EOK, bondCross.Expected_Amount__c, 'expected = 500억 × 20%');
        Recommendation__c rpUpsell = byType.get('업셀|RP');
        Assert.isNotNull(rpUpsell, 'RP at 10% share (< 30%) → upsell');
        Assert.areEqual(200 * EOK, rpUpsell.Expected_Amount__c, 'expected = 1,000억 × (30% − 10%)');
        Assert.areEqual(10.0, rpUpsell.Wallet_Share__c, 'share stored as percent');
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
}