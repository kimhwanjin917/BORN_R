/**
 * FinlightNewsService / FinlightNewsQueueable / FinlightNewsBatch / FinlightNewsScheduler 테스트.
 * Finlight 뉴스의 정상 수집(기업명 매핑), Source_URL 자연키 중복 제외, publishDate(ISO 8601) 파싱,
 * 오류/일시적 오류 응답 처리, Queueable 재처리·최종 실패 알림, 배치·스케줄러 진입점을
 * HttpCalloutMock 으로 검증한다.
 */
@isTest
private class FinlightNewsServiceTest {
    private static final String COMPANY_NAME = '코스메카코리아';
    private static final String URL_ONE = 'https://www.mk.co.kr/news/stock/12131555';
    private static final String URL_TWO = 'https://www.yna.co.kr/view/AKR20260819130400008';

    // 뉴스 2건을 반환하는 정상 응답 mock.
    private class SuccessMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setBody(JSON.serialize(new Map<String, Object>{
                'status' => 'ok',
                'page' => 1,
                'pageSize' => 50,
                'articles' => new List<Map<String, Object>>{
                    new Map<String, Object>{
                        'link' => URL_ONE,
                        'source' => 'www.mk.co.kr',
                        'title' => '코스메카코리아 코스피 이전 성공할까',
                        'summary' => 'K뷰티 관심 속 코스메카코리아 실적 개선',
                        'publishDate' => '2026-08-19T10:06:49.000Z',
                        'language' => 'ko',
                        'countries' => new List<String>{ 'KR' }
                    },
                    new Map<String, Object>{
                        'link' => URL_TWO,
                        'source' => 'www.yna.co.kr',
                        'title' => '코스닥 기관 순매수도 상위종목',
                        'summary' => '코스닥 기관 순매수 표',
                        'publishDate' => '2026-08-19T06:45:53.000Z',
                        'language' => 'ko',
                        'countries' => new List<String>{ 'KR' }
                    }
                }
            }));
            return response;
        }
    }

    // articles 가 비어있는 정상 응답 mock.
    private class EmptyMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setBody(JSON.serialize(new Map<String, Object>{
                'status' => 'ok',
                'articles' => new List<Object>()
            }));
            return response;
        }
    }

    // HTTP 401(인증 실패) 응답 mock.
    private class UnauthorizedMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(401);
            response.setBody('{"message":"Unauthorized"}');
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

    private static void setKey() {
        FinlightNewsService.testApiKey = 'sk_test';
    }

    @isTest
    static void shouldInsertSignals_WhenSuccessResponse() {
        // Given
        User apiUser = TestDataFactory.createDartUser();
        setKey();
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        // When
        System.runAs(apiUser) {
            Account account = TestDataFactory.createAccountByName(COMPANY_NAME, true);
            Test.startTest();
            FinlightNewsService.collectNews(COMPANY_NAME);
            Test.stopTest();

            // Then: 뉴스 2건이 적재되고 기업명으로 Account 가 매핑되어야 한다
            List<ExternalSignal__c> signals = [
                SELECT Account__c, Signal_Type__c, Title__c, Summary__c, Signal_Date__c,
                       Source_URL__c, Relevance_Score__c, Confidence__c
                FROM ExternalSignal__c
                ORDER BY Source_URL__c
            ];
            Assert.areEqual(2, signals.size(), '뉴스 2건이 적재되어야 한다');

            ExternalSignal__c first = signals[0];
            Assert.areEqual(account.Id, first.Account__c, '기업명으로 Account 가 매핑되어야 한다');
            Assert.areEqual('뉴스', first.Signal_Type__c, '시그널 유형은 뉴스여야 한다');
            Assert.areEqual(URL_ONE, first.Source_URL__c, 'link 가 출처 URL 로 저장되어야 한다');
            Assert.areEqual('코스메카코리아 코스피 이전 성공할까', first.Title__c, '제목이 저장되어야 한다');
            Assert.areEqual(Date.newInstance(2026, 8, 19), first.Signal_Date__c,
                'publishDate 가 파싱되어야 한다');
        }
    }

    @isTest
    static void shouldSkipDuplicate_WhenSourceUrlExists() {
        // Given: URL_ONE 뉴스가 이미 적재되어 있다(Source_URL 자연키 중복)
        User apiUser = TestDataFactory.createDartUser();
        setKey();
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        // When
        System.runAs(apiUser) {
            Account account = TestDataFactory.createAccountByName(COMPANY_NAME, true);
            ExternalSignal__c existing = new ExternalSignal__c(
                Account__c = account.Id,
                Signal_Type__c = '뉴스',
                Title__c = 'Existing',
                Source_URL__c = URL_ONE
            );
            insert existing;

            Test.startTest();
            FinlightNewsService.collectNews(COMPANY_NAME);
            Test.stopTest();

            // Then: URL_ONE 은 건너뛰고 URL_TWO 만 신규 적재되어 총 2건
            Assert.areEqual(1, [SELECT COUNT() FROM ExternalSignal__c WHERE Source_URL__c = :URL_ONE],
                '기존 URL 은 중복 적재되지 않아야 한다');
            Assert.areEqual(1, [SELECT COUNT() FROM ExternalSignal__c WHERE Source_URL__c = :URL_TWO],
                '새 URL 은 적재되어야 한다');
            Assert.areEqual(2, [SELECT COUNT() FROM ExternalSignal__c],
                '총 2건(기존 1 + 신규 1)이어야 한다');
        }
    }

    @isTest
    static void shouldNotInsert_WhenEmptyArticles() {
        // Given
        User apiUser = TestDataFactory.createDartUser();
        setKey();
        Test.setMock(HttpCalloutMock.class, new EmptyMock());

        // When
        System.runAs(apiUser) {
            TestDataFactory.createAccountByName(COMPANY_NAME, true);
            Test.startTest();
            List<ExternalSignal__c> result = FinlightNewsService.collectNews(COMPANY_NAME);
            Test.stopTest();

            // Then
            Assert.areEqual(0, result.size(), '뉴스가 없으면 적재되지 않아야 한다');
            Assert.areEqual(0, [SELECT COUNT() FROM ExternalSignal__c], '적재 레코드가 없어야 한다');
        }
    }

    @isTest
    static void shouldThrow_WhenUnauthorized() {
        // Given
        setKey();
        Test.setMock(HttpCalloutMock.class, new UnauthorizedMock());

        // When / Then
        Test.startTest();
        try {
            FinlightNewsService.collectNews(COMPANY_NAME);
            Assert.fail('401 응답 시 예외가 발생해야 한다');
        } catch (FinlightNewsService.FinlightNewsException e) {
            Assert.isTrue(e.getMessage().contains('호출 실패'), '호출 실패 메시지여야 한다');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldThrowRetryable_WhenServerError() {
        // Given
        setKey();
        Test.setMock(HttpCalloutMock.class, new ServerErrorMock());

        // When / Then
        Test.startTest();
        try {
            FinlightNewsService.collectNews(COMPANY_NAME);
            Assert.fail('일시적 오류 시 예외가 발생해야 한다');
        } catch (FinlightNewsService.FinlightNewsException e) {
            Assert.isTrue(e.getMessage().contains('재시도'), '재시도 대상 메시지여야 한다');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldThrow_WhenApiKeyMissing() {
        // Given: testApiKey 미설정 → CMDT Default 도 테스트에서 비어있음
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        // When / Then
        Test.startTest();
        try {
            FinlightNewsService.collectNews(COMPANY_NAME);
            Assert.fail('API 키 미설정 시 예외가 발생해야 한다');
        } catch (FinlightNewsService.FinlightNewsException e) {
            Assert.isTrue(e.getMessage().contains('API 키'), 'API 키 관련 오류여야 한다');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldThrow_WhenBlankCompanyName() {
        // When / Then
        Test.startTest();
        try {
            FinlightNewsService.collectNews('');
            Assert.fail('companyName 누락 시 예외가 발생해야 한다');
        } catch (FinlightNewsService.FinlightNewsException e) {
            Assert.isTrue(e.getMessage().contains('필수'), '필수 파라미터 오류여야 한다');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldParsePublishDate_ForVariousInputs() {
        Test.startTest();
        Assert.areEqual(Date.newInstance(2026, 8, 19),
            FinlightNewsService.parsePublishDate('2026-08-19T10:06:49.000Z'), '정상 파싱');
        Assert.isNull(FinlightNewsService.parsePublishDate(''), '빈 값은 null');
        Assert.isNull(FinlightNewsService.parsePublishDate('2026/08'), '형식 미달은 null');
        Test.stopTest();
    }

    @isTest
    static void shouldCollectSuccessfully_ViaQueueable() {
        // Given
        User apiUser = TestDataFactory.createDartUser();
        setKey();
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        // When
        System.runAs(apiUser) {
            TestDataFactory.createAccountByName(COMPANY_NAME, true);
            Test.startTest();
            System.enqueueJob(new FinlightNewsQueueable(COMPANY_NAME));
            Test.stopTest();

            // Then
            Assert.areEqual(2, [SELECT COUNT() FROM ExternalSignal__c],
                'Queueable 정상 실행 시 뉴스 2건이 수집되어야 한다');
        }
    }

    @isTest
    static void shouldReEnqueue_WhenTransientErrorAndRetriesRemain() {
        // Given: 일시적 오류(500) + 첫 시도(attempt 0 < maxRetry)
        setKey();
        Test.setMock(HttpCalloutMock.class, new ServerErrorMock());

        // When
        Test.startTest();
        new FinlightNewsQueueable(COMPANY_NAME).execute(null);
        Test.stopTest();

        // Then
        Assert.isNotNull(FinlightNewsQueueable.retryEnqueued, '일시적 오류 시 재시도가 재큐되어야 한다');
        Assert.areEqual(0, FinlightNewsQueueable.sentEmails.size(),
            '재시도가 남아있으면 관리자 알림은 아직 발송되지 않아야 한다');
    }

    @isTest
    static void shouldNotifyAdmin_WhenQueueableFailsFinally() {
        // Given: 최종 실패 시 관리자 알림 경로
        FinlightNewsQueueable.testAdminEmail = 'admin@example.com';

        // When
        FinlightNewsQueueable queueable = new FinlightNewsQueueable(COMPANY_NAME);
        Test.startTest();
        queueable.notifyAdmin(new FinlightNewsService.FinlightNewsException('Finlight 일시적 오류'), 3);
        Test.stopTest();

        // Then
        Assert.areEqual(1, FinlightNewsQueueable.sentEmails.size(),
            '최종 실패 시 관리자 이메일 1건이 발송되어야 한다');
        Assert.areEqual(new List<String>{ 'admin@example.com' },
            FinlightNewsQueueable.sentEmails[0].getToAddresses(),
            '설정된 관리자 주소로 발송되어야 한다');
    }

    @isTest
    static void shouldCollectSuccessfully_ViaBatch() {
        // Given
        User apiUser = TestDataFactory.createDartUser();
        setKey();
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        // When
        System.runAs(apiUser) {
            TestDataFactory.createAccountByName(COMPANY_NAME, true);
            Test.startTest();
            Database.executeBatch(new FinlightNewsBatch(), 1);
            Test.stopTest();

            // Then
            Assert.areEqual(2, [SELECT COUNT() FROM ExternalSignal__c],
                '배치 실행 시 뉴스 2건이 수집되어야 한다');
        }
    }

    @isTest
    static void shouldScheduleBatch_ViaScheduler() {
        // Given
        setKey();
        Test.setMock(HttpCalloutMock.class, new EmptyMock());

        // When
        Test.startTest();
        String jobId = System.schedule(
            'Finlight News Test Schedule',
            '0 0 6 * * ?',
            new FinlightNewsScheduler()
        );
        Test.stopTest();

        // Then: CRON 등록이 성공해야 한다
        CronTrigger ct = [SELECT Id, CronExpression FROM CronTrigger WHERE Id = :jobId];
        Assert.areEqual('0 0 6 * * ?', ct.CronExpression, '스케줄 CRON 이 등록되어야 한다');
    }
}