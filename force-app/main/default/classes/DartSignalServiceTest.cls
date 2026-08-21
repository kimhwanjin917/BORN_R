/**
 * DartSignalService / DartSignalQueueable 테스트.
 * 공시 시그널의 정상 수집, 관심 키워드 필터링, 중복 제외(Source_URL 자연키),
 * 데이터 없음/오류 응답 처리, 그리고 Queueable 재처리·최종 실패 알림을
 * HttpCalloutMock 으로 검증한다.
 */
@isTest
private class DartSignalServiceTest {
    private static final String CORP_CODE = '00126380';
    private static final String BEGIN_DATE = '20230101';
    private static final String END_DATE = '20231231';
    private static final String VIEWER_URL = 'https://dart.fss.or.kr/dsaf001/main.do?rcpNo=';

    // 관심 공시 2건(설비투자·차입) + 무관 공시 1건을 반환하는 정상 응답 mock.
    private static final String CAPEX_RCEPT_NO = '20230101000001';
    private static final String DEBT_RCEPT_NO = '20230201000002';
    private static final String CAPEX_KEY = CORP_CODE + '_' + CAPEX_RCEPT_NO;
    private static final String DEBT_KEY = CORP_CODE + '_' + DEBT_RCEPT_NO;

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
                    },
                    new Map<String, Object>{
                        'report_nm' => '회사채 발행결정',
                        'rcept_no' => DEBT_RCEPT_NO,
                        'rcept_dt' => '20230210',
                        'corp_name' => '테스트법인',
                        'flr_nm' => '테스트법인'
                    },
                    new Map<String, Object>{
                        'report_nm' => '현금·현물배당 결정',
                        'rcept_no' => '20230301000003',
                        'rcept_dt' => '20230305',
                        'corp_name' => '테스트법인',
                        'flr_nm' => '테스트법인'
                    }
                }
            }));
            return response;
        }
    }

    // 조회 데이터 없음(status=013) 응답 mock.
    private class NoDataMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setBody(JSON.serialize(new Map<String, Object>{
                'status' => '013',
                'message' => '조회된 데이터가 없습니다.'
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
    static void shouldInsertSignals_WhenSuccessResponse() {
        // Given
        User dartUser = TestDataFactory.createDartUser();
        DartSignalService.testCrtfcKey = 'TEST_KEY';
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        // When
        System.runAs(dartUser) {
            Account account = TestDataFactory.createAccount(CORP_CODE, true);
            Test.startTest();
            DartSignalService.collectSignals(CORP_CODE, BEGIN_DATE, END_DATE);
            Test.stopTest();

            // Then: 설비투자·차입 2건만 적재되고 무관 공시는 제외되어야 한다
            List<ExternalSignal__c> signals = [
                SELECT Account__c, External_Key__c, Signal_Type__c, Title__c, Signal_Date__c,
                       Source_URL__c, Relevance_Score__c, Confidence__c
                FROM ExternalSignal__c
                ORDER BY External_Key__c
            ];
            Assert.areEqual(2, signals.size(), '설비투자·차입 공시 2건만 적재되어야 한다');

            Map<String, ExternalSignal__c> byKey = new Map<String, ExternalSignal__c>();
            for (ExternalSignal__c s : signals) {
                byKey.put(s.External_Key__c, s);
            }
            ExternalSignal__c capex = byKey.get(CAPEX_KEY);
            ExternalSignal__c debt = byKey.get(DEBT_KEY);
            Assert.isNotNull(capex, '설비투자 공시가 적재되어야 한다');
            Assert.isNotNull(debt, '차입 공시가 적재되어야 한다');
            Assert.areEqual(account.Id, capex.Account__c, 'corp_code 로 Account 가 매핑되어야 한다');
            Assert.areEqual(VIEWER_URL + CAPEX_RCEPT_NO, capex.Source_URL__c, '뷰어 URL 이 저장되어야 한다');
            Assert.areEqual('공시', capex.Signal_Type__c, '시그널 유형은 공시여야 한다');
            Assert.areEqual(Date.newInstance(2023, 1, 15), capex.Signal_Date__c, 'rcept_dt 가 파싱되어야 한다');
            Assert.areEqual(60, capex.Relevance_Score__c, '설비투자 공시 관련도는 60 이어야 한다');
            Assert.areEqual(80, debt.Relevance_Score__c, '차입 공시 관련도는 80 이어야 한다');
            Assert.areEqual(70, capex.Confidence__c, '신뢰도는 70 이어야 한다');
        }
    }

    @isTest
    static void shouldUpsertNotDuplicate_WhenExternalKeyExists() {
        // Given: 설비투자 공시가 이미 적재되어 있다(External_Key 중복)
        User dartUser = TestDataFactory.createDartUser();
        DartSignalService.testCrtfcKey = 'TEST_KEY';
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        // When
        System.runAs(dartUser) {
            Account account = TestDataFactory.createAccount(CORP_CODE, true);
            TestDataFactory.createExternalSignal(account, CAPEX_KEY, true);

            Test.startTest();
            DartSignalService.collectSignals(CORP_CODE, BEGIN_DATE, END_DATE);
            Test.stopTest();

            // Then: 기존 공시는 upsert 로 갱신되고, 새 차입 공시만 추가되어야 한다
            Integer capexCount = [
                SELECT COUNT() FROM ExternalSignal__c WHERE External_Key__c = :CAPEX_KEY
            ];
            Integer debtCount = [
                SELECT COUNT() FROM ExternalSignal__c WHERE External_Key__c = :DEBT_KEY
            ];
            Integer total = [SELECT COUNT() FROM ExternalSignal__c];
            Assert.areEqual(1, capexCount, '기존 키는 중복되지 않고 1건이어야 한다');
            Assert.areEqual(1, debtCount, '새 차입 공시는 적재되어야 한다');
            Assert.areEqual(2, total, '총 2건(갱신 1 + 신규 1)이어야 한다');

            // upsert 로 기존 레코드가 실제 공시 제목으로 갱신되었는지 확인
            ExternalSignal__c updated = [
                SELECT Title__c FROM ExternalSignal__c WHERE External_Key__c = :CAPEX_KEY LIMIT 1
            ];
            Assert.areEqual('유형자산 취득결정', updated.Title__c,
                '기존 레코드가 수집된 공시 제목으로 갱신되어야 한다');
        }
    }

    @isTest
    static void shouldNotInsert_WhenNoDataStatus() {
        // Given: status=013(조회 데이터 없음)
        User dartUser = TestDataFactory.createDartUser();
        DartSignalService.testCrtfcKey = 'TEST_KEY';
        Test.setMock(HttpCalloutMock.class, new NoDataMock());

        // When
        System.runAs(dartUser) {
            TestDataFactory.createAccount(CORP_CODE, true);
            Test.startTest();
            List<ExternalSignal__c> result =
                DartSignalService.collectSignals(CORP_CODE, BEGIN_DATE, END_DATE);
            Test.stopTest();

            // Then
            Assert.areEqual(0, result.size(), '조회 데이터가 없으면 적재되지 않아야 한다');
            Assert.areEqual(0, [SELECT COUNT() FROM ExternalSignal__c],
                '적재 레코드가 없어야 한다');
        }
    }

    @isTest
    static void shouldThrowRetryable_WhenServerError() {
        // Given
        DartSignalService.testCrtfcKey = 'TEST_KEY';
        Test.setMock(HttpCalloutMock.class, new ServerErrorMock());

        // When / Then
        Test.startTest();
        try {
            DartSignalService.collectSignals(CORP_CODE, BEGIN_DATE, END_DATE);
            Assert.fail('일시적 오류 시 예외가 발생해야 한다');
        } catch (DartSignalService.DartServiceException e) {
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
            DartSignalService.collectSignals(CORP_CODE, BEGIN_DATE, END_DATE);
            Assert.fail('인증키 미설정 시 예외가 발생해야 한다');
        } catch (DartSignalService.DartServiceException e) {
            Assert.isTrue(e.getMessage().contains('인증키'), '인증키 관련 오류여야 한다');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldThrow_WhenBlankArgs() {
        // When / Then: 필수 파라미터 누락 시 예외
        Test.startTest();
        try {
            DartSignalService.collectSignals('', BEGIN_DATE, END_DATE);
            Assert.fail('corpCode 누락 시 예외가 발생해야 한다');
        } catch (DartSignalService.DartServiceException e) {
            Assert.isTrue(e.getMessage().contains('필수'), '필수 파라미터 오류여야 한다');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldClassifyKeywords_ForCapexAndDebt() {
        // 관심 키워드 분류(설비투자·차입) 검증
        Test.startTest();
        Assert.isTrue(DartSignalService.isCapexOrDebt('유형자산 취득결정'), '설비투자 키워드는 관심 대상');
        Assert.isTrue(DartSignalService.isCapexOrDebt('회사채 발행결정'), '차입 키워드는 관심 대상');
        Assert.isTrue(DartSignalService.isDebt('전환사채 발행결정'), '전환사채는 차입으로 분류');
        Assert.isFalse(DartSignalService.isDebt('유형자산 취득결정'), '설비투자는 차입이 아니다');
        Assert.isFalse(DartSignalService.isCapexOrDebt('현금·현물배당 결정'), '무관 공시는 대상이 아니다');
        Test.stopTest();
    }

    @isTest
    static void shouldParseDartDate_ForVariousInputs() {
        // DART 날짜(YYYYMMDD) 파싱 검증
        Test.startTest();
        Assert.areEqual(Date.newInstance(2023, 1, 15),
            DartSignalService.parseDartDate('20230115'), '정상 날짜 파싱');
        Assert.isNull(DartSignalService.parseDartDate(''), '빈 값은 null');
        Assert.isNull(DartSignalService.parseDartDate('2023'), '자릿수 미달은 null');
        Assert.isNull(DartSignalService.parseDartDate('2023011X'), '숫자가 아니면 null');
        Test.stopTest();
    }

    @isTest
    static void shouldCollectSuccessfully_ViaQueueable() {
        // Given
        User dartUser = TestDataFactory.createDartUser();
        DartSignalService.testCrtfcKey = 'TEST_KEY';
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        // When
        System.runAs(dartUser) {
            TestDataFactory.createAccount(CORP_CODE, true);
            Test.startTest();
            System.enqueueJob(new DartSignalQueueable(CORP_CODE, BEGIN_DATE, END_DATE));
            Test.stopTest();

            // Then
            Assert.areEqual(2, [SELECT COUNT() FROM ExternalSignal__c],
                'Queueable 정상 실행 시 관심 공시 2건이 수집되어야 한다');
        }
    }

    @isTest
    static void shouldReEnqueue_WhenTransientErrorAndRetriesRemain() {
        // Given: 일시적 오류(500) + 첫 시도(attempt 0 < maxRetry)
        DartSignalService.testCrtfcKey = 'TEST_KEY';
        Test.setMock(HttpCalloutMock.class, new ServerErrorMock());

        // When: execute 가 실패를 감지하고 재시도 재큐 경로를 타야 한다
        Test.startTest();
        new DartSignalQueueable(CORP_CODE, BEGIN_DATE, END_DATE).execute(null);
        Test.stopTest();

        // Then
        Assert.isNotNull(DartSignalQueueable.retryEnqueued, '일시적 오류 시 재시도가 재큐되어야 한다');
        Assert.areEqual(0, DartSignalQueueable.sentEmails.size(),
            '재시도가 남아있으면 관리자 알림은 아직 발송되지 않아야 한다');
    }

    @isTest
    static void shouldNotifyAdmin_WhenQueueableFailsFinally() {
        // Given: 최종 실패 시 관리자 알림 경로
        DartSignalService.testCrtfcKey = 'TEST_KEY';
        DartSignalQueueable.testAdminEmail = 'admin@example.com';

        // When: notifyAdmin 을 직접 겨냥해 검증한다.
        DartSignalQueueable queueable =
            new DartSignalQueueable(CORP_CODE, BEGIN_DATE, END_DATE);
        Test.startTest();
        queueable.notifyAdmin(new DartSignalService.DartServiceException('DART 일시적 오류'), 3);
        Test.stopTest();

        // Then
        Assert.areEqual(1, DartSignalQueueable.sentEmails.size(),
            '최종 실패 시 관리자 이메일 1건이 발송되어야 한다');
        Assert.areEqual(new List<String>{ 'admin@example.com' },
            DartSignalQueueable.sentEmails[0].getToAddresses(),
            '설정된 관리자 주소로 발송되어야 한다');
    }
}