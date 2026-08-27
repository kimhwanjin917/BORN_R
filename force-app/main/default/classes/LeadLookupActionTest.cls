@IsTest
private class LeadLookupActionTest {

    @TestSetup
    static void setup() {
        User tester = LeadRecommendationTestUtil.createTestUserWithFls();
        System.runAs(tester) {
            insert new List<Lead>{
                LeadRecommendationTestUtil.newLead('대성정밀(주)', '김담당', 'RP', 90),
                LeadRecommendationTestUtil.newLead('씨앤씨인터내셔널', '이재무', null, 70),
                LeadRecommendationTestUtil.newLead('한빛전자', '박대리', '회사채', 50)
            };
            Lead converted = LeadRecommendationTestUtil.newLead('전환된회사', '최부장', null, 10);
            insert converted;
            Database.LeadConvert lc = new Database.LeadConvert();
            lc.setLeadId(converted.Id);
            lc.setConvertedStatus([SELECT MasterLabel FROM LeadStatus WHERE IsConverted = true LIMIT 1].MasterLabel);
            lc.setDoNotCreateOpportunity(true);
            Database.convertLead(lc);
        }
    }

    private static LeadLookupAction.Result run(String keyword) {
        LeadLookupAction.Request req = new LeadLookupAction.Request();
        req.keyword = keyword;
        LeadLookupAction.Result res;
        System.runAs(LeadRecommendationTestUtil.getTestUser()) {
            res = LeadLookupAction.search(new List<LeadLookupAction.Request>{ req })[0];
        }
        return res;
    }

    @IsTest
    static void shouldFindByCompanyKeyword() {
        LeadLookupAction.Result res = run('대성');
        Assert.areEqual(1, res.matchCount, res.message);
        Assert.areEqual('대성정밀(주)', res.matches[0].company);
        Assert.areEqual('김담당', res.matches[0].contactName);
        Assert.areEqual('RP', res.matches[0].recommendedProductFamily);
    }

    @IsTest
    static void shouldFindByContactNameKeyword() {
        LeadLookupAction.Result res = run('재무');
        Assert.areEqual(1, res.matchCount, res.message);
        Assert.areEqual('씨앤씨인터내셔널', res.matches[0].company);
        Assert.isNull(res.matches[0].recommendedProductFamily);
    }

    @IsTest
    static void shouldExcludeConvertedLeads() {
        LeadLookupAction.Result res = run('전환된');
        Assert.areEqual(0, res.matchCount);
        Assert.isTrue(res.message.contains('찾지 못했습니다'));
    }

    @IsTest
    static void shouldReturnEmptyForBlankKeyword() {
        LeadLookupAction.Result blank = run('   ');
        Assert.areEqual(0, blank.matchCount);
        Assert.isTrue(blank.message.contains('검색어가 비어'));
    }

    @IsTest
    static void shouldReturnEmptyListForNullRequests() {
        Assert.areEqual(0, LeadLookupAction.search(null).size());
    }
}