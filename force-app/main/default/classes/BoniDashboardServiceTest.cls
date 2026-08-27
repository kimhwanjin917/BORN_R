@IsTest
private class BoniDashboardServiceTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(Name = 'BONI-테스트법인', Business_Registration_Number__c = '9999999999');
        insert acc;
        Product2 prod = new Product2(Name = 'RP (환매조건부채권)', IsActive = true);
        insert prod;
        Id me = UserInfo.getUserId();
        insert new List<Opportunity>{
            new Opportunity(Name = 'BONI-만기D1', AccountId = acc.Id, StageName = 'Closed Won', CloseDate = Date.today().addDays(-30),
                Amount = 81200000000L, RP_Maturity_Date__c = Date.today().addDays(1), Primary_Product__c = prod.Id, OwnerId = me),
            new Opportunity(Name = 'BONI-만기D30', AccountId = acc.Id, StageName = 'Closed Won', CloseDate = Date.today().addDays(-30),
                Amount = 1000000000L, RP_Maturity_Date__c = Date.today().addDays(30), Primary_Product__c = prod.Id, OwnerId = me),
            new Opportunity(Name = 'BONI-이번주마감', AccountId = acc.Id, StageName = 'Prospecting', CloseDate = Date.today(),
                Amount = 5000000000L, OwnerId = me)
        };
        insert new Event(Subject = 'BONI-미팅', OwnerId = me, StartDateTime = Datetime.now().addHours(2), DurationInMinutes = 60, WhatId = acc.Id);
        insert new List<Task>{
            new Task(Subject = 'BONI-지연할일', OwnerId = me, ActivityDate = Date.today().addDays(-2), Status = 'Not Started'),
            new Task(Subject = 'BONI-완료할일', OwnerId = me, ActivityDate = Date.today(), Status = 'Completed')
        };
        insert new ExternalSignal__c(Title__c = 'BONI-수주공시', Account__c = acc.Id, Signal_Date__c = Date.today(),
            Relevance_Score__c = 85, Confidence__c = 70);
    }

    private static Boni_Target__mdt target(String role) {
        return new Boni_Target__mdt(DeveloperName = 'T', Data_User_Id__c = UserInfo.getUserId(),
            Slack_User_Id__c = 'U0TEST', Role__c = role, Is_Active__c = true);
    }

    @IsTest
    static void build_fillsAllSectionsWithinWindows() {
        BoniDashboardData d = BoniDashboardService.build(target('RM'), Date.today());
        Assert.areEqual(1, d.maturities.size(), '7일 창 안 만기 1건(D30 제외)');
        Assert.areEqual(1, d.maturities[0].daysLeft);
        Assert.areEqual(1, d.signals.size(), '시그널 임계값 통과 1건');
        Assert.areEqual(1, d.pipeline.closingThisWeek);
        Assert.areEqual(1, d.tasks.size(), '미완료 지연 할일 1건');
        Assert.areEqual(2, d.tasks[0].overdueDays);
        // 이벤트는 now+2h 가 자정을 넘길 수 있어 0 또는 1
        Assert.isTrue(d.events.size() <= 1);
        Assert.areEqual(!d.events.isEmpty(), d.calendarConnected);
    }

    @IsTest
    static void build_noEvents_marksCalendarNotConnected() {
        delete [SELECT Id FROM Event WHERE Subject = 'BONI-미팅'];
        BoniDashboardData d = BoniDashboardService.build(target('RM'), Date.today());
        Assert.isFalse(d.calendarConnected);
        Assert.areEqual(0, d.events.size());
    }

    @IsTest
    static void buildWrapup_countsTodayChanges() {
        BoniDashboardData d = BoniDashboardService.buildWrapup(target('RM'), Date.today());
        Assert.isNotNull(d.wrapup);
        Assert.areEqual(3, d.wrapup.updatedOpps.size(), '오늘 생성/수정된 Opp 3');
        Assert.areEqual(1, d.wrapup.completedTasks);
        Assert.areEqual(1, d.wrapup.carriedTasks);
        Assert.isTrue(d.wrapup.teamLines.isEmpty(), 'RM 은 팀 라인 없음');
    }

    @IsTest
    static void buildWrapup_managerWithoutRole_fallsBackToSelfAndHasTeamLine() {
        BoniDashboardData d = BoniDashboardService.buildWrapup(target('Manager'), Date.today());
        Assert.isFalse(d.wrapup.teamLines.isEmpty());
    }

    @IsTest
    static void load_defaultsWhenNoMdt() {
        BoniDashboardService.Settings s = BoniDashboardService.load();
        Assert.isTrue(s.maturityWindowDays > 0);
        Assert.isTrue(s.briefingHour >= 0 && s.briefingHour <= 23);
    }
}