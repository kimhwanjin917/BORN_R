@IsTest
private class OpportunityListActionTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(Name = '성우하이텍 테스트', Business_Registration_Number__c = '9998877777');
        insert acc;
        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 3; i++) {
            opps.add(new Opportunity(Name = '테스트 기회 ' + i, AccountId = acc.Id,
                StageName = 'Prospecting', CloseDate = Date.today().addDays(30 + i), Amount = 1000 * (i + 1)));
        }
        opps.add(new Opportunity(Name = '종결 기회', AccountId = acc.Id,
            StageName = 'Closed Won', CloseDate = Date.today(), Amount = 500));
        insert opps;
    }

    @IsTest
    static void mineOpenDefault() {
        OpportunityListAction.Request r = new OpportunityListAction.Request();
        r.mineOnly = true;
        List<OpportunityListAction.Result> res = OpportunityListAction.listOpportunities(new List<OpportunityListAction.Request>{ r });
        System.assertEquals(1, res.size());
        System.assertEquals(3, res[0].itemCount, '진행 중 3건만');
        for (OpportunityListAction.Item it : res[0].items) {
            System.assertNotEquals('종결 기회', it.opportunityName);
        }
    }

    @IsTest
    static void keywordAndClosedIncludedAmountSort() {
        OpportunityListAction.Request r = new OpportunityListAction.Request();
        r.keyword = '성우하이텍';
        r.openOnly = false;
        r.sortBy = 'amount';
        List<OpportunityListAction.Result> res = OpportunityListAction.listOpportunities(new List<OpportunityListAction.Request>{ r });
        System.assertEquals(4, res[0].itemCount);
        System.assertEquals(3000, res[0].items[0].amount);
    }

    @IsTest
    static void ownerNameNoMatch() {
        OpportunityListAction.Request r = new OpportunityListAction.Request();
        r.ownerName = '존재하지않는담당자XYZ';
        List<OpportunityListAction.Result> res = OpportunityListAction.listOpportunities(new List<OpportunityListAction.Request>{ r });
        System.assertEquals(0, res[0].itemCount);
        System.assert(res[0].message.contains('없습니다'));
    }

    @IsTest
    static void ownerNameWithoutSpaceMatchesSpacedUserName() {
        // 실행 사용자 이름(성 이름)을 공백 없이 붙여서 검색해도 매칭돼야 한다
        String full = UserInfo.getName();
        String compact = full.replaceAll('\\s+', '');
        if (compact == full || compact.length() < 2) {
            return; // 이름에 공백이 없는 사용자면 검증 대상 아님
        }
        OpportunityListAction.Request r = new OpportunityListAction.Request();
        r.ownerName = compact;
        List<OpportunityListAction.Result> res = OpportunityListAction.listOpportunities(new List<OpportunityListAction.Request>{ r });
        System.assertEquals(3, res[0].itemCount, '공백 없는 이름으로도 담당자 매칭');
    }

    @IsTest
    static void closedFallbackWhenNoOpen() {
        OpportunityListAction.Request r = new OpportunityListAction.Request();
        r.keyword = '종결 기회'; // 진행 중 건은 없고 종결 건만 있는 키워드
        List<OpportunityListAction.Result> res = OpportunityListAction.listOpportunities(new List<OpportunityListAction.Request>{ r });
        System.assertEquals(true, res[0].closedFallback);
        System.assertEquals(1, res[0].itemCount);
        System.assert(res[0].message.contains('종결된 기회 1건'));
    }

    @IsTest
    static void nullRequestList() {
        System.assertEquals(0, OpportunityListAction.listOpportunities(null).size());
    }
}