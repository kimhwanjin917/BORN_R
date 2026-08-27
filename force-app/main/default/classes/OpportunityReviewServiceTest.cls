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

    @IsTest
    static void shouldApproveCreateContractNotifyAndAdvanceStage_OnMeetingLogChange() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];

        Test.startTest();
        opp.Meeting_Log__c = '2026-08-26 미팅: RP 1억 6개월 조건 합의';
        update opp; // OpportunityReviewTrigger → Queueable
        Test.stopTest();

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