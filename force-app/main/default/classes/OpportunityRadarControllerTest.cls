/**
 * Covers OpportunityRadarController, RecommendationOutcomeService and RadarRefreshSchedulable.
 */
@IsTest
private class OpportunityRadarControllerTest {
    private static final Decimal EOK = RadarTestDataFactory.EOK;

    @TestSetup
    static void setup() {
        RadarTestDataFactory.createProducts();
        List<Account> accounts = RadarTestDataFactory.createAccounts(2, true);
        RadarTestDataFactory.createStatements(accounts, 2026, 2, 12000 * EOK, 1000 * EOK, 0, 500 * EOK, 500 * EOK);
    }

    @IsTest
    static void shouldReturnAllAccountsWithKpis_WhenNoAccountFilter() {
        Test.startTest();
        OpportunityRadarController.RadarDTO dto = OpportunityRadarController.getRadar(null, false, 'all');
        Test.stopTest();

        Assert.areEqual(2, dto.accountCount, 'both accounts with statements');
        Assert.areEqual(2 * 2000 * EOK, dto.totalWhitespace, 'cash 1,000억 + bonds 1,000억 per account, nothing outstanding');
        Assert.areEqual(0, dto.averageShare, 'no deals → 0 share');
        OpportunityRadarController.AccountRow row = dto.accounts[0];
        Assert.areEqual('대기업', row.segment, '1.2조 assets → 대기업');
        Assert.areEqual(2, row.recommendations.size(), 'RP cross + 채권 cross generated on first load');
        Assert.isNotNull(row.propensity, 'top score exposed');
        Assert.areEqual(row.whitespace * row.propensity, row.priority, 'priority = whitespace × propensity');
    }

    @IsTest
    static void shouldReturnSingleAccount_WhenAccountIdGiven() {
        Account account = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        OpportunityRadarController.RadarDTO dto = OpportunityRadarController.getRadar(account.Id, true, null);
        Test.stopTest();

        Assert.areEqual(1, dto.accountCount, 'record-page mode returns one account');
        Assert.areEqual(account.Id, dto.accounts[0].accountId, 'the requested account');
    }

    @IsTest
    static void shouldCreateOpportunityAndSyncOutcome_WhenRecommendationConverted() {
        Account account = [SELECT Id FROM Account LIMIT 1];
        OpportunityRadarController.getRadar(account.Id, false, null);
        Recommendation__c rec = [SELECT Id, Expected_Amount__c, Product__r.Family FROM Recommendation__c WHERE Account__c = :account.Id AND Rank__c = 1 LIMIT 1];

        Test.startTest();
        Id opportunityId = OpportunityRadarController.createOpportunity(rec.Id);
        Opportunity created = [SELECT Amount, StageName, AccountId, Primary_Product__c FROM Opportunity WHERE Id = :opportunityId];
        Assert.areEqual(rec.Expected_Amount__c, created.Amount, 'amount from expected');
        Assert.areEqual('미팅', created.StageName, 'starts at 미팅');
        Assert.areEqual(account.Id, created.AccountId, 'linked to account');
        Recommendation__c linked = [SELECT Status__c, Opportunity__c FROM Recommendation__c WHERE Id = :rec.Id];
        Assert.areEqual('기회생성', linked.Status__c, 'status advanced');
        Assert.areEqual(opportunityId, linked.Opportunity__c, 'opportunity linked');

        created.StageName = 'Closed Won';
        update created;
        Integer synced = RecommendationOutcomeService.syncOutcomes(new Set<Id>{ account.Id });
        Test.stopTest();

        Assert.areEqual(1, synced, 'one recommendation synced');
        Assert.areEqual('수주', [SELECT Status__c FROM Recommendation__c WHERE Id = :rec.Id].Status__c, 'won outcome reflected');
    }

    @IsTest
    static void shouldRejectSecondConversion_WhenAlreadyCreated() {
        Account account = [SELECT Id FROM Account LIMIT 1];
        OpportunityRadarController.getRadar(account.Id, false, null);
        Recommendation__c rec = [SELECT Id FROM Recommendation__c WHERE Account__c = :account.Id AND Rank__c = 1 LIMIT 1];
        OpportunityRadarController.createOpportunity(rec.Id);

        Test.startTest();
        try {
            OpportunityRadarController.createOpportunity(rec.Id);
            Assert.fail('second conversion must fail');
        } catch (AuraHandledException e) {
            Assert.isTrue(true, 'AuraHandledException raised');
        }
        Test.stopTest();
    }

