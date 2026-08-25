/**
 * NaverNewsService / NaverNewsQueueable / NaverNewsBatch / NaverNewsScheduler 테스트.
 * 네이버 뉴스의 정상 수집(기업명 매핑), Source_URL 자연키 중복 제외, HTML 태그·pubDate 파싱,
 * 오류/일시적 오류 응답 처리, Queueable 재처리·최종 실패 알림, 배치·스케줄러 진입점을
 * HttpCalloutMock 으로 검증한다.
 */
@isTest
private class NaverNewsServiceTest {
    private static final String COMPANY_NAME = 'Test Corp 00126380';
    private static final String URL_ONE = 'https://news.example.com/article/1';
    private static final String URL_TWO = 'https://news.example.com/article/2';

    // 뉴스 2건을 반환하는 정상 응답 mock(제목에 <b> 태그·HTML 엔티티 포함).
    private class SuccessMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setBody(JSON.serialize(new Map<String, Object>{
                'items' => new List<Map<String, Object>>{
                    new Map<String, Object>{
                        'title' => '<b>Test Corp</b> 신규 &quot;투자&quot; 발표',
                        'originallink' => URL_ONE,
                        'link' => 'https://n.news.example.com/1',
                        'description' => '<b>Test Corp</b>가 신규 투자를 발표했다.',
                        'pubDate' => 'Mon, 26 Sep 2016 07:50:00 +0900'
                    },
                    new Map<String, Object>{
                        'title' => 'Test Corp 실적 개선',
                        'originallink' => URL_TWO,
                        'link' => 'https://n.news.example.com/2',
                        'description' => '실적이 개선되었다.',
                        'pubDate' => 'Tue, 27 Sep 2016 09:00:00 +0900'
                    }
                }
            }));
            return response;
        }
    }

    // items 가 비어있는 정상 응답 mock.
    private class EmptyMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setBody(JSON.serialize(new Map<String, Object>{
                'items' => new List<Object>()
            }));
            return response;
        }
    }

    // 네이버 오류(errorCode) 응답 mock.
    private class ErrorMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setBody(JSON.serialize(new Map<String, Object>{
                'errorCode' => 'SE01',
                'errorMessage' => 'Invalid search api request'
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

    private static void setCredentials() {
        NaverNewsService.testClientId = 'TEST_ID';
        NaverNewsService.testClientSecret = 'TEST_SECRET';
    }

    @isTest
    static void shouldInsertSignals_WhenSuccessResponse() {
        // Given
        User naverUser = TestDataFactory.createDartUser();
        setCredentials();
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        // When
        System.runAs(naverUser) {
            Account account = TestDataFactory.createAccountByName(COMPANY_NAME, true);
            Test.startTest();
            NaverNewsService.collectNews(COMPANY_NAME);
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
            Assert.areEqual(URL_ONE, first.Source_URL__c, 'originallink 가 출처 URL 로 저장되어야 한다');
            Assert.areEqual('Test Corp 신규 "투자" 발표', first.Title__c,
                'HTML 태그·엔티티가 제거·복원되어야 한다');
            Assert.areEqual(Date.newInstance(2016, 9, 26), first.Signal_Date__c,
                'pubDate 가 파싱되어야 한다');
        }
    }

    @isTest
    static void shouldSkipDuplicate_WhenSourceUrlExists() {
        // Given: URL_ONE 뉴스가 이미 적재되어 있다(Source_URL 자연키 중복)
        User naverUser = TestDataFactory.createDartUser();
        setCredentials();
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        // When
        System.runAs(naverUser) {
            Account account = TestDataFactory.createAccountByName(COMPANY_NAME, true);
            ExternalSignal__c existing = new ExternalSignal__c(
                Account__c = account.Id,
                Signal_Type__c = '뉴스',
                Title__c = 'Existing',
                Source_URL__c = URL_ONE
            );
            insert existing;

            Test.startTest();
            NaverNewsService.collectNews(COMPANY_NAME);
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
    static void shouldNotInsert_WhenEmptyItems() {
        // Given
        User naverUser = TestDataFactory.createDartUser();
        setCredentials();
        Test.setMock(HttpCalloutMock.class, new EmptyMock());

        // When
        System.runAs(naverUser) {
            TestDataFactory.createAccountByName(COMPANY_NAME, true);
            Test.startTest();
            List<ExternalSignal__c> result = NaverNewsService.collectNews(COMPANY_NAME);
            Test.stopTest();

            // Then
            Assert.areEqual(0, result.size(), '뉴스가 없으면 적재되지 않아야 한다');
            Assert.areEqual(0, [SELECT COUNT() FROM ExternalSignal__c], '적재 레코드가 없어야 한다');
        }
    }

    @isTest
    static void shouldThrow_WhenNaverErrorResponse() {
        // Given
        setCredentials();
        Test.setMock(HttpCalloutMock.class, new ErrorMock());

        // When / Then
        Test.startTest();
        try {
            NaverNewsService.collectNews(COMPANY_NAME);
            Assert.fail('네이버 오류 응답 시 예외가 발생해야 한다');
        } catch (NaverNewsService.NaverNewsException e) {
            Assert.isTrue(e.getMessage().contains('네이버 오류'), '네이버 오류 메시지여야 한다');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldThrowRetryable_WhenServerError() {
        // Given
        setCredentials();
        Test.setMock(HttpCalloutMock.class, new ServerErrorMock());

        // When / Then
        Test.startTest();
        try {
            NaverNewsService.collectNews(COMPANY_NAME);
            Assert.fail('일시적 오류 시 예외가 발생해야 한다');
        } catch (NaverNewsService.NaverNewsException e) {
            Assert.isTrue(e.getMessage().contains('재시도'), '재시도 대상 메시지여야 한다');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldThrow_WhenCredentialsMissing() {
        // Given: testClientId/Secret 미설정 → CMDT Default 도 테스트에서 비어있음
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        // When / Then
        Test.startTest();
        try {
            NaverNewsService.collectNews(COMPANY_NAME);
            Assert.fail('인증정보 미설정 시 예외가 발생해야 한다');
        } catch (NaverNewsService.NaverNewsException e) {
            Assert.isTrue(e.getMessage().contains('인증정보'), '인증정보 관련 오류여야 한다');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldThrow_WhenBlankCompanyName() {
        // When / Then
        Test.startTest();
        try {
            NaverNewsService.collectNews('');
            Assert.fail('companyName 누락 시 예외가 발생해야 한다');
        } catch (NaverNewsService.NaverNewsException e) {
            Assert.isTrue(e.getMessage().contains('필수'), '필수 파라미터 오류여야 한다');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldCleanText_ForTagsAndEntities() {
        Test.startTest();
        Assert.areEqual('제목', NaverNewsService.cleanText('<b>제목</b>'), 'b 태그 제거');
        Assert.areEqual('a & b "c"',
            NaverNewsService.cleanText('a &amp; b &quot;c&quot;'), '엔티티 복원');
        Assert.isNull(NaverNewsService.cleanText(null), 'null 은 null');
        Test.stopTest();
    }

    @isTest
    static void shouldParsePubDate_ForVariousInputs() {
        Test.startTest();
        Assert.areEqual(Date.newInstance(2016, 9, 26),
            NaverNewsService.parsePubDate('Mon, 26 Sep 2016 07:50:00 +0900'), '정상 파싱');
        Assert.isNull(NaverNewsService.parsePubDate(''), '빈 값은 null');
        Assert.isNull(NaverNewsService.parsePubDate('26 Foo 2016'), '알 수 없는 월은 null');
        Test.stopTest();
    }

    @isTest
    static void shouldCollectSuccessfully_ViaQueueable() {
        // Given
        User naverUser = TestDataFactory.createDartUser();
        setCredentials();
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        // When
        System.runAs(naverUser) {
            TestDataFactory.createAccountByName(COMPANY_NAME, true);
            Test.startTest();
            System.enqueueJob(new NaverNewsQueueable(COMPANY_NAME));
            Test.stopTest();

            // Then
            Assert.areEqual(2, [SELECT COUNT() FROM ExternalSignal__c],
                'Queueable 정상 실행 시 뉴스 2건이 수집되어야 한다');
        }
    }

    @isTest
    static void shouldReEnqueue_WhenTransientErrorAndRetriesRemain() {
        // Given: 일시적 오류(500) + 첫 시도(attempt 0 < maxRetry)
        setCredentials();
        Test.setMock(HttpCalloutMock.class, new ServerErrorMock());

        // When
        Test.startTest();
        new NaverNewsQueueable(COMPANY_NAME).execute(null);
        Test.stopTest();

        // Then
        Assert.isNotNull(NaverNewsQueueable.retryEnqueued, '일시적 오류 시 재시도가 재큐되어야 한다');
        Assert.areEqual(0, NaverNewsQueueable.sentEmails.size(),
            '재시도가 남아있으면 관리자 알림은 아직 발송되지 않아야 한다');
    }

    @isTest
    static void shouldNotifyAdmin_WhenQueueableFailsFinally() {
        // Given: 최종 실패 시 관리자 알림 경로
        NaverNewsQueueable.testAdminEmail = 'admin@example.com';

        // When
        NaverNewsQueueable queueable = new NaverNewsQueueable(COMPANY_NAME);
        Test.startTest();
        queueable.notifyAdmin(new NaverNewsService.NaverNewsException('네이버 일시적 오류'), 3);
        Test.stopTest();

        // Then
        Assert.areEqual(1, NaverNewsQueueable.sentEmails.size(),
            '최종 실패 시 관리자 이메일 1건이 발송되어야 한다');
        Assert.areEqual(new List<String>{ 'admin@example.com' },
            NaverNewsQueueable.sentEmails[0].getToAddresses(),
            '설정된 관리자 주소로 발송되어야 한다');
    }

    @isTest
    static void shouldCollectSuccessfully_ViaBatch() {
        // Given
        User naverUser = TestDataFactory.createDartUser();
        setCredentials();
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        // When
        System.runAs(naverUser) {
            TestDataFactory.createAccountByName(COMPANY_NAME, true);
            Test.startTest();
            Database.executeBatch(new NaverNewsBatch(), 1);
            Test.stopTest();

            // Then
            Assert.areEqual(2, [SELECT COUNT() FROM ExternalSignal__c],
                '배치 실행 시 뉴스 2건이 수집되어야 한다');
        }
    }

    @isTest
    static void shouldScheduleBatch_ViaScheduler() {
        // Given
        setCredentials();
        Test.setMock(HttpCalloutMock.class, new EmptyMock());

        // When
        Test.startTest();
        String jobId = System.schedule(
            'Naver News Test Schedule',
            '0 0 6 * * ?',
            new NaverNewsScheduler()
        );
        Test.stopTest();

        // Then: CRON 등록이 성공해야 한다
        CronTrigger ct = [SELECT Id, CronExpression FROM CronTrigger WHERE Id = :jobId];
        Assert.areEqual('0 0 6 * * ?', ct.CronExpression, '스케줄 CRON 이 등록되어야 한다');
    }
}