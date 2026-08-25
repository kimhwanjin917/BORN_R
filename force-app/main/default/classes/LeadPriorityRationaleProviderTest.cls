/**
 * LeadPriorityRationaleProvider 테스트.
 * 재무·시그널이 있는 리드의 근거 텍스트 생성, 데이터/리드 없음 안내 문구,
 * Invocable 진입점 동작을 검증한다.
 *
 * 팀 동결 파일 TestDataFactory 는 건드리지 않고 Lead/CFS/시그널은 이 클래스 헬퍼로 만든다.
 */
@isTest
private class LeadPriorityRationaleProviderTest {

    private static final Decimal ASSETS = 100000000000L; // 1000억

    @isTest
    static void shouldBuildContext_WhenFinancialAndSignalExist() {
        Lead lead = createLead('Context Lead');
        insertStatement(lead.Id, 2023, ASSETS, ASSETS, 30000000000L);
        insertDisclosureSignal(lead.Id, Date.newInstance(2024, 3, 15), '유상증자 결정', '운영자금 조달 목적');

        Lead grounded = [SELECT Id FROM Lead WHERE Id = :lead.Id];
        Test.startTest();
        String text = LeadPriorityRationaleProvider.buildContextText(grounded);
        Test.stopTest();

        Assert.isTrue(text.contains('최신 연간 재무제표'), '재무 블록이 포함돼야 한다');
        Assert.isTrue(text.contains('최근 외부 시그널'), '시그널 블록이 포함돼야 한다');
        Assert.isTrue(text.contains('유상증자 결정'), '시그널 제목이 인용돼야 한다');
        Assert.isTrue(text.contains('억 원'), '재무 수치가 억 단위로 표기돼야 한다');
    }

    @isTest
    static void shouldReturnFinancialOnly_WhenNoSignal() {
        Lead lead = createLead('Fin Only Lead');
        insertStatement(lead.Id, 2023, ASSETS, ASSETS, 30000000000L);

        Lead grounded = [SELECT Id FROM Lead WHERE Id = :lead.Id];
        String text = LeadPriorityRationaleProvider.buildContextText(grounded);

        Assert.isTrue(text.contains('최신 연간 재무제표'), '재무 블록은 있어야 한다');
        Assert.isTrue(!text.contains('최근 외부 시그널'), '시그널이 없으면 시그널 블록은 없어야 한다');
    }

    @isTest
    static void shouldReturnNoDataMessage_WhenLeadHasNothing() {
        Lead lead = createLead('Bare Lead');

        Lead grounded = [SELECT Id FROM Lead WHERE Id = :lead.Id];
        String text = LeadPriorityRationaleProvider.buildContextText(grounded);

        Assert.areEqual(
            LeadPriorityRationaleProvider.NO_DATA_MESSAGE,
            text,
            '연결 데이터가 없으면 안내 문구를 돌려줘야 한다'
        );
    }

    @isTest
    static void shouldReturnNoLeadMessage_WhenLeadNull() {
        String text = LeadPriorityRationaleProvider.buildContextText(null);
        Assert.areEqual(
            LeadPriorityRationaleProvider.NO_LEAD_MESSAGE,
            text,
            '리드가 없으면 안내 문구를 돌려줘야 한다'
        );
    }

    @isTest
    static void shouldRunViaInvocable_WhenRequestGiven() {
        Lead lead = createLead('Invocable Lead');
        insertStatement(lead.Id, 2023, ASSETS, ASSETS, 30000000000L);

        LeadPriorityRationaleProvider.Request request = new LeadPriorityRationaleProvider.Request();
        request.RelatedLead = [SELECT Id FROM Lead WHERE Id = :lead.Id];

        Test.startTest();
        List<LeadPriorityRationaleProvider.Response> responses =
            LeadPriorityRationaleProvider.getRationaleContext(
                new List<LeadPriorityRationaleProvider.Request>{ request }
            );
        Test.stopTest();

        Assert.areEqual(1, responses.size(), '요청 1건에 응답 1건이어야 한다');
        Assert.isTrue(
            responses[0].Prompt.contains('최신 연간 재무제표'),
            'Invocable 경로로도 재무 근거가 반환돼야 한다'
        );
    }

    @isTest
    static void shouldReturnEmpty_WhenNoRequests() {
        List<LeadPriorityRationaleProvider.Response> responses =
            LeadPriorityRationaleProvider.getRationaleContext(null);
        Assert.areEqual(0, responses.size(), '요청이 없으면 빈 응답이어야 한다');
    }

    // ─── 헬퍼 ──────────────────────────────────────────────────────────────

    private static Integer brnSeq = 4000000;

    private static Lead createLead(String company) {
        Integer seq = brnSeq++;
        Lead lead = new Lead(
            LastName = 'Tester' + seq,
            Company = company,
            Status = 'New',
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
            Period_Type__c = '연간',
            Total_Assets__c = totalAssets,
            Total_Equity__c = totalEquity,
            Cash_And_Equivalents__c = cash,
            Short_Term_Financial_Instruments__c = 0,
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
}