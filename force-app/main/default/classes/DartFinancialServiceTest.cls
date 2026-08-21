/**
 * DartFinancialService / DartCollectionQueueable 테스트.
 * 정상 수집, 일시적 오류 재처리, 최종 실패 시 관리자 알림을 HttpCalloutMock 으로 검증한다.
 */
@isTest
private class DartFinancialServiceTest {
    private static final String CORP_CODE = '00126380';
    private static final String BUSINESS_YEAR = '2023';
    private static final String REPORT_CODE = '11011';

    /**
     * DART 정상 응답(status=000)을 흉내내는 mock.
     */
    private class SuccessMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setBody(buildBody());
            return response;
        }
        private String buildBody() {
            return JSON.serialize(new Map<String, Object>{
                'status' => '000',
                'message' => '정상',
                'list' => new List<Map<String, Object>>{
                    new Map<String, Object>{ 'account_nm' => '현금및현금성자산', 'thstrm_amount' => '1,000,000' },
                    new Map<String, Object>{ 'account_nm' => '자산총계', 'thstrm_amount' => '5,000,000' },
                    new Map<String, Object>{ 'account_nm' => '부채총계', 'thstrm_amount' => '2,000,000' },
                    new Map<String, Object>{ 'account_nm' => '매출액', 'thstrm_amount' => '8,000,000' },
                    new Map<String, Object>{ 'account_nm' => '영업이익', 'thstrm_amount' => '1,200,000' }
                }
            });
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
    static void shouldUpsertFinancials_WhenSuccessResponse() {
        // Given
        User dartUser = TestDataFactory.createDartUser();
        DartFinancialService.testCrtfcKey = 'TEST_KEY';
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        // When
        System.runAs(dartUser) {
            Account account = TestDataFactory.createAccount(CORP_CODE, true);
            Test.startTest();
            DartFinancialService.collectFinancials(CORP_CODE, BUSINESS_YEAR, REPORT_CODE);
            Test.stopTest();

            // Then
            CorporateFinancialStatement__c saved = [
                SELECT External_Key__c, Account__c, Fiscal_Year__c, Period_Type__c,
                       Cash_And_Equivalents__c, Total_Assets__c, Total_Debt__c,
                       Revenue__c, Operating_Income__c, Cash_Asset_Ratio__c
                FROM CorporateFinancialStatement__c
                WHERE External_Key__c = :(CORP_CODE + '_' + BUSINESS_YEAR + '_' + REPORT_CODE)
            ];
            Assert.areEqual(account.Id, saved.Account__c, 'corp_code 로 Account 가 매핑되어야 한다');
            Assert.areEqual(2023, saved.Fiscal_Year__c, '사업연도가 저장되어야 한다');
            Assert.areEqual('연간', saved.Period_Type__c, '11011 은 연간으로 매핑되어야 한다');
            Assert.areEqual(1000000, saved.Cash_And_Equivalents__c, '현금및현금성자산');
            Assert.areEqual(5000000, saved.Total_Assets__c, '자산총계');
            Assert.areEqual(2000000, saved.Total_Debt__c, '부채총계');
            Assert.areEqual(8000000, saved.Revenue__c, '매출액');
            Assert.areEqual(1200000, saved.Operating_Income__c, '영업이익');
            Assert.areEqual(20.00, saved.Cash_Asset_Ratio__c, '현금자산비율 = 1,000,000/5,000,000*100');
        }
    }

    @isTest
    static void shouldUpsertNotDuplicate_WhenCalledTwice() {
        // Given
        User dartUser = TestDataFactory.createDartUser();
        DartFinancialService.testCrtfcKey = 'TEST_KEY';
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        // When: 콜아웃으로 1건 수집한 뒤, 같은 응답을 재수집한다.
        // (한 트랜잭션에서 콜아웃→DML→콜아웃은 불가하므로 두 번째 수집은 stopTest 이후 새 컨텍스트에서 실행)
        System.runAs(dartUser) {
            TestDataFactory.createAccount(CORP_CODE, true);
            Test.startTest();
            DartFinancialService.collectFinancials(CORP_CODE, BUSINESS_YEAR, REPORT_CODE);
            Test.stopTest();

            // 동일 External_Key 로 재수집해도 upsert 로 중복이 생기지 않아야 한다
            DartFinancialService.collectFinancials(CORP_CODE, BUSINESS_YEAR, REPORT_CODE);

            // Then
            Integer count = [
                SELECT COUNT()
                FROM CorporateFinancialStatement__c
                WHERE External_Key__c = :(CORP_CODE + '_' + BUSINESS_YEAR + '_' + REPORT_CODE)
            ];
            Assert.areEqual(1, count, 'External_Key__c upsert 로 중복이 없어야 한다');
        }
    }

    @isTest
    static void shouldThrowRetryable_WhenServerError() {
        // Given
        DartFinancialService.testCrtfcKey = 'TEST_KEY';
        Test.setMock(HttpCalloutMock.class, new ServerErrorMock());

        // When / Then
        Test.startTest();
        try {
            DartFinancialService.collectFinancials(CORP_CODE, BUSINESS_YEAR, REPORT_CODE);
            Assert.fail('일시적 오류 시 예외가 발생해야 한다');
        } catch (DartFinancialService.DartServiceException e) {
            Assert.isTrue(e.getMessage().contains('재시도'), '재시도 대상 메시지여야 한다');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldThrow_WhenKeyMissing() {
        // Given: testCrtfcKey 미설정 → CMDT Default 키도 테스트에서 null
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        // When / Then
        Test.startTest();
        try {
            DartFinancialService.collectFinancials(CORP_CODE, BUSINESS_YEAR, REPORT_CODE);
            Assert.fail('인증키 미설정 시 예외가 발생해야 한다');
        } catch (DartFinancialService.DartServiceException e) {
            Assert.isTrue(e.getMessage().contains('인증키'), '인증키 관련 오류여야 한다');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldNotifyAdmin_WhenQueueableFailsFinally() {
        // Given: 재시도 없이 최종 실패 → 관리자 알림 경로
        DartFinancialService.testCrtfcKey = 'TEST_KEY';
        DartCollectionQueueable.testAdminEmail = 'admin@example.com';
        Test.setMock(HttpCalloutMock.class, new ServerErrorMock());

        // When: 최종 실패 시 알림 경로(notifyAdmin)를 직접 겨냥해 검증한다.
        // (execute→enqueueJob 재큐는 비동기 컨텍스트라 같은 트랜잭션에서 검증 불가)
        DartCollectionQueueable queueable =
            new DartCollectionQueueable(CORP_CODE, BUSINESS_YEAR, REPORT_CODE);
        Test.startTest();
        queueable.notifyAdmin(new DartFinancialService.DartServiceException('DART 일시적 오류'), 3);
        Test.stopTest();

        // Then: 관리자에게 알림 이메일 1건이 구성/발송되어야 한다
        Assert.areEqual(1, DartCollectionQueueable.sentEmails.size(),
            '최종 실패 시 관리자 이메일 1건이 발송되어야 한다');
        Assert.areEqual(new List<String>{ 'admin@example.com' },
            DartCollectionQueueable.sentEmails[0].getToAddresses(),
            '설정된 관리자 주소로 발송되어야 한다');
    }

    @isTest
    static void shouldReEnqueue_WhenTransientErrorAndRetriesRemain() {
        // Given: 일시적 오류(500) + 첫 시도(attempt 0 < maxRetry)
        DartFinancialService.testCrtfcKey = 'TEST_KEY';
        Test.setMock(HttpCalloutMock.class, new ServerErrorMock());

        // When: execute 가 실패를 감지하고 재시도 재큐 경로를 타야 한다
        Test.startTest();
        new DartCollectionQueueable(CORP_CODE, BUSINESS_YEAR, REPORT_CODE).execute(null);
        Test.stopTest();

        // Then: 다음 시도(attempt=1)로 재큐가 예약되고 알림은 아직 발송되지 않아야 한다
        Assert.isNotNull(DartCollectionQueueable.retryEnqueued, '일시적 오류 시 재시도가 재큐되어야 한다');
        Assert.areEqual(0, DartCollectionQueueable.sentEmails.size(),
            '재시도가 남아있으면 관리자 알림은 아직 발송되지 않아야 한다');
    }

    @isTest
    static void shouldCollectSuccessfully_ViaQueueable() {
        // Given
        User dartUser = TestDataFactory.createDartUser();
        DartFinancialService.testCrtfcKey = 'TEST_KEY';
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        // When
        System.runAs(dartUser) {
            Account account = TestDataFactory.createAccount(CORP_CODE, true);
            Test.startTest();
            System.enqueueJob(new DartCollectionQueueable(CORP_CODE, BUSINESS_YEAR, REPORT_CODE));
            Test.stopTest();

            // Then
            Integer count = [
                SELECT COUNT()
                FROM CorporateFinancialStatement__c
                WHERE Account__c = :account.Id
            ];
            Assert.areEqual(1, count, 'Queueable 정상 실행 시 재무제표 1건이 수집되어야 한다');
        }
    }
}