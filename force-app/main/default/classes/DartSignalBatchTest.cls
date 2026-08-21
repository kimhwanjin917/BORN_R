/**
 * DartSignalBatch / DartSignalScheduler 테스트 (백로그 222).
 * DART 공시 시그널 수집 배치의 정상 적재, 일시적 오류 시 재처리 위임,
 * 생성자 검증, 스케줄러의 배치 기동을 HttpCalloutMock 으로 검증한다.
 */
@isTest
private class DartSignalBatchTest {
    private static final String CORP_CODE = '00126380';
    private static final String BEGIN_DATE = '20230101';
    private static final String END_DATE = '20231231';
    private static final String CAPEX_RCEPT_NO = '20230101000001';

    // 관심 공시(설비투자) 1건을 반환하는 정상 응답 mock.
    private class SuccessMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setBody(JSON.serialize(new Map<String, Object>{
                'status' => '000',
                'message' => '정상',
                'list' => new List<Map<String, Object>>{
                    new Map<String, Object>{
                        'report_nm' => '유형자산 취득결정',
                        'rcept_no' => CAPEX_RCEPT_NO,
                        'rcept_dt' => '20230115',
                        'corp_name' => '테스트법인',
                        'flr_nm' => '테스트법인'
                    }
                }
            }));
            return response;
        }
    }

    // HTTP 500 을 반환하는 일시적 오류 mock.
    private class ServerErrorMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(500);
            response.setBody('Internal Server Error');
            return response;
        }
    }

    @isTest
    static void shouldCollectSignals_WhenBatchRunsSuccessfully() {
        // Given
        User dartUser = TestDataFactory.createDartUser();
        DartSignalService.testCrtfcKey = 'TEST_KEY';
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        // When: 회사당 1 execute(콜아웃+upsert)를 보장하기 위해 배치 크기 1 로 실행
        System.runAs(dartUser) {
            TestDataFactory.createAccount(CORP_CODE, true);
            Test.startTest();
            Database.executeBatch(new DartSignalBatch(BEGIN_DATE, END_DATE), 1);
            Test.stopTest();

            // Then
            Integer count = [
                SELECT COUNT()
                FROM ExternalSignal__c
                WHERE External_Key__c = :(CORP_CODE + '_' + CAPEX_RCEPT_NO)
            ];
            Assert.areEqual(1, count, '배치가 담당사 공시 시그널 1건을 수집해야 한다');
        }
    }

    @isTest
    static void shouldNotCollect_WhenBatchHitsTransientError() {
        // Given: 일시적 오류 → 배치가 Queueable 로 재처리를 위임하고 레코드는 생기지 않는다
        User dartUser = TestDataFactory.createDartUser();
        DartSignalService.testCrtfcKey = 'TEST_KEY';
        Test.setMock(HttpCalloutMock.class, new ServerErrorMock());

        // When
        System.runAs(dartUser) {
            TestDataFactory.createAccount(CORP_CODE, true);
            Test.startTest();
            Database.executeBatch(new DartSignalBatch(BEGIN_DATE, END_DATE), 1);
            Test.stopTest();

            // Then
            Integer count = [SELECT COUNT() FROM ExternalSignal__c];
            Assert.areEqual(0, count, '일시적 오류 시 수집 레코드가 없어야 한다(재처리 위임)');
        }
    }

    @isTest
    static void shouldThrow_WhenConstructedWithBlankArgs() {
        // When / Then: 필수 파라미터 누락 시 생성자에서 예외
        Test.startTest();
        try {
            new DartSignalBatch(null, END_DATE);
            Assert.fail('beginDate 누락 시 예외가 발생해야 한다');
        } catch (IllegalArgumentException e) {
            Assert.isTrue(e.getMessage().contains('필수'), '필수 파라미터 오류여야 한다');
        }
        try {
            new DartSignalBatch(BEGIN_DATE, '');
            Assert.fail('endDate 누락 시 예외가 발생해야 한다');
        } catch (IllegalArgumentException e) {
            Assert.isTrue(e.getMessage().contains('필수'), '필수 파라미터 오류여야 한다');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldRunBatch_WhenSchedulerFires() {
        // Given
        User dartUser = TestDataFactory.createDartUser();
        DartSignalService.testCrtfcKey = 'TEST_KEY';
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        // When: 스케줄러 execute 가 배치를 기동해 수집이 일어나야 한다
        System.runAs(dartUser) {
            TestDataFactory.createAccount(CORP_CODE, true);
            Test.startTest();
            new DartSignalScheduler(BEGIN_DATE, END_DATE).execute(null);
            Test.stopTest();

            // Then
            Integer count = [
                SELECT COUNT()
                FROM ExternalSignal__c
                WHERE External_Key__c = :(CORP_CODE + '_' + CAPEX_RCEPT_NO)
            ];
            Assert.areEqual(1, count, '스케줄러가 배치를 기동해 공시 시그널을 수집해야 한다');
        }
    }
}