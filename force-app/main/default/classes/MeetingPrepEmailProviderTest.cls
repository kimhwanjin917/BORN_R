/**
 * MeetingPrepEmailProvider 테스트.
 * 브리핑 맥락(재무·시그널) + 상품 카탈로그 grounding 텍스트 생성,
 * 데이터/리드/상품 없음 안내 문구, Invocable 진입점 동작을 검증한다.
 *
 * 팀 동결 파일 TestDataFactory 는 건드리지 않고 Lead/CFS/시그널/상품은 이 클래스 헬퍼로 만든다.
 */
@isTest
private class MeetingPrepEmailProviderTest {

    private static final Decimal ASSETS = 100000000000L; // 1000억

    @isTest
    static void shouldBuildContext_WhenFinancialSignalAndProductExist() {
        Lead lead = createLead('Email Lead');
        insertStatement(lead.Id, 2025, ASSETS, ASSETS, 30000000000L);
        insertDisclosureSignal(lead.Id, Date.newInstance(2026, 3, 15), '설비투자 공시', '증설 목적');
        insertRpProduct();

        Lead grounded = [SELECT Id FROM Lead WHERE Id = :lead.Id];
        String catalog = MeetingPrepEmailProvider.buildCatalogText();

        Test.startTest();
        String text = MeetingPrepEmailProvider.buildContextText(grounded, catalog);
        Test.stopTest();

        Assert.isTrue(text.contains('기업 브리핑 요약'), '브리핑 블록이 포함돼야 한다');
        Assert.isTrue(text.contains('설비투자 공시'), '시그널이 인용돼야 한다');
        Assert.isTrue(text.contains('추천 상품 카탈로그'), '상품 카탈로그 블록이 포함돼야 한다');
        Assert.isTrue(text.contains('RP 7일'), 'RP 상품명이 인용돼야 한다');
    }

    @isTest
    static void shouldReturnNoFinancialNote_WhenLeadHasNoData() {
        Lead lead = createLead('Bare Email Lead');
        insertRpProduct();

        Lead grounded = [SELECT Id FROM Lead WHERE Id = :lead.Id];
        String catalog = MeetingPrepEmailProvider.buildCatalogText();
        String text = MeetingPrepEmailProvider.buildContextText(grounded, catalog);

        Assert.isTrue(
            text.contains(MeetingPrepEmailProvider.NO_FINANCIAL_MESSAGE),
            '재무·시그널이 없으면 안내 문구가 있어야 한다'
        );
        Assert.isTrue(text.contains('추천 상품 카탈로그'), '상품이 있으면 카탈로그는 나와야 한다');
    }

    @isTest
    static void shouldReturnNoProductNote_WhenNoProduct() {
        Lead lead = createLead('No Product Lead');
        insertStatement(lead.Id, 2025, ASSETS, ASSETS, 30000000000L);

        Lead grounded = [SELECT Id FROM Lead WHERE Id = :lead.Id];
        String catalog = MeetingPrepEmailProvider.buildCatalogText();
        String text = MeetingPrepEmailProvider.buildContextText(grounded, catalog);

        Assert.isTrue(text.contains('기업 브리핑 요약'), '브리핑은 나와야 한다');
        Assert.isTrue(
            text.contains(MeetingPrepEmailProvider.NO_PRODUCT_MESSAGE),
            '활성 상품이 없으면 안내 문구가 있어야 한다'
        );
    }

    @isTest
    static void shouldReturnNoLeadMessage_WhenLeadNull() {
        String text = MeetingPrepEmailProvider.buildContextText(null, 'anything');
        Assert.areEqual(
            MeetingPrepEmailProvider.NO_LEAD_MESSAGE,
            text,
            '리드가 없으면 안내 문구를 돌려줘야 한다'
        );
    }

    @isTest
    static void shouldRunViaInvocable_WhenRequestGiven() {
        Lead lead = createLead('Invocable Email Lead');
        insertStatement(lead.Id, 2025, ASSETS, ASSETS, 30000000000L);
        insertRpProduct();

        MeetingPrepEmailProvider.Request request = new MeetingPrepEmailProvider.Request();
        request.RelatedLead = [SELECT Id FROM Lead WHERE Id = :lead.Id];

        Test.startTest();
        List<MeetingPrepEmailProvider.Response> responses =
            MeetingPrepEmailProvider.getEmailContext(
                new List<MeetingPrepEmailProvider.Request>{ request }
            );
        Test.stopTest();

        Assert.areEqual(1, responses.size(), '요청 1건에 응답 1건이어야 한다');
        Assert.isTrue(
            responses[0].Prompt.contains('기업 브리핑 요약'),
            'Invocable 경로로도 브리핑 근거가 반환돼야 한다'
        );
    }

    @isTest
    static void shouldReturnEmpty_WhenNoRequests() {
        List<MeetingPrepEmailProvider.Response> responses =
            MeetingPrepEmailProvider.getEmailContext(null);
        Assert.areEqual(0, responses.size(), '요청이 없으면 빈 응답이어야 한다');
    }

    // ─── 헬퍼 ──────────────────────────────────────────────────────────────

    private static Integer brnSeq = 4300000;

    private static Lead createLead(String company) {
        Integer seq = brnSeq++;
        Lead lead = new Lead(
            LastName = 'Tester' + seq,
            Company = company,
            Status = '신규',
            IsConverted = false,
            Email = 'tester' + seq + '@example.com',
            name_new__c = 'Tester',
            Business_Registration_Number__c = String.valueOf(seq)
        );
        Database.DMLOptions dml = new Database.DMLOptions();
        dml.DuplicateRuleHeader.AllowSave = true;
        lead.setOptions(dml);
        insert lead;
        return lead;
    }

    private static void insertStatement(
        Id leadId, Integer fiscalYear, Decimal totalAssets, Decimal totalEquity, Decimal cash
    ) {
        insert new CorporateFinancialStatement__c(
            Lead__c = leadId,
            Fiscal_Year__c = fiscalYear,
            Period_Type__c = '4분기',
            Total_Assets__c = totalAssets,
            Total_Equity__c = totalEquity,
            Cash_And_Equivalents__c = cash,
            Short_Term_Financial_Instruments__c = 0,
            Revenue__c = 50000000000L,
            Operating_Income__c = 5000000000L,
            Bonds_Payable__c = 0,
            Short_Term_Borrowings__c = 0,
            Long_Term_Borrowings__c = 0,
            External_Key__c = 'K_' + leadId + '_' + fiscalYear
        );
    }

    private static void insertDisclosureSignal(Id leadId, Date signalDate, String title, String summary) {
        insert new ExternalSignal__c(
            Lead__c = leadId,
            Signal_Type__c = '공시',
            Signal_Date__c = signalDate,
            Title__c = title,
            Summary__c = summary,
            External_Key__c = 'SIG_' + leadId + '_' + signalDate.year()
        );
    }

    private static void insertRpProduct() {
        insert new Product2(
            Name = 'RP 7일',
            Family = 'RP',
            IsActive = true,
            Eligibility_Rule__c = '법인 고객',
            Default_Fee_Rate__c = 3.10,
            Min_Term_Days__c = 7,
            Max_Term_Days__c = 90
        );
    }
}