    @IsTest
    static void shouldThrow_WhenRecommendationIdNull() {
        Test.startTest();
        try {
            OpportunityRadarController.createOpportunity(null);
            Assert.fail('null id must fail');
        } catch (AuraHandledException e) {
            Assert.isTrue(true, 'AuraHandledException raised');
        }
        Test.stopTest();
    }

    @IsTest
    static void shouldRegenerateForAllAccounts_WhenScheduledJobRuns() {
        Test.startTest();
        Id jobId = RadarRefreshSchedulable.scheduleDaily();
        new RadarRefreshSchedulable().execute(null);
        Test.stopTest();

        Assert.isNotNull(jobId, 'job scheduled');
        Assert.areEqual(1, [SELECT COUNT() FROM CronTrigger WHERE Id = :jobId], 'cron registered');
        Assert.areEqual(4, [SELECT COUNT() FROM Recommendation__c], 'two proposals × two accounts');
    }

    @IsTest
    static void shouldKeepInProgressCard_AndNotReproposeSameFamily_UntilClosed() {
        Account account = [SELECT Id FROM Account LIMIT 1];
        OpportunityRadarController.getRadar(account.Id, false, null);
        Recommendation__c rec = [SELECT Id, Product__r.Family FROM Recommendation__c WHERE Account__c = :account.Id AND Rank__c = 1 LIMIT 1];
        Id opportunityId = OpportunityRadarController.createOpportunity(rec.Id);

        Test.startTest();
        OpportunityRadarController.RadarDTO afterCreate = OpportunityRadarController.getRadar(account.Id, true, null);
        Integer sameFamily = 0;
        Integer inProgress = 0;
        for (OpportunityRadarController.RecommendationDTO r : afterCreate.accounts[0].recommendations) {
            if (r.family == rec.Product__r.Family) { sameFamily++; }
            if (r.status == '기회생성') { inProgress++; }
        }
        Assert.areEqual(1, sameFamily, 'family with an open opportunity is shown once (the in-progress card), not re-proposed');
        Assert.areEqual(1, inProgress, 'in-progress card stays visible after regeneration');
        Assert.areEqual(1, afterCreate.accounts[0].recommendations[0].rank, 'display ranks renumbered from 1');

        Opportunity created = new Opportunity(Id = opportunityId, StageName = 'Closed Lost');
        update created;
        OpportunityRadarController.RadarDTO afterClose = OpportunityRadarController.getRadar(account.Id, true, null);
        Test.stopTest();

        Integer stillInProgress = 0;
        for (OpportunityRadarController.RecommendationDTO r : afterClose.accounts[0].recommendations) {
            if (r.status == '기회생성') { stillInProgress++; }
        }
        Assert.areEqual(0, stillInProgress, 'closed opportunity → card leaves the proposal list');
        Assert.areEqual('실패', [SELECT Status__c FROM Recommendation__c WHERE Id = :rec.Id].Status__c, 'history keeps the outcome');
        Assert.areEqual(1, afterClose.accounts[0].outcomes.size(), 'closed recommendation appears under 최근 결과');
        Assert.areEqual('실패', afterClose.accounts[0].outcomes[0].status, 'outcome status shown');
        Assert.areEqual(Date.today(), afterClose.accounts[0].outcomes[0].closedOn, 'closed date is today');
    }

    @IsTest
    static void shouldResolveAccountId_FromAccountOpportunityAndTask() {
        Account account = [SELECT Id, Name FROM Account LIMIT 1];
        Product2 product = [SELECT Id, Name FROM Product2 WHERE Family = 'RP' LIMIT 1];
        Opportunity opportunity = RadarTestDataFactory.buildOpportunity(account, product, 10 * EOK, Date.today(), Date.today().addDays(91), false);
        opportunity.StageName = '미팅';
        insert opportunity;
        Task task = new Task(Subject = '만기 30일 전 후속 영업 테스트', WhatId = opportunity.Id, Status = 'Not Started', Priority = 'Normal');
        insert task;

        Test.startTest();
        Assert.areEqual(account.Id, OpportunityRadarController.resolveAccountId(account.Id), 'account passes through');
        Assert.areEqual(account.Id, OpportunityRadarController.resolveAccountId(opportunity.Id), 'opportunity → its account');
        Assert.areEqual(account.Id, OpportunityRadarController.resolveAccountId(task.Id), 'task → what → account');
        Assert.isNull(OpportunityRadarController.resolveAccountId(null), 'null stays null');
        Test.stopTest();
    }

    @IsTest
    static void shouldReturnZero_WhenNothingToSync() {
        Test.startTest();
        Integer synced = RecommendationOutcomeService.syncOutcomes(null);
        Test.stopTest();
        Assert.areEqual(0, synced, 'no linked recommendations');
    }
}