@IsTest
private class LeadRecommendationSaveActionTest {

    @TestSetup
    static void setup() {
        User tester = LeadRecommendationTestUtil.createTestUserWithFls();
        System.runAs(tester) {
            insert LeadRecommendationTestUtil.newLead('대성정밀(주)', '김담당', null, 80);
        }
    }

    private static LeadRecommendationSaveAction.Response run(Id leadId, String family, String rationale) {
        return run(leadId, family, rationale, null, null, null);
    }

    private static LeadRecommendationSaveAction.Response run(
        Id leadId, String family, String rationale, String productName, Decimal termDays, Decimal feeRate
    ) {
        LeadRecommendationSaveAction.Request req = new LeadRecommendationSaveAction.Request();
        req.leadId = leadId;
        req.productFamily = family;
        req.rationale = rationale;
        req.productName = productName;
        req.termDays = termDays;
        req.feeRate = feeRate;
        LeadRecommendationSaveAction.Response res;
        System.runAs(LeadRecommendationTestUtil.getTestUser()) {
            res = LeadRecommendationSaveAction.save(new List<LeadRecommendationSaveAction.Request>{ req })[0];
        }
        return res;
    }

    /** 검증 조회도 FLS 를 가진 테스트 사용자로 실행한다 (실행 사용자 프로필 FLS 에 의존하지 않도록). */
    private static Lead reload(Id leadId) {
        Lead saved;
        System.runAs(LeadRecommendationTestUtil.getTestUser()) {
            saved = [
                SELECT Recommended_Product_Family__c, Recommended_Product_Rationale__c,
                       Recommended_Product__c, Recommended_Product__r.Name,
                       Recommended_Term_Days__c, Recommended_Fee_Rate__c
                FROM Lead WHERE Id = :leadId
            ];
        }
        return saved;
    }

    @IsTest
    static void shouldSaveFamilyAndRationale() {
        Lead lead = [SELECT Id FROM Lead LIMIT 1];

        LeadRecommendationSaveAction.Response res = run(lead.Id, ' RP ', '현금성자산이 많아 단기 RP 적합');

        Assert.isTrue(res.isSuccess, res.message);
        Lead saved = reload(lead.Id);
        Assert.areEqual('RP', saved.Recommended_Product_Family__c, '공백 제거 후 저장');
        Assert.areEqual('현금성자산이 많아 단기 RP 적합', saved.Recommended_Product_Rationale__c);
    }

    @IsTest
    static void shouldRejectUnknownFamily() {
        Lead lead = [SELECT Id FROM Lead LIMIT 1];

        LeadRecommendationSaveAction.Response res = run(lead.Id, 'IPO', null);

        Assert.isFalse(res.isSuccess);
        Assert.isTrue(res.message.contains('RP 또는 회사채'));
        Assert.isNull(reload(lead.Id).Recommended_Product_Family__c);
    }

    @IsTest
    static void shouldRejectNullLeadId() {
        LeadRecommendationSaveAction.Response res = run(null, 'RP', null);
        Assert.isFalse(res.isSuccess);
        Assert.isTrue(res.message.contains('Lead Id'));
    }

    @IsTest
    static void shouldTruncateLongRationale() {
        Lead lead = [SELECT Id FROM Lead LIMIT 1];
        String longText = 'x'.repeat(2500);

        LeadRecommendationSaveAction.Response res = run(lead.Id, '회사채', longText);

        Assert.isTrue(res.isSuccess, res.message);
        Assert.areEqual(2000, reload(lead.Id).Recommended_Product_Rationale__c.length());
    }

    @IsTest
    static void shouldReportDmlFailurePerRow() {
        Lead lead = [SELECT Id FROM Lead LIMIT 1];
        delete lead;

        LeadRecommendationSaveAction.Response res = run(lead.Id, 'RP', null);

        Assert.isFalse(res.isSuccess);
        Assert.isTrue(res.message.startsWith('기록 실패'));
    }

    @IsTest
    static void shouldReturnEmptyForNoRequests() {
        Assert.areEqual(0, LeadRecommendationSaveAction.save(null).size());
    }

    // ─── 종목·기간·요율 (브리핑과 PDF 일치용) ──────────────────────────

    private static Product2 makeProduct(String name, String family, Integer minDays, Decimal fee) {
        Product2 p = new Product2(
            Name = name, Family = family, IsActive = true,
            Min_Term_Days__c = minDays, Max_Term_Days__c = minDays, Default_Fee_Rate__c = fee
        );
        insert p;
        return p;
    }

