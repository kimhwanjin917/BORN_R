@IsTest
private class LeadRecommendationEngineTest {

    private static final Decimal EOK = 100000000;

    @TestSetup
    static void setup() {
        insert new List<Product2>{
            new Product2(Name = 'RP (환매조건부채권)', Family = 'RP', IsActive = true,
                Min_Term_Days__c = 1, Max_Term_Days__c = 180, Default_Fee_Rate__c = 0.15),
            new Product2(Name = '외화 RP (USD)', Family = 'RP', IsActive = true,
                Min_Term_Days__c = 1, Max_Term_Days__c = 180, Default_Fee_Rate__c = 0.10),
            new Product2(Name = '회사채', Family = '채권', IsActive = true,
                Min_Term_Days__c = 90, Max_Term_Days__c = 1825, Default_Fee_Rate__c = 0.30)
        };
        insert new List<Lead>{
            newLead('여유', '여유기업'), newLead('조달', '조달기업'), newLead('무자료', '자료없는기업')
        };
    }

    private static Lead newLead(String last, String company) {
        return new Lead(LastName = last, name_new__c = last, Company = company,
            Email = 'engine.test@example.com', Industry = '제조업', Status = '신규');
    }

    private static void addFinance(String company, Decimal cash, Decimal stfi, Decimal shortDebt, Decimal bonds) {
        Lead l = [SELECT Id FROM Lead WHERE Company = :company LIMIT 1];
        insert new CorporateFinancialStatement__c(
            Lead__c = l.Id, Fiscal_Year__c = 2026, External_Key__c = 'T-' + company + '-11012',
            Cash_And_Equivalents__c = cash, Short_Term_Financial_Instruments__c = stfi,
            Short_Term_Borrowings__c = shortDebt, Bonds_Payable__c = bonds);
    }

    private static Lead reload(String company) {
        return [SELECT Recommended_Product_Family__c, Recommended_Product__r.Name, Recommended_Term_Days__c,
                       Recommended_Fee_Rate__c, Recommended_Product_Rationale__c
                FROM Lead WHERE Company = :company LIMIT 1];
    }

    @IsTest
    static void recommendsRpWhenLiquidityIsHealthy() {
        addFinance('여유기업', 1200 * EOK, 300 * EOK, 100 * EOK, 0);
        Lead l = [SELECT Id FROM Lead WHERE Company = '여유기업' LIMIT 1];

        Test.startTest();
        LeadRecommendationEngine.Result r = LeadRecommendationEngine.ensureRecommendation(l.Id);
        Test.stopTest();

        System.Assert.isTrue(r.saved, '저장 실패: ' + r.skipReason);
        Lead saved = reload('여유기업');
        System.Assert.areEqual('RP', saved.Recommended_Product_Family__c);
        System.Assert.areEqual('RP (환매조건부채권)', saved.Recommended_Product__r.Name, '외화 상품은 고르지 않는다');
        System.Assert.areEqual(91, saved.Recommended_Term_Days__c, '500억 이상이면 91일');
        System.Assert.areEqual(0.15, saved.Recommended_Fee_Rate__c);
        System.Assert.isTrue(saved.Recommended_Product_Rationale__c.contains('억원'), '근거에 수치가 들어가야 한다');
    }

    @IsTest
    static void recommendsBondWhenFundingDebtExists() {
        addFinance('조달기업', 200 * EOK, 0, 50 * EOK, 800 * EOK);
        Lead l = [SELECT Id FROM Lead WHERE Company = '조달기업' LIMIT 1];

        Test.startTest();
        LeadRecommendationEngine.ensureRecommendation(l.Id);
        Test.stopTest();

        Lead saved = reload('조달기업');
        System.Assert.areEqual('회사채', saved.Recommended_Product_Family__c, '사채가 있으면 조달 쪽이다');
        System.Assert.areEqual(1095, saved.Recommended_Term_Days__c);
    }

    @IsTest
    static void skipsWhenNoFinancials() {
        Lead l = [SELECT Id FROM Lead WHERE Company = '자료없는기업' LIMIT 1];

        Test.startTest();
        LeadRecommendationEngine.Result r = LeadRecommendationEngine.ensureRecommendation(l.Id);
        Test.stopTest();

        System.Assert.isFalse(r.saved, '근거가 없으면 추정하지 않는다');
        System.Assert.isNull(reload('자료없는기업').Recommended_Product__c);
    }

    @IsTest
    static void doesNotOverwriteExistingRecommendation() {
        addFinance('여유기업', 1200 * EOK, 300 * EOK, 100 * EOK, 0);
        Lead l = [SELECT Id FROM Lead WHERE Company = '여유기업' LIMIT 1];
        Product2 bond = [SELECT Id FROM Product2 WHERE Name = '회사채' LIMIT 1];
        update new Lead(Id = l.Id, Recommended_Product_Family__c = '회사채',
            Recommended_Product__c = bond.Id, Recommended_Term_Days__c = 730);

        Test.startTest();
        LeadRecommendationEngine.Result r = LeadRecommendationEngine.ensureRecommendation(l.Id);
        Test.stopTest();

        System.Assert.isFalse(r.saved, '에이전트가 기록한 값을 덮으면 안 된다');
        System.Assert.areEqual(730, reload('여유기업').Recommended_Term_Days__c);
    }
}