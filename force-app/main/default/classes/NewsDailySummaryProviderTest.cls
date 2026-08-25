/**
 * NewsDailySummaryProvider 테스트.
 * Top3 담당 기업 뉴스 + 산업군 뉴스의 grounding 텍스트 생성, 데이터 없음 안내 문구,
 * Invocable 진입점 동작을 검증한다.
 *
 * 팀 동결 파일 TestDataFactory 는 건드리지 않고 Account/시그널은 이 클래스 헬퍼로 만든다.
 */
@isTest
private class NewsDailySummaryProviderTest {

    private static Account createAccount(String name, String corpCode, Integer priority) {
        Account acct = TestDataFactory.createAccountByName(name, false);
        acct.Assigned_Company_Code__c = corpCode;
        acct.Priority_Score__c = priority;
        insert acct;
        return acct;
    }

    private static void insertCompanyNews(Id accountId, String key, Date signalDate, String title, String summary) {
        insertCompanyNews(accountId, key, signalDate, title, summary, null);
    }

    private static void insertCompanyNews(
        Id accountId, String key, Date signalDate, String title, String summary, String sourceUrl
    ) {
        insert new ExternalSignal__c(
            Account__c = accountId,
            Signal_Type__c = '뉴스',
            Signal_Date__c = signalDate,
            Title__c = title,
            Summary__c = summary,
            Source_URL__c = sourceUrl,
            External_Key__c = key
        );
    }

    private static void insertIndustryNews(String industry, String key, Date signalDate, String title, String summary) {
        insert new ExternalSignal__c(
            Industry__c = industry,
            Signal_Type__c = '뉴스',
            Signal_Date__c = signalDate,
            Title__c = title,
            Summary__c = summary,
            External_Key__c = key
        );
    }

    @isTest
    static void shouldBuildContext_WhenCompanyAndIndustryNewsExist() {
        Account topAccount = createAccount('리노공업', 'C0001', 80);
        insertCompanyNews(topAccount.Id, 'N_1', Date.today().addDays(-1),
            'AI 반도체 테스트 소켓 수요 급증', '고부가 소켓 비중 확대');
        insertIndustryNews('제조업', 'N_IND_1', Date.today().addDays(-1),
            '[산업군] AI·HBM 붐에 후공정 투자 확대', '메모리 업황 반등');

        Test.startTest();
        String text = NewsDailySummaryProvider.buildContextText();
        Test.stopTest();

        Assert.isTrue(text.contains('담당 기업 뉴스'), '기업 뉴스 블록이 포함돼야 한다');
        Assert.isTrue(text.contains('리노공업'), '기업명이 인용돼야 한다');
        Assert.isTrue(text.contains('AI 반도체 테스트 소켓'), '기업 뉴스 제목이 인용돼야 한다');
        Assert.isTrue(text.contains('담당 산업군 뉴스'), '산업군 뉴스 블록이 포함돼야 한다');
        Assert.isTrue(text.contains('제조업'), '산업군 태그가 인용돼야 한다');
    }

    @isTest
    static void shouldIncludeSourceUrl_WhenNewsHasSourceUrl() {
        Account topAccount = createAccount('출처 있는 기업', 'C0009', 80);
        insertCompanyNews(topAccount.Id, 'N_URL', Date.today().addDays(-1),
            '신제품 공급계약 체결', '연 매출 기여 예상', 'https://news.example.com/a1');

        String text = NewsDailySummaryProvider.buildContextText();

        Assert.isTrue(
            text.contains('(출처: https://news.example.com/a1)'),
            '출처 URL 이 있으면 근거 텍스트에 링크가 포함돼야 한다'
        );
    }

    @isTest
    static void shouldReturnCompanyOnly_WhenNoIndustryNews() {
        Account topAccount = createAccount('성우하이텍', 'C0002', 80);
        insertCompanyNews(topAccount.Id, 'N_2', Date.today().addDays(-1),
            '북미 전기차 OEM 공급계약', '차체 경량화 부품 다년 공급');

        String text = NewsDailySummaryProvider.buildContextText();

        Assert.isTrue(text.contains('담당 기업 뉴스'), '기업 뉴스 블록은 있어야 한다');
        Assert.isTrue(!text.contains('담당 산업군 뉴스'), '산업군 뉴스가 없으면 산업군 블록은 없어야 한다');
    }

    @isTest
    static void shouldLimitToTop3Accounts_ByPriorityScore() {
        // 담당 기업 4곳을 만들고, 하위 1곳의 뉴스는 Top3 밖이라 제외돼야 한다.
        Account a1 = createAccount('High A', 'C1', 90);
        Account a2 = createAccount('High B', 'C2', 85);
        Account a3 = createAccount('High C', 'C3', 80);
        Account a4 = createAccount('Low D', 'C4', 10);
        insertCompanyNews(a1.Id, 'N_A1', Date.today(), 'A1 뉴스', 'x');
        insertCompanyNews(a2.Id, 'N_A2', Date.today(), 'A2 뉴스', 'x');
        insertCompanyNews(a3.Id, 'N_A3', Date.today(), 'A3 뉴스', 'x');
        insertCompanyNews(a4.Id, 'N_A4', Date.today(), 'LowD 뉴스', 'x');

        String text = NewsDailySummaryProvider.buildContextText();

        Assert.isTrue(text.contains('A1 뉴스'), 'Top3 기업 뉴스는 포함돼야 한다');
        Assert.isTrue(!text.contains('LowD 뉴스'), 'Top3 밖 기업 뉴스는 제외돼야 한다');
    }

    @isTest
    static void shouldReturnNoDataMessage_WhenNoNews() {
        // 담당 기업은 있으나 뉴스 시그널이 전혀 없는 경우.
        createAccount('No News Co', 'C0003', 50);

        String text = NewsDailySummaryProvider.buildContextText();

        Assert.areEqual(
            NewsDailySummaryProvider.NO_DATA_MESSAGE,
            text,
            '뉴스 시그널이 없으면 안내 문구를 돌려줘야 한다'
        );
    }

    @isTest
    static void shouldRunViaInvocable_WhenRequestGiven() {
        Account topAccount = createAccount('하나기술', 'C0004', 70);
        insertCompanyNews(topAccount.Id, 'N_3', Date.today().addDays(-1),
            '유럽 배터리셀 업체와 조립장비 수주', '수주잔고 확대');

        NewsDailySummaryProvider.Request request = new NewsDailySummaryProvider.Request();

        Test.startTest();
        List<NewsDailySummaryProvider.Response> responses =
            NewsDailySummaryProvider.getSummaryContext(
                new List<NewsDailySummaryProvider.Request>{ request }
            );
        Test.stopTest();

        Assert.areEqual(1, responses.size(), '요청 1건에 응답 1건이어야 한다');
        Assert.isTrue(
            responses[0].Prompt.contains('조립장비 수주'),
            'Invocable 경로로도 뉴스 근거가 반환돼야 한다'
        );
    }

    @isTest
    static void shouldReturnOneResponse_WhenNoRequests() {
        // 뉴스 요약은 레코드 입력이 필요 없으므로 빈 요청에도 근거 텍스트 1건을 돌려준다.
        List<NewsDailySummaryProvider.Response> responses =
            NewsDailySummaryProvider.getSummaryContext(null);
        Assert.areEqual(1, responses.size(), '요청이 없어도 응답 1건이어야 한다');
    }
}