@IsTest
private class LeadProductRecommendationActionTest {

    @TestSetup
    static void setup() {
        User tester = LeadRecommendationTestUtil.createTestUserWithFls();
        System.runAs(tester) {
            Lead lead = LeadRecommendationTestUtil.newLead('대성정밀(주)', '김담당', null, 88);
            lead.Industry = 'Manufacturing';
            lead.AnnualRevenue = 50000000000L;
            lead.NumberOfEmployees = 120;
            lead.Priority_Rationale_Summary__c = '현금성자산 급증';
            insert lead;

            // 실제 org 의 기간 구분 값은 1~4분기다. 사업보고서(연간)는 '4분기'로 들어온다.
            List<CorporateFinancialStatement__c> fins = new List<CorporateFinancialStatement__c>();
            for (Integer y = 2021; y <= 2025; y++) {
                fins.add(new CorporateFinancialStatement__c(
                    Lead__c = lead.Id, Fiscal_Year__c = y, Period_Type__c = '4분기',
                    Revenue__c = y * 1000000, Operating_Income__c = 5000000,
                    Total_Assets__c = 90000000, Cash_And_Equivalents__c = 30000000
                ));
            }
            // 연간보다 최신인 분기 1건 — 잔고 판단용으로 따로 넘어가야 한다
            fins.add(new CorporateFinancialStatement__c(
                Lead__c = lead.Id, Fiscal_Year__c = 2026, Period_Type__c = '2분기',
                Revenue__c = 2026000000L, Operating_Income__c = 6000000,
                Total_Assets__c = 95000000, Cash_And_Equivalents__c = 41000000
            ));
            insert fins;

            List<ExternalSignal__c> sigs = new List<ExternalSignal__c>();
            for (Integer i = 0; i < 12; i++) {
                sigs.add(new ExternalSignal__c(
                    Lead__c = lead.Id, Signal_Type__c = '뉴스', Title__c = '시그널 ' + i,
                    Summary__c = '요약 ' + i, Signal_Date__c = Date.today().addDays(-i),
                    Relevance_Score__c = 10 - i
                ));
            }
            insert sigs;

            insert new List<Product2>{
                new Product2(Name = 'RP (환매조건부채권)', Family = 'RP', IsActive = true, Eligibility_Rule__c = '법인 대상'),
                new Product2(Name = '회사채', Family = '채권', IsActive = true),
                new Product2(Name = '패밀리 없음', IsActive = true),
                new Product2(Name = '비활성', Family = 'RP', IsActive = false)
            };
        }
    }

    private static LeadProductRecommendationAction.Response run(Id leadId) {
        LeadProductRecommendationAction.Request req = new LeadProductRecommendationAction.Request();
        req.leadId = leadId;
        LeadProductRecommendationAction.Response res;
        System.runAs(LeadRecommendationTestUtil.getTestUser()) {
            res = LeadProductRecommendationAction.gather(new List<LeadProductRecommendationAction.Request>{ req })[0];
        }
        return res;
    }

    @IsTest
    static void shouldGatherLeadContextFinancialsSignalsAndCandidates() {
        Lead lead = [SELECT Id FROM Lead LIMIT 1];

        LeadProductRecommendationAction.Response res = run(lead.Id);

        Assert.isTrue(res.isAccessible, res.message);
        Assert.areEqual('대성정밀(주)', res.company);
        Assert.areEqual('김담당', res.contactName);
        Assert.areEqual(88, res.priorityScore);
        Assert.areEqual('현금성자산 급증', res.priorityRationale);
        // 연간 3개년(추세) + 최신 분기 1건(잔고). 연간만 보면 반년 넘게 묵은 잔고로 제안하게 된다.
        Assert.areEqual(
            LeadProductRecommendationAction.MAX_FINANCIALS + LeadProductRecommendationAction.MAX_LATEST_QUARTERS,
            res.financials.size(), '연간 3개년 + 최신 분기 1건');
        Assert.areEqual(2026, res.financials[0].fiscalYear, '가장 최신 기간이 먼저');
        Assert.isFalse(res.financials[0].isAnnual, '최신은 분기다');
        Assert.areEqual(41000000, res.financials[0].cashAndEquivalents, '잔고는 최신 분기 값이어야 한다');

        Integer annuals = 0;
        for (LeadProductRecommendationAction.Financial f : res.financials) {
            if (f.isAnnual == true) {
                annuals++;
            }
        }
        Assert.areEqual(LeadProductRecommendationAction.MAX_FINANCIALS, annuals, '연간은 3개년까지만');
        Assert.areEqual(2025, res.financials[1].fiscalYear, '연간은 최신 연도부터');
        Assert.areEqual(LeadProductRecommendationAction.MAX_SIGNALS, res.signals.size(), '최근 10건만');
        Assert.areEqual('시그널 0', res.signals[0].title, '최신 시그널이 먼저');
        Assert.areEqual(2, res.candidates.size(), 'Family 있는 활성 상품만');
        Assert.isTrue(res.financialText.contains('2025'));
        Assert.isTrue(res.signalText.contains('[뉴스]'));
        Assert.isTrue(res.candidateText.contains('상품군: RP'));
        Assert.isTrue(res.message.contains('재무 '
            + (LeadProductRecommendationAction.MAX_FINANCIALS + LeadProductRecommendationAction.MAX_LATEST_QUARTERS)
            + '건'), res.message);
    }

    @IsTest
    static void shouldReturnInaccessibleForUnknownLead() {
        Lead lead = [SELECT Id FROM Lead LIMIT 1];
        delete lead;

        LeadProductRecommendationAction.Response res = run(lead.Id);

        Assert.isFalse(res.isAccessible);
        Assert.areEqual(0, res.financials.size());
        Assert.areEqual(0, res.candidates.size());
        Assert.isTrue(res.message.contains('찾지 못했거나'));
    }

    @IsTest
    static void shouldReturnInaccessibleForNullLeadId() {
        LeadProductRecommendationAction.Response res = run(null);
        Assert.isFalse(res.isAccessible);
    }

    @IsTest
    static void shouldReturnEmptyForNoRequests() {
        Assert.areEqual(0, LeadProductRecommendationAction.gather(null).size());
        Assert.areEqual(0, LeadProductRecommendationAction.gather(new List<LeadProductRecommendationAction.Request>()).size());
    }
}