    @IsTest
    static void shouldSaveProductWithTermAndFee() {
        Lead lead = [SELECT Id FROM Lead LIMIT 1];
        makeProduct('RP 91일물', 'RP', 91, 0.15);

        LeadRecommendationSaveAction.Response res =
            run(lead.Id, 'RP', '단기 여유자금', 'RP 91일물', null, null);

        Assert.isTrue(res.isSuccess, res.message);
        Lead saved = reload(lead.Id);
        Assert.areEqual('RP 91일물', saved.Recommended_Product__r.Name, '종목이 저장돼야 한다');
        Assert.areEqual(91, saved.Recommended_Term_Days__c, '기간을 안 주면 종목의 최소 기간을 쓴다');
        Assert.areEqual(0.15, saved.Recommended_Fee_Rate__c, '요율을 안 주면 종목의 기본 요율을 쓴다');
    }

    @IsTest
    static void shouldPreferExplicitTermAndFee() {
        Lead lead = [SELECT Id FROM Lead LIMIT 1];
        makeProduct('RP 91일물', 'RP', 91, 0.15);

        LeadRecommendationSaveAction.Response res =
            run(lead.Id, 'RP', '협상 요율 적용', 'RP 91일물', 45, 0.12);

        Assert.isTrue(res.isSuccess, res.message);
        Lead saved = reload(lead.Id);
        Assert.areEqual(45, saved.Recommended_Term_Days__c, '명시한 기간이 상품 기본값을 이긴다');
        Assert.areEqual(0.12, saved.Recommended_Fee_Rate__c, '명시한 요율이 상품 기본값을 이긴다');
    }

    @IsTest
    static void shouldRejectProductFromOtherFamily() {
        Lead lead = [SELECT Id FROM Lead LIMIT 1];
        makeProduct('회사채 - 삼성전자 3년물 (AAA)', '채권', 1095, 0.20);

        // 상품군은 RP 라고 해놓고 채권 종목을 고른 모순
        LeadRecommendationSaveAction.Response res =
            run(lead.Id, 'RP', '모순', '회사채 - 삼성전자 3년물 (AAA)', null, null);

        Assert.isFalse(res.isSuccess, '상품군과 종목이 어긋나면 기록하면 안 된다');
        Assert.isTrue(res.message.contains('맞지 않습니다'), res.message);
        Assert.isNull(reload(lead.Id).Recommended_Product__c, '아무것도 저장되지 않아야 한다');
    }

    @IsTest
    static void shouldMapBondFamilyToProductFamily() {
        Lead lead = [SELECT Id FROM Lead LIMIT 1];
        makeProduct('회사채 - 삼성전자 3년물 (AAA)', '채권', 1095, 0.20);

        // Lead 는 '회사채', Product2 는 '채권' — 낱말이 다르지만 같은 상품군이다
        LeadRecommendationSaveAction.Response res =
            run(lead.Id, '회사채', '중기 운용', '회사채 - 삼성전자 3년물 (AAA)', null, null);

        Assert.isTrue(res.isSuccess, res.message);
        Assert.areEqual(1095, reload(lead.Id).Recommended_Term_Days__c);
    }

    @IsTest
    static void shouldRejectUnknownProduct() {
        Lead lead = [SELECT Id FROM Lead LIMIT 1];

        LeadRecommendationSaveAction.Response res =
            run(lead.Id, 'RP', '없는 종목', 'RP 999일물', null, null);

        Assert.isFalse(res.isSuccess);
        Assert.isTrue(res.message.contains('찾지 못했습니다'), res.message);
    }

    @IsTest
    static void shouldClearProductWhenOnlyFamilyGiven() {
        Lead lead = [SELECT Id FROM Lead LIMIT 1];
        makeProduct('RP 91일물', 'RP', 91, 0.15);
        run(lead.Id, 'RP', '최초', 'RP 91일물', null, null);
        Assert.isNotNull(reload(lead.Id).Recommended_Product__c, '사전 조건: 종목이 저장돼 있다');

        // 상품군만 다시 기록하면 낡은 종목은 지워져야 한다 (모순 방지)
        run(lead.Id, '회사채', '상품군 변경', null, null, null);

        Lead saved = reload(lead.Id);
        Assert.areEqual('회사채', saved.Recommended_Product_Family__c);
        Assert.isNull(saved.Recommended_Product__c, '낡은 RP 종목이 남으면 안 된다');
        Assert.isNull(saved.Recommended_Term_Days__c);
        Assert.isNull(saved.Recommended_Fee_Rate__c);
    }
}