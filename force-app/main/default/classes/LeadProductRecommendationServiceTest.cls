/**
 * LeadProductRecommendationService 테스트.
 *
 * 프롬프트 템플릿(ConnectApi) 호출은 stubResponse 로 대체한다. 그래서 템플릿이 org 에 아직
 * 없어도 "LLM 응답 → 파싱 → SaveAction 저장 → 실패 시 규칙 폴백" 전 경로를 검증할 수 있다.
 */
@IsTest
private class LeadProductRecommendationServiceTest {

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
            newLead('여유', '여유기업'), newLead('무자료', '자료없는기업')
        };
        Lead rich = [SELECT Id FROM Lead WHERE Company = '여유기업' LIMIT 1];
        insert new CorporateFinancialStatement__c(
            Lead__c = rich.Id, Fiscal_Year__c = 2026, External_Key__c = 'SVC-1',
            Cash_And_Equivalents__c = 1200 * EOK, Short_Term_Financial_Instruments__c = 300 * EOK,
            Short_Term_Borrowings__c = 0, Bonds_Payable__c = 0);
    }

    private static Lead newLead(String last, String company) {
        return new Lead(LastName = last, name_new__c = last, Company = company,
            Email = 'svc.test@example.com', Industry = '제조업', Status = '신규');
    }

    private static Id leadIdOf(String company) {
        return [SELECT Id FROM Lead WHERE Company = :company LIMIT 1].Id;
    }

    private static Lead reload(String company) {
        return [
            SELECT Recommended_Product_Family__c, Recommended_Product__r.Name,
                   Recommended_Term_Days__c, Recommended_Fee_Rate__c, Recommended_Product_Rationale__c
            FROM Lead WHERE Company = :company LIMIT 1
        ];
    }

    @IsTest
    static void savesLlmVerdictThroughTheAgentPath() {
        LeadProductRecommendationService.stubResponse =
            '{"productFamily":"RP","productName":"RP 91일물","termDays":91,"feeRate":0.15,'
            + '"rationale":"여유자금이 충분해 단기 운용이 적합합니다."}';

        Test.startTest();
        LeadProductRecommendationService.Outcome out =
            LeadProductRecommendationService.ensureRecommendation(leadIdOf('여유기업'));
        Test.stopTest();

        System.Assert.areEqual(LeadProductRecommendationService.Source.LLM, out.decidedBy,
            'LLM 판정으로 기록돼야 한다: ' + out.detail);
        Lead saved = reload('여유기업');
        System.Assert.areEqual('RP 91일물', saved.Recommended_Product__r.Name);
        System.Assert.areEqual(91, saved.Recommended_Term_Days__c);
        System.Assert.areEqual(0.15, saved.Recommended_Fee_Rate__c);
        System.Assert.areEqual('여유자금이 충분해 단기 운용이 적합합니다.',
            saved.Recommended_Product_Rationale__c);
    }

    @IsTest
    static void readsJsonWrappedInProseOrCodeFence() {
        LeadProductRecommendationService.stubResponse =
            '판정 결과입니다.\n```json\n'
            + '{"productFamily":"RP","productName":"RP 91일물","rationale":"근거"}\n```\n이상입니다.';

        Test.startTest();
        LeadProductRecommendationService.ensureRecommendation(leadIdOf('여유기업'));
        Test.stopTest();

        System.Assert.areEqual('RP 91일물', reload('여유기업').Recommended_Product__r.Name,
            '모델이 앞뒤에 설명을 붙여도 JSON 을 읽어내야 한다');
    }

    @IsTest
    static void fillsTermAndFeeFromProductWhenOmitted() {
        LeadProductRecommendationService.stubResponse =
            '{"productFamily":"RP","productName":"RP 91일물","rationale":"근거"}';

        Test.startTest();
        LeadProductRecommendationService.ensureRecommendation(leadIdOf('여유기업'));
        Test.stopTest();

        Lead saved = reload('여유기업');
        System.Assert.areEqual(91, saved.Recommended_Term_Days__c,
            '기간을 안 주면 SaveAction 이 상품 최소기간으로 채운다');
        System.Assert.areEqual(0.15, saved.Recommended_Fee_Rate__c,
            '요율을 안 주면 SaveAction 이 상품 기본요율로 채운다');
    }

    @IsTest
    static void fallsBackToRuleEngineWhenVerdictIsUnusable() {
        // JSON 이 없는 응답 — 문장에서 종목을 추측하지 말고 규칙으로 떨어져야 한다
        LeadProductRecommendationService.stubResponse = '추천을 만들 수 없습니다.';

        Test.startTest();
        LeadProductRecommendationService.Outcome out =
            LeadProductRecommendationService.ensureRecommendation(leadIdOf('여유기업'));
        Test.stopTest();

        System.Assert.areEqual(LeadProductRecommendationService.Source.RULE_ENGINE, out.decidedBy,
            '읽을 수 없는 응답이면 규칙 엔진으로 채운다: ' + out.detail);
        Lead saved = reload('여유기업');
        System.Assert.areEqual('RP', saved.Recommended_Product_Family__c);
        System.Assert.isTrue(saved.Recommended_Product_Rationale__c.contains('최종 조건은 미팅에서 확정합니다'),
            '규칙 엔진이 쓴 근거여야 한다');
    }

    @IsTest
    static void fallsBackWhenFamilyAndProductMismatch() {
        // 상품군은 RP 인데 종목은 채권 — SaveAction 의 정합성 검증에 걸려 폴백해야 한다
        LeadProductRecommendationService.stubResponse =
            '{"productFamily":"RP","productName":"회사채 인수","rationale":"근거"}';

        Test.startTest();
        LeadProductRecommendationService.Outcome out =
            LeadProductRecommendationService.ensureRecommendation(leadIdOf('여유기업'));
        Test.stopTest();

        System.Assert.areEqual(LeadProductRecommendationService.Source.RULE_ENGINE, out.decidedBy,
            '앞뒤 안 맞는 판정은 저장되지 않고 규칙으로 떨어진다: ' + out.detail);
        System.Assert.areEqual('RP 91일물', reload('여유기업').Recommended_Product__r.Name,
            '규칙 엔진이 고른 RP 종목이 들어가야 한다');
    }

    @IsTest
    static void keepsExistingRecommendation() {
        Id leadId = leadIdOf('여유기업');
        Product2 bond = [SELECT Id FROM Product2 WHERE Name = '회사채 인수' LIMIT 1];
        update new Lead(Id = leadId, Recommended_Product_Family__c = '회사채',
            Recommended_Product__c = bond.Id, Recommended_Term_Days__c = 1095,
            Recommended_Product_Rationale__c = '에이전트가 이미 기록한 근거');
        LeadProductRecommendationService.stubResponse =
            '{"productFamily":"RP","productName":"RP 91일물","rationale":"뒤집으려는 판정"}';

        Test.startTest();
        LeadProductRecommendationService.Outcome out =
            LeadProductRecommendationService.ensureRecommendation(leadId);
        Test.stopTest();

        System.Assert.areEqual(LeadProductRecommendationService.Source.ALREADY_PRESENT, out.decidedBy);
        Lead saved = reload('여유기업');
        System.Assert.areEqual('회사채 인수', saved.Recommended_Product__r.Name,
            '에이전트가 쓴 값을 LLM 재판정이 덮으면 안 된다');
        System.Assert.areEqual('에이전트가 이미 기록한 근거', saved.Recommended_Product_Rationale__c);
    }

    @IsTest
    static void leavesLeadEmptyWhenNeitherPathCanDecide() {
        // 재무 자료가 없어 규칙 엔진도 추천을 못 만드는 리드
        LeadProductRecommendationService.stubResponse = null;

        Test.startTest();
        LeadProductRecommendationService.Outcome out =
            LeadProductRecommendationService.ensureRecommendation(leadIdOf('자료없는기업'));
        Test.stopTest();

        System.Assert.areEqual(LeadProductRecommendationService.Source.NONE, out.decidedBy,
            '근거가 없으면 아무것도 기록하지 않는다: ' + out.detail);
        System.Assert.isNull(reload('자료없는기업').Recommended_Product__c);
    }

    @IsTest
    static void isSilentForNullOrUnknownLead() {
        Test.startTest();
        LeadProductRecommendationService.Outcome nullCase =
            LeadProductRecommendationService.ensureRecommendation(null);
        Test.stopTest();

        System.Assert.areEqual(LeadProductRecommendationService.Source.NONE, nullCase.decidedBy,
            'Lead Id 가 없어도 예외를 던지면 안 된다 — 브리핑 생성을 막는다');
    }

    @IsTest
    static void treatsZeroTermAndFeeAsUnknown() {
        // 모델이 feeRate 0 을 준 적이 있다. 그대로 저장하면 수수료율 0% 가 되므로
        // 0·음수는 "모름"으로 보고 SaveAction 이 상품 기본값으로 채우게 해야 한다.
        LeadProductRecommendationService.stubResponse =
            '{"productFamily":"RP","productName":"RP 91일물","termDays":0,"feeRate":0,"rationale":"근거"}';

        Test.startTest();
        LeadProductRecommendationService.ensureRecommendation(leadIdOf('여유기업'));
        Test.stopTest();

        Lead saved = reload('여유기업');
        System.Assert.areEqual(91, saved.Recommended_Term_Days__c, '0 은 상품 최소기간으로 대체돼야 한다');
        System.Assert.areEqual(0.15, saved.Recommended_Fee_Rate__c, '0 은 상품 기본요율로 대체돼야 한다');
    }
}