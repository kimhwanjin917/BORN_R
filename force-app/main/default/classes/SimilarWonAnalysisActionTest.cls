/**
 * SimilarWonAnalysisAction tests for industry and product-family aggregation.
 * Product family is stored on Opportunity.Product_Family__c in this org.
 */
@IsTest
private class SimilarWonAnalysisActionTest {

    private static final String IND_A = 'Manufacturing';
    private static final String IND_B = 'Media';
    private static final String IND_EMPTY = 'Agriculture';

    @TestSetup
    static void setup() {
        Account accA = new Account(Name = 'SWA 테스트 제조', Industry = IND_A, Business_Registration_Number__c = '9990000001');
        Account accB = new Account(Name = 'SWA 테스트 미디어', Industry = IND_B, Business_Registration_Number__c = '9990000002');
        insert new List<Account>{ accA, accB };

        Product2 rp = new Product2(Name = 'SWA RP (환매조건부채권)', IsActive = true);
        Product2 bond = new Product2(Name = 'SWA 회사채', IsActive = true);
        insert new List<Product2>{ rp, bond };

        Date closeDate = Date.today().addDays(30);
        List<Opportunity> opportunities = new List<Opportunity>{
            new Opportunity(Name = 'A-Won-RP-1', AccountId = accA.Id, StageName = 'Closed Won', CloseDate = closeDate, Primary_Product__c = rp.Id),
            new Opportunity(Name = 'A-Won-RP-2', AccountId = accA.Id, StageName = 'Closed Won', CloseDate = closeDate, Primary_Product__c = rp.Id),
            new Opportunity(Name = 'A-Won-Bond', AccountId = accA.Id, StageName = 'Closed Won', CloseDate = closeDate, Primary_Product__c = bond.Id),
            new Opportunity(Name = 'A-Lost-RP', AccountId = accA.Id, StageName = 'Closed Lost', CloseDate = closeDate, Primary_Product__c = rp.Id),
            new Opportunity(Name = 'A-Lost-None', AccountId = accA.Id, StageName = 'Closed Lost', CloseDate = closeDate),
            new Opportunity(Name = 'A-Open-RP', AccountId = accA.Id, StageName = '미팅', CloseDate = closeDate, Primary_Product__c = rp.Id),
            new Opportunity(Name = 'B-Lost-1', AccountId = accB.Id, StageName = 'Closed Lost', CloseDate = closeDate, Primary_Product__c = rp.Id),
            new Opportunity(Name = 'B-Lost-2', AccountId = accB.Id, StageName = 'Closed Lost', CloseDate = closeDate)
        };
        insert opportunities;
    }

    private static SimilarWonAnalysisAction.Result run(String industry, String productType) {
        SimilarWonAnalysisAction.Request request = new SimilarWonAnalysisAction.Request();
        request.industry = industry;
        request.productType = productType;
        List<SimilarWonAnalysisAction.Result> results = SimilarWonAnalysisAction.analyze(
            new List<SimilarWonAnalysisAction.Request>{ request });
        Assert.areEqual(1, results.size(), '요청 1건당 결과 1건');
        return results[0];
    }

    @IsTest
    static void industryOnly_countsClosedWonAndLost() {
        Test.startTest();
        SimilarWonAnalysisAction.Result result = run(IND_A, null);
        Test.stopTest();

        Assert.areEqual(5, result.totalCount, '산업군 A 종결 건수');
        Assert.areEqual(3, result.wonCount, '산업군 A Won 건수');
        Assert.areEqual(60.0, result.wonRate, 'Won 비율');
        Assert.isFalse(result.insufficientData, '데이터 충분');
    }

    @IsTest
    static void productTypeByProductName_filtersMatchingPrimaryProduct() {
        Test.startTest();
        SimilarWonAnalysisAction.Result result = run(IND_A, 'SWA RP (환매조건부채권)');
        Test.stopTest();

        Assert.areEqual(3, result.totalCount, 'A + RP 종결 건수');
        Assert.areEqual(2, result.wonCount, 'A + RP Won 건수');
        Assert.areEqual(66.7, result.wonRate, 'Won 비율');
        Assert.isFalse(result.insufficientData, '데이터 충분');
    }

    @IsTest
    static void productTypeByProductName_alsoMatches() {
        Test.startTest();
        SimilarWonAnalysisAction.Result result = run(IND_A, 'SWA 회사채');
        Test.stopTest();

        Assert.areEqual(1, result.totalCount, '상품명 매칭 건수');
        Assert.areEqual(1, result.wonCount, '상품명 매칭 Won 건수');
        Assert.areEqual(100.0, result.wonRate, 'Won 비율');
    }

    @IsTest
    static void allLost_returnsZeroRateButSufficientData() {
        Test.startTest();
        SimilarWonAnalysisAction.Result result = run(IND_B, null);
        Test.stopTest();

        Assert.areEqual(2, result.totalCount, '종결 건수');
        Assert.areEqual(0, result.wonCount, 'Won 건수');
        Assert.areEqual(0.0, result.wonRate, 'Won 0이면 0%');
        Assert.isFalse(result.insufficientData, '모수가 있으면 데이터 충분');
    }

    @IsTest
    static void noMatchOrBlankIndustry_returnsInsufficientData() {
        Test.startTest();
        SimilarWonAnalysisAction.Result noMatch = run(IND_A, '존재하지않는상품');
        SimilarWonAnalysisAction.Result blank = run('   ', 'SWA RP (환매조건부채권)');
        SimilarWonAnalysisAction.Result nullIndustry = run(null, null);
        Test.stopTest();

        Assert.areEqual(0, noMatch.totalCount, '상품 매칭 없음');
        Assert.isTrue(noMatch.insufficientData, '상품 매칭 없음은 데이터 부족');
        Assert.isTrue(blank.insufficientData, '공백 산업군은 데이터 부족');
        Assert.isTrue(nullIndustry.insufficientData, 'null 산업군은 데이터 부족');
    }

    @IsTest
    static void bulkRequests_returnOneResultPerRequestInOrder() {
        List<SimilarWonAnalysisAction.Request> requests = new List<SimilarWonAnalysisAction.Request>();
        for (String industry : new List<String>{ IND_A, IND_B, IND_EMPTY }) {
            SimilarWonAnalysisAction.Request request = new SimilarWonAnalysisAction.Request();
            request.industry = industry;
            requests.add(request);
        }

        Test.startTest();
        List<SimilarWonAnalysisAction.Result> results = SimilarWonAnalysisAction.analyze(requests);
        Test.stopTest();

        Assert.areEqual(3, results.size(), '요청별 결과');
        Assert.areEqual(5, results[0].totalCount, '첫 번째 결과');
        Assert.areEqual(2, results[1].totalCount, '두 번째 결과');
        Assert.isTrue(results[2].insufficientData, '세 번째 결과');
        Assert.areEqual(0, SimilarWonAnalysisAction.analyze(null).size(), 'null 입력');
        Assert.areEqual(0, SimilarWonAnalysisAction.analyze(new List<SimilarWonAnalysisAction.Request>()).size(), '빈 입력');
    }
}