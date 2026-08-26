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
                    new Map<String, Object>{ 'sj_div' => 'BS', 'account_nm' => '현금및현금성자산', 'thstrm_amount' => '1,000,000' },
                    new Map<String, Object>{ 'sj_div' => 'BS', 'account_nm' => '자산총계', 'thstrm_amount' => '5,000,000' },
                    new Map<String, Object>{ 'sj_div' => 'BS', 'account_nm' => '부채총계', 'thstrm_amount' => '2,000,000' },
                    new Map<String, Object>{ 'sj_div' => 'IS', 'account_id' => 'ifrs-full_Revenue', 'account_nm' => '매출액', 'thstrm_amount' => '8,000,000' },
                    new Map<String, Object>{ 'sj_div' => 'IS', 'account_id' => 'dart_OperatingIncomeLoss', 'account_nm' => '영업이익', 'thstrm_amount' => '1,200,000' },
                    // 표준계정코드(account_id) 기반 신규 필드 — 재무상태표(BS)
                    new Map<String, Object>{ 'sj_div' => 'BS', 'account_id' => 'ifrs-full_ShorttermDepositsNotClassifiedAsCashEquivalents', 'account_nm' => '단기금융상품', 'thstrm_amount' => '500,000' },
                    new Map<String, Object>{ 'sj_div' => 'BS', 'account_id' => 'ifrs-full_Equity', 'account_nm' => '자본총계', 'thstrm_amount' => '3,000,000' },
                    new Map<String, Object>{ 'sj_div' => 'BS', 'account_id' => 'ifrs-full_ShorttermBorrowings', 'account_nm' => '단기차입금', 'thstrm_amount' => '400,000' },
                    new Map<String, Object>{ 'sj_div' => 'BS', 'account_id' => 'ifrs-full_CurrentLoansReceivedAndCurrentPortionOfNoncurrentLoansReceived', 'account_nm' => '유동성장기차입금', 'thstrm_amount' => '100,000' },
                    new Map<String, Object>{ 'sj_div' => 'BS', 'account_id' => 'ifrs-full_NoncurrentPortionOfNoncurrentLoansReceived', 'account_nm' => '비유동 장기차입금', 'thstrm_amount' => '600,000' },
                    new Map<String, Object>{ 'sj_div' => 'BS', 'account_id' => 'ifrs-full_CurrentBondsIssuedAndCurrentPortionOfNoncurrentBondsIssued', 'account_nm' => '유동성사채', 'thstrm_amount' => '200,000' },
                    new Map<String, Object>{ 'sj_div' => 'BS', 'account_id' => 'ifrs-full_NoncurrentPortionOfNoncurrentBondsIssued', 'account_nm' => '사채', 'thstrm_amount' => '300,000' },
                    // 자본변동표(SCE)의 자본총계 중복 행 — BS 만 담기므로 무시되어야 한다
                    new Map<String, Object>{ 'sj_div' => 'SCE', 'account_id' => 'ifrs-full_Equity', 'account_nm' => '자본총계', 'thstrm_amount' => '99,999,999' }
                }
            });
        }
    }

    /**
     * 단일법인(연결재무제표 미작성)을 흉내내는 mock.
     * CFS 요청에는 013(데이터 없음), OFS 요청에는 정상(000)을 반환한다.
     */
    private class SeparateOnlyMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            if (request.getEndpoint().contains('fs_div=OFS')) {
                // 무차입 단일법인: 자본총계는 있으나 차입금·사채 표준계정코드가 전혀 없다.
                response.setBody(JSON.serialize(new Map<String, Object>{
                    'status' => '000',
                    'message' => '정상',
                    'list' => new List<Map<String, Object>>{
                        new Map<String, Object>{ 'sj_div' => 'BS', 'account_nm' => '현금및현금성자산', 'thstrm_amount' => '3,000,000' },
                        new Map<String, Object>{ 'sj_div' => 'BS', 'account_nm' => '자산총계', 'thstrm_amount' => '10,000,000' },
                        new Map<String, Object>{ 'sj_div' => 'BS', 'account_id' => 'ifrs-full_Equity', 'account_nm' => '자본총계', 'thstrm_amount' => '7,000,000' }
                    }
                }));
            } else {
                response.setBody(JSON.serialize(new Map<String, Object>{
                    'status' => '013',
                    'message' => '조회된 데이타가 없습니다.'
                }));
            }
            return response;
        }
    }

    /**
     * 차입금 표준계정코드를 쓰지 않는 회사(예: 성우하이텍)를 흉내내는 mock.
     * 차입금은 리스부채 포함 합산 계정명으로만, 사채는 별도 계정으로 공시한다.
     */
    private class NameOnlyBorrowingMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setBody(JSON.serialize(new Map<String, Object>{
                'status' => '000',
                'message' => '정상',
                'list' => new List<Map<String, Object>>{
                    new Map<String, Object>{ 'sj_div' => 'BS', 'account_nm' => '현금및현금성자산', 'thstrm_amount' => '2,000,000' },
                    new Map<String, Object>{ 'sj_div' => 'BS', 'account_nm' => '자산총계', 'thstrm_amount' => '20,000,000' },
                    new Map<String, Object>{ 'sj_div' => 'BS', 'account_id' => 'ifrs-full_Equity', 'account_nm' => '자본총계', 'thstrm_amount' => '8,000,000' },
                    // 차입금: 표준계정코드 없이 계정명으로만. 유동=단기, 비유동=장기로 잡혀야 한다.
                    new Map<String, Object>{ 'sj_div' => 'BS', 'account_nm' => '유동 리스부채를 포함한 유동 차입금 및 비유동차입금의 유동성 대체 부분 합계', 'thstrm_amount' => '1,000,000' },
                    new Map<String, Object>{ 'sj_div' => 'BS', 'account_nm' => '비유동 리스부채를 포함한 총 비유동차입금의 비유동성 부분', 'thstrm_amount' => '700,000' },
                    // 사채는 별도 계정명으로 공시
                    new Map<String, Object>{ 'sj_div' => 'BS', 'account_nm' => '사채', 'thstrm_amount' => '500,000' },
                    // 차입금과 사채를 합친 상위 합계 계정 — 이중계상 방지를 위해 무시되어야 한다
                    new Map<String, Object>{ 'sj_div' => 'BS', 'account_nm' => '차입금및사채', 'thstrm_amount' => '9,999,999' }
                }
            }));
            return response;
        }
    }

    /**
     * 매출을 계정명 '매출액' 이 아니라 '수익(매출액)' 으로, 영업이익을 '영업이익(손실)' 로
     * 공시하는 회사(예: 성우하이텍·하나마이크론)를 흉내내는 mock.
     * 계정명 매칭으로는 잡히지 않고 표준계정코드로만 잡혀야 한다.
     */
    private class StdCodeRevenueMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setBody(JSON.serialize(new Map<String, Object>{
                'status' => '000',
                'message' => '정상',
                'list' => new List<Map<String, Object>>{
                    new Map<String, Object>{ 'sj_div' => 'BS', 'account_nm' => '현금및현금성자산', 'thstrm_amount' => '1,000,000' },
                    new Map<String, Object>{ 'sj_div' => 'BS', 'account_nm' => '자산총계', 'thstrm_amount' => '5,000,000' },
                    // 매출·영업이익: 계정명은 '매출액'/'영업이익'과 다르지만 표준계정코드는 존재
                    new Map<String, Object>{ 'sj_div' => 'CIS', 'account_id' => 'ifrs-full_Revenue', 'account_nm' => '수익(매출액)', 'thstrm_amount' => '9,000,000' },
                    new Map<String, Object>{ 'sj_div' => 'CIS', 'account_id' => 'dart_OperatingIncomeLoss', 'account_nm' => '영업이익(손실)', 'thstrm_amount' => '1,500,000' }
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
                SELECT External_Key__c, Account__c, Fiscal_Year__c, Period_Type__c, CurrencyIsoCode,
                       Cash_And_Equivalents__c, Total_Assets__c, Total_Debt__c,
                       Revenue__c, Operating_Income__c, Cash_Asset_Ratio__c,
                       Short_Term_Financial_Instruments__c, Total_Equity__c,
                       Short_Term_Borrowings__c, Long_Term_Borrowings__c, Bonds_Payable__c
                FROM CorporateFinancialStatement__c
                WHERE External_Key__c = :(CORP_CODE + '_' + BUSINESS_YEAR + '_' + REPORT_CODE)
            ];
            Assert.areEqual(account.Id, saved.Account__c, 'corp_code 로 Account 가 매핑되어야 한다');
            Assert.areEqual(2023, saved.Fiscal_Year__c, '사업연도가 저장되어야 한다');
            Assert.areEqual('4분기', saved.Period_Type__c, '11011(사업보고서) 은 4분기로 매핑되어야 한다');
            Assert.areEqual('KRW', saved.CurrencyIsoCode, 'DART 재무는 원 단위이므로 통화는 KRW로 고정되어야 한다');
            Assert.areEqual(1000000, saved.Cash_And_Equivalents__c, '현금및현금성자산');
            Assert.areEqual(5000000, saved.Total_Assets__c, '자산총계');
            Assert.areEqual(2000000, saved.Total_Debt__c, '부채총계');
            Assert.areEqual(8000000, saved.Revenue__c, '매출액');
            Assert.areEqual(1200000, saved.Operating_Income__c, '영업이익');
            Assert.areEqual(20.00, saved.Cash_Asset_Ratio__c, '현금자산비율 = 1,000,000/5,000,000*100');
            Assert.areEqual(500000, saved.Short_Term_Financial_Instruments__c, '단기금융상품(표준계정코드)');
            Assert.areEqual(3000000, saved.Total_Equity__c, '자본총계는 BS 값(3,000,000)이어야 하고 SCE 중복행(99,999,999)은 무시되어야 한다');
            Assert.areEqual(500000, saved.Short_Term_Borrowings__c, '단기차입금 = 단기차입금 400,000 + 유동성장기차입금 100,000');
            Assert.areEqual(600000, saved.Long_Term_Borrowings__c, '비유동 장기차입금 600,000');
            Assert.areEqual(500000, saved.Bonds_Payable__c, '사채 = 유동성사채 200,000 + 비유동사채 300,000');
        }
    }

    @isTest
    static void shouldCaptureRevenue_ViaStandardCode_WhenAccountNameDiffers() {
        // Given: 매출을 '수익(매출액)', 영업이익을 '영업이익(손실)'로 공시하는 회사
        User dartUser = TestDataFactory.createDartUser();
        DartFinancialService.testCrtfcKey = 'TEST_KEY';
        Test.setMock(HttpCalloutMock.class, new StdCodeRevenueMock());

        // When
        System.runAs(dartUser) {
            TestDataFactory.createAccount(CORP_CODE, true);
            Test.startTest();
            DartFinancialService.collectFinancials(CORP_CODE, BUSINESS_YEAR, REPORT_CODE);
            Test.stopTest();

            // Then: 계정명이 '매출액'/'영업이익'이 아니어도 표준계정코드로 값이 잡혀야 한다
            CorporateFinancialStatement__c saved = [
                SELECT Revenue__c, Operating_Income__c
                FROM CorporateFinancialStatement__c
                WHERE External_Key__c = :(CORP_CODE + '_' + BUSINESS_YEAR + '_' + REPORT_CODE)
            ];
            Assert.areEqual(9000000, saved.Revenue__c, 'ifrs-full_Revenue 표준계정코드로 매출이 잡혀야 한다');
            Assert.areEqual(1500000, saved.Operating_Income__c, 'dart_OperatingIncomeLoss 표준계정코드로 영업이익이 잡혀야 한다');
        }
    }

    @isTest
    static void shouldFallBackToSeparate_WhenConsolidatedHasNoData() {
        // Given: 연결재무제표(CFS)는 013, 별도재무제표(OFS)는 정상인 단일법인
        User dartUser = TestDataFactory.createDartUser();
        DartFinancialService.testCrtfcKey = 'TEST_KEY';
        Test.setMock(HttpCalloutMock.class, new SeparateOnlyMock());

        // When
        System.runAs(dartUser) {
            TestDataFactory.createAccount(CORP_CODE, true);
            Test.startTest();
            DartFinancialService.collectFinancials(CORP_CODE, BUSINESS_YEAR, REPORT_CODE);
            Test.stopTest();

            // Then: CFS 013 후 OFS 로 폴백해 별도재무제표 값이 저장되어야 한다
            CorporateFinancialStatement__c saved = [
                SELECT Cash_And_Equivalents__c, Total_Assets__c, Cash_Asset_Ratio__c,
                       Total_Equity__c, Short_Term_Borrowings__c, Long_Term_Borrowings__c, Bonds_Payable__c
                FROM CorporateFinancialStatement__c
                WHERE External_Key__c = :(CORP_CODE + '_' + BUSINESS_YEAR + '_' + REPORT_CODE)
            ];
            Assert.areEqual(3000000, saved.Cash_And_Equivalents__c, 'OFS 현금및현금성자산이 저장되어야 한다');
            Assert.areEqual(10000000, saved.Total_Assets__c, 'OFS 자산총계가 저장되어야 한다');
            Assert.areEqual(30.00, saved.Cash_Asset_Ratio__c, '현금자산비율 = 3,000,000/10,000,000*100');
            Assert.areEqual(7000000, saved.Total_Equity__c, 'OFS 자본총계(표준계정코드)가 저장되어야 한다');
            // 무차입 회사: 차입금·사채 표준계정코드가 없으면 0 이 아니라 null 이어야 한다
            Assert.isNull(saved.Short_Term_Borrowings__c, '차입금 항목이 없으면 단기차입금은 null');
            Assert.isNull(saved.Long_Term_Borrowings__c, '차입금 항목이 없으면 장기차입금은 null');
            Assert.isNull(saved.Bonds_Payable__c, '사채 항목이 없으면 사채는 null');
        }
    }

    @isTest
    static void shouldFallBackToAccountName_WhenNoBorrowingStdCodes() {
        // Given: 차입금 표준계정코드가 없고 계정명으로만 공시하는 회사
        User dartUser = TestDataFactory.createDartUser();
        DartFinancialService.testCrtfcKey = 'TEST_KEY';
        Test.setMock(HttpCalloutMock.class, new NameOnlyBorrowingMock());

        // When
        System.runAs(dartUser) {
            TestDataFactory.createAccount(CORP_CODE, true);
            Test.startTest();
            DartFinancialService.collectFinancials(CORP_CODE, BUSINESS_YEAR, REPORT_CODE);
            Test.stopTest();

            // Then: 계정명 폴백으로 유동=단기, 비유동=장기, 사채가 잡히고 합계 계정은 무시되어야 한다
            CorporateFinancialStatement__c saved = [
                SELECT Total_Equity__c, Short_Term_Borrowings__c,
                       Long_Term_Borrowings__c, Bonds_Payable__c
                FROM CorporateFinancialStatement__c
                WHERE External_Key__c = :(CORP_CODE + '_' + BUSINESS_YEAR + '_' + REPORT_CODE)
            ];
            Assert.areEqual(8000000, saved.Total_Equity__c, '자본총계는 표준계정코드로 정상 저장');
            Assert.areEqual(1000000, saved.Short_Term_Borrowings__c, '유동 차입금 계정명 → 단기차입금');
            Assert.areEqual(700000, saved.Long_Term_Borrowings__c, '비유동 차입금 계정명 → 장기차입금');
            Assert.areEqual(500000, saved.Bonds_Payable__c, '사채 계정명 → 사채');
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

    @isTest
    static void subtractIfCumulative_onlyWhenAnnualExceedsQuarterSum() {
        // 연간(누적)이 세 분기 합보다 크면 당분기(연간-합)로 차감
        Assert.areEqual(25,
            DartFinancialService.subtractIfCumulative(100, 30, 25, 20),
            '연간 100 - (30+25+20)=25 당분기가 되어야 한다');
        // 이미 당분기(합 이하)면 원값 유지(멱등)
        Assert.areEqual(25,
            DartFinancialService.subtractIfCumulative(25, 30, 25, 20),
            '이미 당분기면 변경되지 않아야 한다');
        // 분기값이 하나라도 null 이면 원값 유지
        Assert.areEqual(100,
            DartFinancialService.subtractIfCumulative(100, null, 25, 20),
            '분기값 누락 시 연간 원값을 유지해야 한다');
    }
}