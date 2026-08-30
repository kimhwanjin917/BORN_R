/**
 * MeetingPrepBriefingController 테스트.
 * ConnectApi(프롬프트 템플릿) 호출은 testResponseOverride 로 대체해,
 * 저장/조회/에러 처리 로직만 검증한다.
 */
@isTest
private class MeetingPrepBriefingControllerTest {

    private static Integer brnSeq = 5300000;

    private static Lead createLead() {
        Integer seq = brnSeq++;
        Lead lead = new Lead(
            LastName = 'Tester' + seq,
            Company = 'Briefing Co ' + seq,
            Status = '신규',
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

    @isTest
    static void shouldReturnStoredBriefing_WhenPresent() {
        Lead lead = createLead();
        Datetime stamp = System.now();
        update new Lead(
            Id = lead.Id,
            Meeting_Prep_Briefing__c = '저장된 브리핑 본문',
            Meeting_Prep_Briefing_Updated_At__c = stamp
        );

        MeetingPrepBriefingController.BriefingResult result =
            MeetingPrepBriefingController.getBriefing(lead.Id);

        Assert.areEqual('저장된 브리핑 본문', result.briefing, '저장된 브리핑을 반환해야 한다');
        Assert.areNotEqual(null, result.updatedAt, '생성 시각이 반환돼야 한다');
    }

    @isTest
    static void shouldReturnNull_WhenNoBriefingStored() {
        Lead lead = createLead();
        MeetingPrepBriefingController.BriefingResult result =
            MeetingPrepBriefingController.getBriefing(lead.Id);
        Assert.areEqual(null, result.briefing, '저장된 브리핑이 없으면 null 이어야 한다');
    }

    @isTest
    static void shouldGenerateAndStoreBriefing_WhenTemplateReturnsText() {
        Lead lead = createLead();
        MeetingPrepBriefingController.testResponseOverride = '■ 한줄 요약: 테스트 브리핑';

        Test.startTest();
        MeetingPrepBriefingController.BriefingResult result =
            MeetingPrepBriefingController.generateBriefing(lead.Id);
        Test.stopTest();

        Assert.areEqual('■ 한줄 요약: 테스트 브리핑', result.briefing, '생성된 브리핑을 반환해야 한다');
        Lead stored = [
            SELECT Meeting_Prep_Briefing__c, Meeting_Prep_Briefing_Updated_At__c
            FROM Lead WHERE Id = :lead.Id
        ];
        Assert.areEqual('■ 한줄 요약: 테스트 브리핑', stored.Meeting_Prep_Briefing__c, 'Lead 에 저장돼야 한다');
        Assert.areNotEqual(null, stored.Meeting_Prep_Briefing_Updated_At__c, '생성 시각이 저장돼야 한다');
    }

    @isTest
    static void shouldThrow_WhenTemplateReturnsBlank() {
        Lead lead = createLead();
        MeetingPrepBriefingController.testResponseOverride = '';

        Boolean threw = false;
        try {
            MeetingPrepBriefingController.generateBriefing(lead.Id);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Assert.isTrue(threw, '빈 응답이면 예외를 던져야 한다');
    }

    @isTest
    static void shouldThrow_WhenRecordIdNull() {
        Boolean threw = false;
        try {
            MeetingPrepBriefingController.generateBriefing(null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Assert.isTrue(threw, 'recordId 가 없으면 예외를 던져야 한다');
    }

    @isTest
    static void getSimilarWon_returnsActualOpportunityAggregate() {
        Account account = new Account(
            Name = '유사 WON 테스트 제조',
            Industry = 'Manufacturing',
            Business_Registration_Number__c = '9980000001'
        );
        insert account;
        Product2 product = new Product2(Name = '테스트 RP', Family = 'RP', IsActive = true);
        insert product;
        insert new List<Opportunity>{
            new Opportunity(Name = '유사 WON 1', AccountId = account.Id,
                StageName = 'Closed Won', CloseDate = Date.today(), Primary_Product__c = product.Id),
            new Opportunity(Name = '유사 Lost 1', AccountId = account.Id,
                StageName = 'Closed Lost', CloseDate = Date.today(), Primary_Product__c = product.Id)
        };

        Opportunity openOpportunity = new Opportunity(
            Name = '현재 영업기회', AccountId = account.Id,
            StageName = '미팅', CloseDate = Date.today().addDays(30), Primary_Product__c = product.Id
        );
        insert openOpportunity;

        Test.startTest();
        MeetingPrepBriefingController.SimilarWonCardResult result =
            MeetingPrepBriefingController.getSimilarWon(openOpportunity.Id);
        Test.stopTest();

        Assert.areEqual(2, result.totalCount, '종결 기회만 집계해야 한다');
        Assert.areEqual(1, result.wonCount, 'Closed Won만 Won 건수로 집계해야 한다');
        Assert.areEqual(50.0, result.wonRate, 'Won 비율은 50.0%여야 한다');
        Assert.isFalse(result.insufficientData, '종결 기회 2건이면 데이터가 충분하다');
        Assert.areEqual('Manufacturing', result.industry);
        Assert.areEqual('RP', result.productType);
    }

    @isTest
    static void getSimilarWon_returnsNullForLead() {
        Lead lead = createLead();
        Assert.isNull(MeetingPrepBriefingController.getSimilarWon(lead.Id),
            '유사 WON 카드는 영업기회에서만 조회해야 한다');
    }

    // ─── ensureRecommendation ──────────────────────────────────────────
    //
    // 브리핑과 상품 제안서가 같은 추천을 보여주려면 양쪽 다 엔진을 불러야 한다.
    // 예전에는 제안서(LeadProposalController.getContext)에만 배선돼 있어서,
    // 제안서 탭을 먼저 연 리드만 추천이 채워지는 순서 의존이 있었다.

    private static final Decimal EOK = 100000000;

    private static void addFinance(Id leadId, Decimal cash, Decimal bonds) {
        insert new CorporateFinancialStatement__c(
            Lead__c = leadId, Fiscal_Year__c = 2026,
            External_Key__c = 'MPB-' + leadId,
            Cash_And_Equivalents__c = cash, Short_Term_Financial_Instruments__c = 0,
            Short_Term_Borrowings__c = 0, Bonds_Payable__c = bonds);
    }

    private static Product2 insertRp() {
        Product2 p = new Product2(Name = 'RP (환매조건부채권)', Family = 'RP', IsActive = true,
            Min_Term_Days__c = 1, Max_Term_Days__c = 180, Default_Fee_Rate__c = 0.15);
        insert p;
        return p;
    }

    @isTest
    static void ensureRecommendation_usesLlmVerdictWhenAvailable() {
        Lead lead = createLead();
        Product2 rp = insertRp();
        addFinance(lead.Id, 1200 * EOK, 0);
        LeadProductRecommendationService.stubResponse =
            '{"productFamily":"RP","productName":"RP (환매조건부채권)","termDays":30,'
            + '"feeRate":0.15,"rationale":"LLM 이 판정한 근거"}';

        Test.startTest();
        MeetingPrepBriefingController.ensureRecommendation(lead.Id);
        Test.stopTest();

        Lead saved = [
            SELECT Recommended_Product__c, Recommended_Term_Days__c, Recommended_Product_Rationale__c
            FROM Lead WHERE Id = :lead.Id
        ];
        Assert.areEqual(rp.Id, saved.Recommended_Product__c);
        Assert.areEqual(30, saved.Recommended_Term_Days__c, 'LLM 이 정한 기간이 들어가야 한다');
        Assert.areEqual('LLM 이 판정한 근거', saved.Recommended_Product_Rationale__c,
            '규칙 엔진 문구가 아니라 LLM 근거여야 한다');
    }

    @isTest
    static void ensureRecommendation_fillsLeadFields_WhenNothingStored() {
        Lead lead = createLead();
        Product2 rp = insertRp();
        addFinance(lead.Id, 1200 * EOK, 0);

        Test.startTest();
        MeetingPrepBriefingController.ensureRecommendation(lead.Id);
        Test.stopTest();

        Lead saved = [
            SELECT Recommended_Product__c, Recommended_Product_Family__c,
                   Recommended_Term_Days__c, Recommended_Fee_Rate__c
            FROM Lead WHERE Id = :lead.Id
        ];
        Assert.areEqual(rp.Id, saved.Recommended_Product__c,
            '브리핑 쪽에서도 추천이 채워져야 한다 — 제안서 탭을 먼저 열 필요가 없어야 한다');
        Assert.areEqual('RP', saved.Recommended_Product_Family__c);
        Assert.areEqual(91, saved.Recommended_Term_Days__c);
        Assert.areEqual(0.15, saved.Recommended_Fee_Rate__c);
    }

    @isTest
    static void ensureRecommendation_keepsExistingRecommendation() {
        Lead lead = createLead();
        Product2 rp = insertRp();
        addFinance(lead.Id, 1200 * EOK, 0);
        update new Lead(
            Id = lead.Id,
            Recommended_Product_Family__c = 'RP',
            Recommended_Product__c = rp.Id,
            Recommended_Term_Days__c = 7,
            Recommended_Fee_Rate__c = 0.99,
            Recommended_Product_Rationale__c = '에이전트가 이미 기록한 근거'
        );

        Test.startTest();
        MeetingPrepBriefingController.ensureRecommendation(lead.Id);
        Test.stopTest();

        Lead saved = [
            SELECT Recommended_Term_Days__c, Recommended_Fee_Rate__c, Recommended_Product_Rationale__c
            FROM Lead WHERE Id = :lead.Id
        ];
        Assert.areEqual(7, saved.Recommended_Term_Days__c, '에이전트가 쓴 값을 덮으면 안 된다');
        Assert.areEqual(0.99, saved.Recommended_Fee_Rate__c);
        Assert.areEqual('에이전트가 이미 기록한 근거', saved.Recommended_Product_Rationale__c);
    }

    @isTest
    static void ensureRecommendation_isSilent_WhenNoFinancialsOrNullId() {
        Lead lead = createLead();

        Test.startTest();
        // 재무자료가 없으면 추정하지 않고 조용히 넘어간다 (예외를 던지면 브리핑 생성이 막힌다)
        MeetingPrepBriefingController.ensureRecommendation(lead.Id);
        MeetingPrepBriefingController.ensureRecommendation(null);
        Test.stopTest();

        Lead saved = [SELECT Recommended_Product__c FROM Lead WHERE Id = :lead.Id];
        Assert.isNull(saved.Recommended_Product__c, '근거 없이 추천을 만들면 안 된다');
    }
}