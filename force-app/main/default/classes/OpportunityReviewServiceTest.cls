@IsTest
private class OpportunityReviewServiceTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(Name = '대성정밀(주)', Industry = '제조업', Business_Registration_Number__c = '1234567890');
        insert acc;
        insert new Contact(LastName = '김담당', name_new__c = '김담당', AccountId = acc.Id, Email = 'kim@daesung.demo');
        Product2 rp = new Product2(Name = 'RP (환매조건부채권)', Family = 'RP', IsActive = true, Default_Fee_Rate__c = 0.5);
        insert rp;
        insert new Opportunity(
            Name = '대성정밀 RP', AccountId = acc.Id, StageName = '심사', CloseDate = Date.today().addDays(30),
            Amount = 100000000, Primary_Product__c = rp.Id, RP_Yield__c = 3.2, RP_Maturity_Date__c = Date.today().addMonths(6),
            Issuer_Name__c = '한국전력', Coupon_Rate__c = 4.1
        );
    }

    /** docs/58 (ADR-0004): 트리거는 더 이상 자동 심사를 하지 않는다 — 딜 Slack 채널만 만든다. Slack 은 mock. */
    private class SlackOkMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse r = new HttpResponse();
            r.setStatusCode(200);
            String ep = req.getEndpoint();
            r.setBody(ep.contains('conversations.create') ? '{"ok":true,"channel":{"id":"C0T","name":"t"}}'
                : ep.contains('lookupByEmail') ? '{"ok":true,"user":{"id":"U0T"}}' : '{"ok":true,"ts":"1.1"}');
            return r;
        }
    }

    @IsTest
    static void meetingLogChange_doesNothing_ButCompleteReviewStillWorks() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        Test.setMock(HttpCalloutMock.class, new SlackOkMock());

        Test.startTest();
        opp.Meeting_Log__c = '2026-08-26 미팅: RP 1억 6개월 조건 합의';
        update opp; // OpportunityReviewTrigger 비활성 — 아무 일도 일어나지 않는다
        Test.stopTest();

        opp = [SELECT Approval_Status__c, StageName, Slack_Channel_ID__c FROM Opportunity WHERE Id = :opp.Id];
        Assert.areNotEqual(OpportunityReviewService.APPROVED, opp.Approval_Status__c, '미팅 로그 저장만으로 승인되지 않는다');
        Assert.areEqual(0, [SELECT COUNT() FROM Contract WHERE SourceOpportunityId = :opp.Id], '계약서는 버튼 전까지 안 만든다');
        Assert.isNull(opp.Slack_Channel_ID__c, '트리거 비활성 — 딜 채널도 자동 생성되지 않는다([상품팀 전달] 버튼이 만든다)');

        // RM [계약서 생성] 버튼이 부르는 경로
        OpportunityReviewService.completeReview(new List<Id>{ opp.Id });

        opp = [SELECT Approval_Status__c, StageName FROM Opportunity WHERE Id = :opp.Id];
        Assert.areEqual(OpportunityReviewService.APPROVED, opp.Approval_Status__c);
        Assert.areEqual(OpportunityReviewService.STAGE_DEAL_CLOSED, opp.StageName);

        List<Contract> contracts = [SELECT Id, Status, Contract_Amount__c, RP_Yield__c, Product__c, ContractTerm, Fee_Rate__c FROM Contract WHERE SourceOpportunityId = :opp.Id];
        Assert.areEqual(1, contracts.size(), '계약 1건 자동 생성');
        Assert.areEqual('Draft', contracts[0].Status);
        Assert.areEqual(100000000, contracts[0].Contract_Amount__c);
        Assert.areEqual(3.2, contracts[0].RP_Yield__c);
        Assert.areEqual(0.5, contracts[0].Fee_Rate__c, '수수료율은 상품에서');
        Assert.isTrue(contracts[0].ContractTerm >= 6, '만기까지 개월: ' + contracts[0].ContractTerm);

        Assert.areEqual(1, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :contracts[0].Id], 'PDF가 계약에 첨부');
        Assert.areEqual(1, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :opp.Id], 'PDF가 기회에도 첨부');

        List<Task> tasks = [SELECT Subject, WhatId, Priority FROM Task WHERE WhatId = :opp.Id];
        Assert.areEqual(1, tasks.size());
        Assert.areEqual(OpportunityReviewService.TASK_SUBJECT, tasks[0].Subject);
    }

    @IsTest
    static void shouldRunOnlyOnce_WhenAlreadyApproved() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        Test.setMock(HttpCalloutMock.class, new SlackOkMock());
        opp.Approval_Status__c = OpportunityReviewService.APPROVED;
        opp.Meeting_Log__c = '첫 로그';
        update opp;

        Test.startTest();
        opp.Meeting_Log__c = '두 번째 로그';
        update opp;
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Contract WHERE SourceOpportunityId = :opp.Id], '이미 승인된 기회는 건너뜀');
        Assert.areEqual(0, [SELECT COUNT() FROM Task WHERE WhatId = :opp.Id]);
    }

    @IsTest
    static void shouldIgnoreUpdatesWithoutMeetingLogChange() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        Test.startTest();
        opp.Amount = 200000000;
        update opp;
        Test.stopTest();
        Assert.isNull([SELECT Approval_Status__c FROM Opportunity WHERE Id = :opp.Id].Approval_Status__c);
        Assert.areEqual(0, [SELECT COUNT() FROM Contract WHERE SourceOpportunityId = :opp.Id]);
    }

    @IsTest
    static void completeReviewShouldSkipClosedAndReturnProcessed() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        List<Id> done = OpportunityReviewService.completeReview(new List<Id>{ opp.Id });
        Assert.areEqual(1, done.size());
        Assert.areEqual(0, OpportunityReviewService.completeReview(new List<Id>{ opp.Id }).size(), '두 번째 호출은 건너뜀');
    }

    @IsTest
    static void bellNotificationShouldNotThrow() {
        Opportunity opp = [SELECT Id, OwnerId FROM Opportunity LIMIT 1];
        OpportunityReviewService.sendBellNotification('제목', '본문', opp.OwnerId, opp.Id);
        Assert.isTrue(true, '알림 유형 유무와 무관하게 예외 없이 끝남');
    }
}