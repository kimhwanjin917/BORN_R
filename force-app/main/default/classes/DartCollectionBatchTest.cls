/**
 * DartCollectionBatch / DartCollectionScheduler 테스트.
 * 배치의 정상 수집, 일시적 오류 시 재처리 위임, 생성자 검증과
 * 스케줄러의 배치 기동을 HttpCalloutMock 으로 검증한다.
 */
@isTest
private class DartCollectionBatchTest {
    private static final String CORP_CODE = '00126380';
    private static final String BUSINESS_YEAR = '2023';
    private static final String REPORT_CODE = '11011';
    private static final String EXTERNAL_KEY = CORP_CODE + '_' + BUSINESS_YEAR + '_' + REPORT_CODE;

    /**
     * DART 정상 응답(status=000)을 흉내내는 mock.
     */
    private class SuccessMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setBody(JSON.serialize(new Map<String, Object>{
                'status' => '000',
                'message' => '정상',
                'list' => new List<Map<String, Object>>{
                    new Map<String, Object>{ 'account_nm' => '현금및현금성자산', 'thstrm_amount' => '1,000,000' },
                    new Map<String, Object>{ 'account_nm' => '자산총계', 'thstrm_amount' => '5,000,000' },
                    new Map<String, Object>{ 'account_nm' => '부채총계', 'thstrm_amount' => '2,000,000' },
                    new Map<String, Object>{ 'account_nm' => '매출액', 'thstrm_amount' => '8,000,000' },
                    new Map<String, Object>{ 'account_nm' => '영업이익', 'thstrm_amount' => '1,200,000' }
                }
            }));
            return response;
        }
    }

    /**
     * HTTP 500 을 반환하는 일시적 오류 mock.
     */
    private class ServerErrorMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(500);
            response.setBody('Internal Server Error');
            return response;
        }
    }

    @isTest
    static void shouldCollectFinancials_WhenBatchRunsSuccessfully() {
        // Given
        User dartUser = TestDataFactory.createDartUser();
        DartFinancialService.testCrtfcKey = 'TEST_KEY';
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        // When: 회사당 1 execute(콜아웃+upsert)를 보장하기 위해 배치 크기 1 로 실행
        System.runAs(dartUser) {
            TestDataFactory.createAccount(CORP_CODE, true);
            Test.startTest();
            Database.executeBatch(new DartCollectionBatch(BUSINESS_YEAR, REPORT_CODE), 1);
            Test.stopTest();

            // Then
            Integer count = [
                SELECT COUNT()
                FROM CorporateFinancialStatement__c
                WHERE External_Key__c = :EXTERNAL_KEY
            ];
            Assert.areEqual(1, count, '배치가 담당사 재무제표 1건을 수집해야 한다');
        }
    }

    @isTest
    static void shouldNotCollect_WhenBatchHitsTransientError() {
        // Given: 일시적 오류 → 배치가 Queueable 로 재처리를 위임하고 레코드는 생기지 않는다
        User dartUser = TestDataFactory.createDartUser();
        DartFinancialService.testCrtfcKey = 'TEST_KEY';
        Test.setMock(HttpCalloutMock.class, new ServerErrorMock());

        // When
        System.runAs(dartUser) {
            TestDataFactory.createAccount(CORP_CODE, true);
            Test.startTest();
            Database.executeBatch(new DartCollectionBatch(BUSINESS_YEAR, REPORT_CODE), 1);
            Test.stopTest();

            // Then
            Integer count = [
                SELECT COUNT()
                FROM CorporateFinancialStatement__c
                WHERE External_Key__c = :EXTERNAL_KEY
            ];
            Assert.areEqual(0, count, '일시적 오류 시 수집 레코드가 없어야 한다(재처리 위임)');
        }
    }

    @isTest
    static void shouldThrow_WhenConstructedWithBlankArgs() {
        // When / Then: 필수 파라미터 누락 시 생성자에서 예외
        Test.startTest();
        try {
            new DartCollectionBatch(null, REPORT_CODE);
            Assert.fail('businessYear 누락 시 예외가 발생해야 한다');
        } catch (IllegalArgumentException e) {
            Assert.isTrue(e.getMessage().contains('필수'), '필수 파라미터 오류여야 한다');
        }
        try {
            new DartCollectionBatch(BUSINESS_YEAR, '');
            Assert.fail('reportCode 누락 시 예외가 발생해야 한다');
        } catch (IllegalArgumentException e) {
            Assert.isTrue(e.getMessage().contains('필수'), '필수 파라미터 오류여야 한다');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldRunBatch_WhenSchedulerFires() {
        // Given
        User dartUser = TestDataFactory.createDartUser();
        DartFinancialService.testCrtfcKey = 'TEST_KEY';
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        // When: 스케줄러 execute 가 배치를 기동해 수집이 일어나야 한다
        System.runAs(dartUser) {
            TestDataFactory.createAccount(CORP_CODE, true);
            Test.startTest();
            new DartCollectionScheduler(BUSINESS_YEAR, REPORT_CODE).execute(null);
            Test.stopTest();

            // Then
            Integer count = [
                SELECT COUNT()
                FROM CorporateFinancialStatement__c
                WHERE External_Key__c = :EXTERNAL_KEY
            ];
            Assert.areEqual(1, count, '스케줄러가 배치를 기동해 재무제표를 수집해야 한다');
        }
    }
}