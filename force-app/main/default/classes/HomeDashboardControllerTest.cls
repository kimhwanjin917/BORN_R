@isTest
private class HomeDashboardControllerTest {

    private static final String INDUSTRY = '제조업';
    private static final String MATURITY_SUBJECT = '만기 30일 전 후속 영업 — 테스트제품';

    @TestSetup
    static void setup() {
        Account topAcct = new Account(
            Name = 'Top Priority Acct',
            Priority_Score__c = 90,
            Industry = INDUSTRY,
            Business_Registration_Number__c = '2000000001'
        );
        Account plainAcct = new Account(
            Name = 'No Score Acct',
            Business_Registration_Number__c = '2000000002'
        );
        insert new List<Account>{ topAcct, plainAcct };

        Lead topLead = new Lead(
            LastName = 'Lead',
            Company = 'Top Priority Lead Co',
            Status = 'New',
            Email = 'test.lead@example.com',
            Business_Registration_Number__c = '3000000001',
            name_new__c = 'L001',
            Priority_Score__c = 80,
            Industry = INDUSTRY
        );
        insert topLead;

        Id userId = UserInfo.getUserId();

        // A today's meeting has the shape a converted Lead leaves behind:
        // WhoId is the Contact and WhatId is the Opportunity that '미팅 시작'
        // hands to the Meeting_Session Flow. (A Lead WhoId cannot carry a
        // WhatId, so the pre-conversion shape can never drive that button.)
        Contact meetingContact = new Contact(
            LastName = 'Meeting Contact',
            AccountId = topAcct.Id,
            Email = 'meeting.contact@example.com',
            name_new__c = 'C001'
        );
        insert meetingContact;

        Opportunity meetingOpp = new Opportunity(
            Name = 'Top Priority Opp',
            AccountId = topAcct.Id,
            StageName = '미팅',
            CloseDate = Date.today().addDays(30)
        );
        insert meetingOpp;

        insert new Event(
            OwnerId = userId,
            Subject = '오늘 미팅',
            WhoId = meetingContact.Id,
            WhatId = meetingOpp.Id,
            StartDateTime = Datetime.now(),
            DurationInMinutes = 30
        );

        Product2 maturityProduct = new Product2(Name = '현재 상품명', IsActive = true);
        insert maturityProduct;

        Asset maturityAsset = new Asset(
            Name = '테스트 자산명',
            AccountId = topAcct.Id,
            Product2Id = maturityProduct.Id,
            UsageEndDate = Date.today().addDays(10)
        );
        insert maturityAsset;

        insert new Task(
            OwnerId = userId,
            Subject = MATURITY_SUBJECT,
            WhatId = maturityAsset.Id,
            Status = 'Open',
            ActivityDate = Date.today().addDays(10)
        );

        insert new List<ExternalSignal__c>{
            new ExternalSignal__c(
                Signal_Type__c = '뉴스',
                Title__c = '기존기업 뉴스',
                Summary__c = '계정 관련 뉴스 요약',
                Signal_Date__c = Date.today(),
                Account__c = topAcct.Id
            ),
            new ExternalSignal__c(
                Signal_Type__c = '뉴스',
                Title__c = '리드 뉴스',
                Summary__c = '리드 관련 뉴스 요약',
                Signal_Date__c = Date.today().addDays(-1),
                Lead__c = topLead.Id
            ),
            new ExternalSignal__c(
                Signal_Type__c = '뉴스',
                Title__c = '산업군 뉴스',
                Summary__c = '산업군 관련 뉴스 요약',
                Signal_Date__c = Date.today().addDays(-2),
                Industry__c = INDUSTRY
            ),
            new ExternalSignal__c(
                Signal_Type__c = '공시',
                Title__c = '공시 (뉴스 아님)',
                Signal_Date__c = Date.today(),
                Account__c = topAcct.Id
            ),
            new ExternalSignal__c(
                Signal_Type__c = '기타',
                Summary_Text__c = '오늘의 뉴스 요약 텍스트',
                Summary_Date__c = Date.today(),
                OwnerId = userId
            )
        };
    }

    @isTest
    static void getTodayEventsReturnsOwnedTodayEvents() {
        Test.startTest();
        List<Event> events = HomeDashboardController.getTodayEvents();
        Test.stopTest();

        System.assertEquals(1, events.size(), 'Today event owned by user must be returned');
        System.assertEquals('오늘 미팅', events[0].Subject, 'Subject should match');
        System.assertNotEquals(
            null,
            events[0].WhatId,
            'WhatId(Opportunity) must be populated — 미팅 시작 passes it to Meeting_Session'
        );
        System.assertNotEquals(
            null,
            events[0].What.Name,
            'What.Name must be selected so the row can show the related Opportunity'
        );
    }

    @isTest
    static void getMaturityAlertTasksReturnsOpenAlerts() {
        Test.startTest();
        List<Task> tasks = HomeDashboardController.getMaturityAlertTasks();
        List<HomeDashboardController.MaturityAlertTaskRow> rows = HomeDashboardController.getMaturityAlertTaskRows();
        Test.stopTest();

        System.assertEquals(1, tasks.size(), 'Open maturity-alert task must be returned');
        System.assert(
            tasks[0].Subject.startsWith('만기 30일 전 후속 영업'),
            'Subject must match the maturity-alert prefix'
        );
        Assert.areEqual(1, rows.size(), 'One enriched maturity-alert row must be returned');
        Assert.areEqual('테스트 자산명', rows[0].assetName, 'Current Asset name must be returned');
        Assert.areEqual(
            Date.today().addDays(10),
            rows[0].maturityDate,
            'Current Asset maturity date must be returned'
        );
    }

    @isTest
    static void getDailySummaryReturnsLatestSummaryText() {
        Test.startTest();
        String summary = HomeDashboardController.getDailySummary();
        Test.stopTest();

        System.assertEquals('오늘의 뉴스 요약 텍스트', summary, 'Latest stored summary text must be returned');
    }

    @isTest
    static void getPriorityNewsReturnsNewsForPriorityPartiesAndIndustries() {
        Test.startTest();
        List<ExternalSignal__c> news = HomeDashboardController.getPriorityNews();
        Test.stopTest();

        System.assertEquals(3, news.size(), 'Three 뉴스 signals (account, lead, industry) must be returned');
        System.assert(
            news[0].Signal_Date__c >= news[news.size() - 1].Signal_Date__c,
            'News must be ordered by Signal_Date__c descending'
        );

        // The linked party's industry must be selected so the 산업군 tab can
        // group news by KSIC 대분류.
        Boolean sawPartyIndustry = false;
        for (ExternalSignal__c signal : news) {
            if (signal.Account__r != null && signal.Account__r.Industry == INDUSTRY) {
                sawPartyIndustry = true;
            }
            if (signal.Lead__r != null && signal.Lead__r.Industry == INDUSTRY) {
                sawPartyIndustry = true;
            }
        }
        System.assert(
            sawPartyIndustry,
            'Linked Account/Lead Industry must be selected for KSIC grouping'
        );
    }
}