/**
 * Unit tests for BORNGrowthOppController.
 * Test data is created in @TestSetup and is fully isolated/rolled back — no
 * records are ever persisted to the org (AGENTS.md compliant; does not touch
 * TestDataFactory).
 */
@IsTest
private class BORNGrowthOppControllerTest {

    @TestSetup
    static void setup() {
        Account a = new Account(
            Name = 'TEST_GROWTH_ACME',
            Industry = '제조업',
            AnnualRevenue = 1000000000,
            NumberOfEmployees = 500,
            Business_Registration_Number__c = '1234567890'
        );
        insert a;

        Product2 p = new Product2(Name = 'RP (환매조건부채권)', Family = 'RP', IsActive = true);
        insert p;

        // 3 quarters of financials to exercise the trend + latest-period logic
        List<CorporateFinancialStatement__c> fins = new List<CorporateFinancialStatement__c>{
            new CorporateFinancialStatement__c(Account__c = a.Id, Fiscal_Year__c = 2025,
                Period_Type__c = '3분기', Cash_And_Equivalents__c = 100, Short_Term_Financial_Instruments__c = 50),
            new CorporateFinancialStatement__c(Account__c = a.Id, Fiscal_Year__c = 2025,
                Period_Type__c = '4분기', Cash_And_Equivalents__c = 120, Short_Term_Financial_Instruments__c = 60),
            new CorporateFinancialStatement__c(Account__c = a.Id, Fiscal_Year__c = 2026,
                Period_Type__c = '1분기', Cash_And_Equivalents__c = 200, Short_Term_Financial_Instruments__c = 100)
        };
        insert fins;

        Opportunity o = new Opportunity(
            Name = 'TEST_GROWTH_OPP',
            AccountId = a.Id,
            StageName = 'Closed Won',
            CloseDate = Date.today(),
            Amount = 90,
            Primary_Product__c = p.Id
        );
        insert o;

        insert new List<Recommendation__c>{
            new Recommendation__c(Account__c = a.Id, Type__c = '업셀', Status__c = '제안됨'),
            new Recommendation__c(Account__c = a.Id, Type__c = '크로스셀', Status__c = '제안됨'),
            new Recommendation__c(Account__c = a.Id, Type__c = '크로스셀', Status__c = '제안됨')
        };
    }

    @IsTest
    static void testGetAccounts() {
        Test.startTest();
        List<BORNGrowthOppController.AccountOption> opts = BORNGrowthOppController.getAccounts();
        Test.stopTest();
        System.assert(!opts.isEmpty(), 'expected at least the test account');
        Boolean found = false;
        for (BORNGrowthOppController.AccountOption o : opts) {
            if (o.label == 'TEST_GROWTH_ACME') { found = true; }
        }
        System.assert(found, 'test account should be listed');
    }

    @IsTest
    static void testGetAnalysisFull() {
        Account a = [SELECT Id FROM Account WHERE Name = 'TEST_GROWTH_ACME' LIMIT 1];
        Test.startTest();
        BORNGrowthOppController.AnalysisResult r = BORNGrowthOppController.getAnalysis(a.Id);
        Test.stopTest();

        System.assertEquals('제조업', r.industry, 'industry passthrough');
        System.assertEquals(3, r.trend.size(), 'three quarters of trend');
        System.assertEquals(200, r.cash, 'latest quarter cash');
        System.assertEquals(100, r.shortTerm, 'latest quarter short term');
        System.assertEquals(300, r.estimatedInvestableFunds, 'cash + short term');
        System.assertEquals(90, r.closedWonAmount, 'closed won total');
        System.assertEquals(true, r.hasProxy, 'proxy should be positive (300-90)');
        System.assertEquals(210, r.whitespaceProxy, 'proxy value');
        System.assertEquals(1, r.ownedProducts.size(), 'one won product');
        System.assert(r.hasUpsell, 'upsell recommendation present');
        System.assert(r.hasCrossSell, 'crosssell recommendation present');
        System.assertEquals(1, r.upsellCount, 'one upsell rec');
        System.assertEquals(2, r.crossSellCount, 'two crosssell recs');
        // whitespace should NOT include the owned RP product
        System.assert(!r.whitespaceProducts.contains('RP (환매조건부채권)'), 'owned product excluded from whitespace');
    }

    @IsTest
    static void testGetAnalysisNoFinancials() {
        Account b = new Account(Name = 'TEST_GROWTH_NOFIN', Industry = '제조업',
            Business_Registration_Number__c = '1234567891');
        insert b;
        Test.startTest();
        BORNGrowthOppController.AnalysisResult r = BORNGrowthOppController.getAnalysis(b.Id);
        Test.stopTest();
        System.assertEquals(false, r.hasFinancials, 'no financials for this account');
        System.assertEquals(false, r.hasProxy, 'no proxy without financials');
        System.assertEquals(0, r.ownedProducts.size(), 'no won products');
    }
}