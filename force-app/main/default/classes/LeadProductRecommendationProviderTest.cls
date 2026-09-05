/**
 * LeadProductRecommendationProvider 테스트.
 * 판정은 LLM 이 하므로 여기서는 "근거 텍스트가 빠짐없이, 올바른 순서로 실리는가"만 검증한다.
 */
@IsTest
private class LeadProductRecommendationProviderTest {

    private static final Decimal EOK = 100000000;

    @TestSetup
    static void setup() {
        insert new List<Product2>{
            new Product2(Name = 'RP 91일물', Family = 'RP', IsActive = true,
                Min_Term_Days__c = 91, Max_Term_Days__c = 91, Default_Fee_Rate__c = 0.15),
            new Product2(Name = '회사채 인수', Family = '채권', IsActive = true,
                Min_Term_Days__c = 90, Max_Term_Days__c = 1825, Default_Fee_Rate__c = 0.30)
        };
        insert new List<Lead>{
            newLead('여유', '재료있는기업'), newLead('빈', '재료없는기업')
        };
        Lead rich = [SELECT Id FROM Lead WHERE Company = '재료있는기업' LIMIT 1];
        insert new CorporateFinancialStatement__c(
            Lead__c = rich.Id, Fiscal_Year__c = 2026, External_Key__c = 'PRP-1',
            Cash_And_Equivalents__c = 1200 * EOK,
            Short_Term_Financial_Instruments__c = 300 * EOK,
            Short_Term_Borrowings__c = 0, Bonds_Payable__c = 0);
    }

    private static Lead newLead(String last, String company) {
        return new Lead(LastName = last, name_new__c = last, Company = company,
            Email = 'prov.test@example.com', Industry = '제조업', Status = '신규');
    }

    private static Id leadIdOf(String company) {
        return [SELECT Id FROM Lead WHERE Company = :company LIMIT 1].Id;
    }

    private static String promptFor(Id leadId) {
        LeadProductRecommendationProvider.Request req =
            new LeadProductRecommendationProvider.Request();
        req.RelatedLead = new Lead(Id = leadId);
        List<LeadProductRecommendationProvider.Response> out =
            LeadProductRecommendationProvider.getRecommendationContext(
                new List<LeadProductRecommendationProvider.Request>{ req });
        return out.isEmpty() ? null : out[0].Prompt;
    }

    @IsTest
    static void includesCompanyFinancialsAndCatalog() {
        Test.startTest();
        String prompt = promptFor(leadIdOf('재료있는기업'));
        Test.stopTest();

        System.Assert.isTrue(prompt.contains('재료있는기업'), '회사명이 실려야 한다');
        System.Assert.isTrue(prompt.contains('[공시 재무]'), '재무 블록이 실려야 한다');
        System.Assert.isTrue(prompt.contains('RP 91일물'), '상품 카탈로그가 실려야 한다');
        System.Assert.isTrue(prompt.contains('기존 추천 상품군: 없음'),
            '기존 추천 유무를 알려야 모델이 뒤집을지 유지할지 판단한다');
    }

    @IsTest
    static void catalogComesLastSoNamesStayFresh() {
        Test.startTest();
        String prompt = promptFor(leadIdOf('재료있는기업'));
        Test.stopTest();

        Integer catalogAt = prompt.indexOf('[제안 가능한 활성 상품');
        System.Assert.isTrue(catalogAt > 0, '상품 카탈로그 블록이 있어야 한다');
        System.Assert.isTrue(catalogAt > prompt.indexOf('[공시 재무]'),
            '종목명을 정확히 옮기게 하려면 카탈로그가 마지막 블록이어야 한다');
        System.Assert.isTrue(prompt.contains('정확히 일치'),
            '종목명을 그대로 쓰라는 지시가 프롬프트에 있어야 한다');
    }

    @IsTest
    static void reportsStoredRecommendationWhenPresent() {
        Id leadId = leadIdOf('재료있는기업');
        Product2 rp = [SELECT Id FROM Product2 WHERE Name = 'RP 91일물' LIMIT 1];
        update new Lead(Id = leadId, Recommended_Product_Family__c = 'RP',
            Recommended_Product__c = rp.Id, Recommended_Product_Rationale__c = '앞서 기록된 근거');

        Test.startTest();
        String prompt = promptFor(leadId);
        Test.stopTest();

        System.Assert.isTrue(prompt.contains('기존 추천 상품군: RP'), '기존 상품군을 알려야 한다');
        System.Assert.isTrue(prompt.contains('앞서 기록된 근거'), '기존 근거도 함께 알려야 한다');
    }

    @IsTest
    static void returnsGuidanceInsteadOfThrowing() {
        Test.startTest();
        LeadProductRecommendationProvider.Request empty =
            new LeadProductRecommendationProvider.Request();
        List<LeadProductRecommendationProvider.Response> out =
            LeadProductRecommendationProvider.getRecommendationContext(
                new List<LeadProductRecommendationProvider.Request>{ empty });
        List<LeadProductRecommendationProvider.Response> none =
            LeadProductRecommendationProvider.getRecommendationContext(null);
        Test.stopTest();

        System.Assert.areEqual(LeadProductRecommendationProvider.NO_LEAD_MESSAGE, out[0].Prompt,
            '리드가 없어도 예외 대신 안내 문구를 돌려 프롬프트는 생성되게 한다');
        System.Assert.isTrue(none.isEmpty(), '요청이 없으면 빈 목록');
    }

    @IsTest
    static void buildsForLeadWithoutFinancials() {
        Test.startTest();
        String prompt = promptFor(leadIdOf('재료없는기업'));
        Test.stopTest();

        System.Assert.isTrue(prompt.contains('재료없는기업'), '재무가 없어도 고객사 블록은 나온다');
        System.Assert.isTrue(prompt.contains('[제안 가능한 활성 상품'),
            '재무가 없어도 카탈로그는 실어 모델이 판단을 시도할 수 있게 한다');
    }

    @IsTest
    static void statesTheFamilyConstraintTheSaveActionEnforces() {
        Test.startTest();
        String prompt = promptFor(leadIdOf('재료있는기업'));
        Test.stopTest();

        // 카탈로그에는 자금운용·퇴직연금 상품도 실리지만 Lead 에 기록 가능한 상품군은 둘뿐이다.
        // 이 제약이 프롬프트에 없으면 모델이 기록 불가능한 상품군을 골라 저장이 조용히 거부된다.
        System.Assert.isTrue(prompt.contains('"RP" 또는 "회사채" 중 하나로만'),
            '기록 가능한 상품군 제약이 프롬프트에 있어야 한다');
        System.Assert.isTrue(prompt.contains('외화 상품은'),
            '외화 제외 기준이 규칙 엔진과 같아야 한다');
        System.Assert.isTrue(prompt.indexOf('[판정 규칙]') > prompt.indexOf('[제안 가능한 활성 상품'),
            '판정 규칙은 카탈로그 뒤에 와야 모델이 마지막에 읽는다');
    }
}