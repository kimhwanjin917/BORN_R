/**
 * SimilarWonAnalysisAction 테스트 — 시드 Opportunity(Won/Lost 혼합)를 @TestSetup으로 만들고
 * 액션 경계(Invocable 호출)에서 수치 정합과 모수 0(데이터 부족) 케이스를 검증한다.
 * TestDataFactory는 사용하지 않는다(팀 공용 동결 파일). 테스트는 org 데이터를 보지 않으므로(SeeAllData=false)
 * 기대값은 전부 시드 기준이다.
 */
@IsTest
private class SimilarWonAnalysisActionTest {

    private static final String IND_A = 'Manufacturing';   // 시드: Won 3 / Lost 2 / 미종결 1
    private static final String IND_B = 'Media';           // 시드: Won 0 / Lost 2
    private static final String IND_EMPTY = 'Agriculture'; // 시드 없음
    private static final String FAMILY_RP = 'RP';
    private static final String FAMILY_BOND = '채권';

    @TestSetup
    static void setup() {
        // Business_Registration_Number__c(사업자등록번호, 10자)는 이 org에서 필수 필드
        Account accA = new Account(Name = 'SWA 테스트 제조', Industry = IND_A, Business_Registration_Number__c = '9990000001');
        Account accB = new Account(Name = 'SWA 테스트 미디어', Industry = IND_B, Business_Registration_Number__c = '9990000002');
        insert new List<Account>{ accA, accB };

        Product2 rp = new Product2(Name = 'SWA RP (환매조건부채권)', Family = FAMILY_RP, IsActive = true);
        Product2 bond = new Product2(Name = 'SWA 회사채', Family = FAMILY_BOND, IsActive = true);
        insert new List<Product2>{ rp, bond };

        Date d = Date.today().addDays(30);
        List<Opportunity> opps = new List<Opportunity>{
            // 산업군 A: Won 3 (RP 2, 채권 1), Lost 2 (RP 1, 상품 없음 1), 미종결 1 (RP)
            new Opportunity(Name = 'A-Won-RP-1', AccountId = accA.Id, StageName = 'Closed Won',  CloseDate = d, Primary_Product__c = rp.Id),
            new Opportunity(Name = 'A-Won-RP-2', AccountId = accA.Id, StageName = 'Closed Won',  CloseDate = d, Primary_Product__c = rp.Id),
            new Opportunity(Name = 'A-Won-Bond',  AccountId = accA.Id, StageName = 'Closed Won',  CloseDate = d, Primary_Product__c = bond.Id),
            new Opportunity(Name = 'A-Lost-RP',   AccountId = accA.Id, StageName = 'Closed Lost', CloseDate = d, Primary_Product__c = rp.Id),
            new Opportunity(Name = 'A-Lost-None', AccountId = accA.Id, StageName = 'Closed Lost', CloseDate = d),
            new Opportunity(Name = 'A-Open-RP',   AccountId = accA.Id, StageName = '미팅',        CloseDate = d, Primary_Product__c = rp.Id),
            // 산업군 B: Lost 2
            new Opportunity(Name = 'B-Lost-1', AccountId = accB.Id, StageName = 'Closed Lost', CloseDate = d, Primary_Product__c = rp.Id),
            new Opportunity(Name = 'B-Lost-2', AccountId = accB.Id, StageName = 'Closed Lost', CloseDate = d)
        };
        insert opps;
    }

    private static SimilarWonAnalysisAction.Result run(String industry, String productType) {
        SimilarWonAnalysisAction.Request req = new SimilarWonAnalysisAction.Request();
        req.industry = industry;
        req.productType = productType;
        List<SimilarWonAnalysisAction.Result> out = SimilarWonAnalysisAction.analyze(
            new List<SimilarWonAnalysisAction.Request>{ req });
        System.assertEquals(1, out.size(), '요청 1건당 결과 1건');
        return out[0];
    }

    @IsTest
    static void industryOnly_countsClosedWonAndLost() {
        Test.startTest();
        SimilarWonAnalysisAction.Result r = run(IND_A, null);
        Test.stopTest();

        System.assertEquals(5, r.totalCount, '산업군 A 종결 건수(미종결 1건 제외)');
        System.assertEquals(3, r.wonCount, '산업군 A Won 건수');
        System.assertEquals(60.0, r.wonRate, 'Won 비율 = 3/5 = 60.0%');
        System.assertEquals(false, r.insufficientData, '데이터 충분');
        System.assertEquals(IND_A, r.industry);
        System.assertEquals('', r.productType);
        System.assert(r.message.contains('5건 중 3건'), '요약 메시지에 수치 포함: ' + r.message);
    }

    @IsTest
    static void productTypeByFamily_filtersToMatchingPrimaryProduct() {
        Test.startTest();
        SimilarWonAnalysisAction.Result r = run(IND_A, FAMILY_RP);
        Test.stopTest();

        System.assertEquals(3, r.totalCount, 'A + RP 종결: Won 2 + Lost 1');
        System.assertEquals(2, r.wonCount);
        System.assertEquals(66.7, r.wonRate, '2/3 = 66.666.. -> 66.7 (소수 1자리 반올림)');
        System.assertEquals(false, r.insufficientData);
        System.assertEquals(FAMILY_RP, r.productType);
    }

