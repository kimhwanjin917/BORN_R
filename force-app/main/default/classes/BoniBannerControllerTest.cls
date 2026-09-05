@IsTest
private class BoniBannerControllerTest {
    @IsTest
    static void countsOnlyOwnOpenOpportunities() {
        Account acc = new Account(Name = 'BoniTest 고객사', Business_Registration_Number__c = '9998877777');
        insert acc;
        List<Opportunity> opps = new List<Opportunity>{
            new Opportunity(Name = 'open1', AccountId = acc.Id, StageName = 'Prospecting', CloseDate = Date.today().addDays(30)),
            new Opportunity(Name = 'open2', AccountId = acc.Id, StageName = 'Prospecting', CloseDate = Date.today().addDays(30)),
            new Opportunity(Name = 'closed', AccountId = acc.Id, StageName = 'Closed Won', CloseDate = Date.today())
        };
        insert opps;

        Test.startTest();
        Integer cnt = BoniBannerController.getOpenOpportunityCount();
        Test.stopTest();

        System.assertEquals(2, cnt, '진행 중(미종결) 기회만 세어야 한다');
    }
}