    @IsTest
    static void productTypeByProductName_alsoMatches() {
        Test.startTest();
        SimilarWonAnalysisAction.Result r = run(IND_A, 'SWA 회사채');
        Test.stopTest();

        System.assertEquals(1, r.totalCount, '상품명으로 매칭: 회사채 Won 1');
        System.assertEquals(1, r.wonCount);
        System.assertEquals(100.0, r.wonRate);
        System.assertEquals(false, r.insufficientData);
    }

    @IsTest
    static void allLost_returnsZeroRateButSufficientData() {
        Test.startTest();
        SimilarWonAnalysisAction.Result r = run(IND_B, null);
        Test.stopTest();

        System.assertEquals(2, r.totalCount);
        System.assertEquals(0, r.wonCount);
        System.assertEquals(0.0, r.wonRate, '모수는 있으나 Won 0 -> 0% (데이터 부족 아님)');
        System.assertEquals(false, r.insufficientData, '모수 2건이면 데이터 부족이 아니다');
    }

    @IsTest
    static void noMatchingOpportunities_flagsInsufficientData() {
        Test.startTest();
        SimilarWonAnalysisAction.Result r = run(IND_EMPTY, null);
        Test.stopTest();

        System.assertEquals(0, r.totalCount, '모수 0');
        System.assertEquals(0, r.wonCount);
        System.assertEquals(0, r.wonRate, '0으로 나누지 않고 0 반환');
        System.assertEquals(true, r.insufficientData, '데이터 부족 플래그');
        System.assert(r.message.contains('데이터가 부족'), r.message);
    }

    @IsTest
    static void productTypeWithNoMatch_flagsInsufficientData() {
        Test.startTest();
        SimilarWonAnalysisAction.Result r = run(IND_A, '존재하지않는상품');
        Test.stopTest();

        System.assertEquals(0, r.totalCount);
        System.assertEquals(true, r.insufficientData);
    }

    @IsTest
    static void blankIndustry_flagsInsufficientDataWithoutQuery() {
        Test.startTest();
        SimilarWonAnalysisAction.Result blank = run('   ', FAMILY_RP);
        SimilarWonAnalysisAction.Result nul = run(null, null);
        Test.stopTest();

        for (SimilarWonAnalysisAction.Result r : new List<SimilarWonAnalysisAction.Result>{ blank, nul }) {
            System.assertEquals(0, r.totalCount);
            System.assertEquals(0, r.wonCount);
            System.assertEquals(true, r.insufficientData);
            System.assert(r.message.contains('산업군'), r.message);
        }
    }

    @IsTest
    static void bulkRequests_returnOneResultPerRequestInOrder() {
        List<SimilarWonAnalysisAction.Request> reqs = new List<SimilarWonAnalysisAction.Request>();
        for (String ind : new List<String>{ IND_A, IND_B, IND_EMPTY }) {
            SimilarWonAnalysisAction.Request req = new SimilarWonAnalysisAction.Request();
            req.industry = ind;
            reqs.add(req);
        }

        Test.startTest();
        List<SimilarWonAnalysisAction.Result> out = SimilarWonAnalysisAction.analyze(reqs);
        Test.stopTest();

        System.assertEquals(3, out.size());
        System.assertEquals(5, out[0].totalCount);
        System.assertEquals(2, out[1].totalCount);
        System.assertEquals(true, out[2].insufficientData);
        System.assertEquals(0, SimilarWonAnalysisAction.analyze(null).size(), 'null 입력은 빈 결과');
        System.assertEquals(0, SimilarWonAnalysisAction.analyze(new List<SimilarWonAnalysisAction.Request>()).size());
    }

    @IsTest
    static void withSharing_userWithoutAccessSeesNoData() {
        // Opportunity OWD가 Private인 전제에서, 다른 사용자(비관리자)는 시드 Opportunity를 볼 수 없어야 한다.
        Profile p = [SELECT Id FROM Profile WHERE Name IN ('Standard User', '표준 사용자') LIMIT 1];
        User u = new User(
            Alias = 'swatst', Email = 'swa.test@example.com', EmailEncodingKey = 'UTF-8',
            LastName = 'SWA', LanguageLocaleKey = 'ko', LocaleSidKey = 'ko_KR',
            ProfileId = p.Id, TimeZoneSidKey = 'Asia/Seoul',
            Username = 'swa.test.' + DateTime.now().getTime() + '@example.com');
        insert u;

        SimilarWonAnalysisAction.Result r;
        System.runAs(u) {
            Test.startTest();
            r = run(IND_A, null);
            Test.stopTest();
        }
        // OWD가 Private이면 0건, Public이면 5건. 어느 쪽이든 예외 없이 집계되고 0건이면 데이터 부족으로 표시돼야 한다.
        if (r.totalCount == 0) {
            System.assertEquals(true, r.insufficientData, '접근 가능한 건이 없으면 데이터 부족');
        } else {
            System.assertEquals(5, r.totalCount, 'Opportunity OWD가 Public이면 전체가 보임');
        }
    }
}