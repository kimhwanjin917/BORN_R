/**
 * Tests for MaturityAlertBatch: boundary of the 30-day window, no Task for
 * Assets maturing beyond the window, and idempotency across re-runs.
 */
@isTest
private class MaturityAlertBatchTest {

    private static final String IN_WINDOW_PRODUCT = '퇴직연금 IRP';
    private static final String OUT_WINDOW_PRODUCT = '회사채 5년물';

    @TestSetup
    static void setupTestData() {
        Account account = new Account(
            Name = '테스트 법인고객',
            Industry = 'Finance',
            Business_Registration_Number__c = '1234567890'
        );
        insert account;

        Product2 inWindowProduct = new Product2(Name = IN_WINDOW_PRODUCT, IsActive = true);
        Product2 outWindowProduct = new Product2(Name = OUT_WINDOW_PRODUCT, IsActive = true);
        insert new List<Product2>{ inWindowProduct, outWindowProduct };

        List<Asset> assets = new List<Asset>();
        // Matures in 30 days exactly — inside the window (boundary).
        assets.add(new Asset(
            Name = '만기임박 자산',
            AccountId = account.Id,
            Product2Id = inWindowProduct.Id,
            UsageEndDate = Date.today().addDays(30)
        ));
        // Matures in 31 days — just outside the window.
        assets.add(new Asset(
            Name = '만기여유 자산',
            AccountId = account.Id,
            Product2Id = outWindowProduct.Id,
            UsageEndDate = Date.today().addDays(31)
        ));
        insert assets;
    }

    @isTest
    static void shouldCreateTask_WhenAssetMaturesWithinWindow() {
        // When
        Test.startTest();
        Database.executeBatch(new MaturityAlertBatch());
        Test.stopTest();

        // Then
        List<Task> tasks = [SELECT Id, Subject, WhatId, ActivityDate, Status, OwnerId FROM Task];
        Assert.areEqual(1, tasks.size(), 'Exactly one Task should be created for the in-window Asset');

        Asset inWindowAsset = [SELECT Id, UsageEndDate, Account.OwnerId FROM Asset WHERE Product2.Name = :IN_WINDOW_PRODUCT];
        Task created = tasks[0];
        Assert.areEqual(inWindowAsset.Id, created.WhatId, 'Task WhatId should point to the in-window Asset');
        Assert.areEqual(inWindowAsset.UsageEndDate, created.ActivityDate, 'ActivityDate should equal the maturity date');
        Assert.areEqual('Open', created.Status, 'Task should be Open');
        Assert.areEqual(inWindowAsset.Account.OwnerId, created.OwnerId, 'Task owner should be the Account Owner (RM)');
        Assert.areEqual('만기 30일 전 후속 영업 — ' + IN_WINDOW_PRODUCT, created.Subject, 'Subject should include the product name');
    }

    @isTest
    static void shouldNotCreateTask_WhenAssetMaturesBeyondWindow() {
        // When
        Test.startTest();
        Database.executeBatch(new MaturityAlertBatch());
        Test.stopTest();

        // Then
        Asset outWindowAsset = [SELECT Id FROM Asset WHERE Product2.Name = :OUT_WINDOW_PRODUCT];
        List<Task> tasks = [SELECT Id FROM Task WHERE WhatId = :outWindowAsset.Id];
        Assert.areEqual(0, tasks.size(), 'No Task should be created for an Asset maturing beyond 30 days');
    }

    @isTest
    static void shouldNotDuplicate_WhenRunTwice() {
        // Given — first run creates the Task
        Test.startTest();
        Database.executeBatch(new MaturityAlertBatch());
        Test.stopTest();

        Integer afterFirstRun = [SELECT COUNT() FROM Task];
        Assert.areEqual(1, afterFirstRun, 'First run should create exactly one Task');

        // When — the batch execute logic runs again over the same Assets
        List<Asset> inScopeAssets = [
            SELECT Id, UsageEndDate, Product2.Name, Account.OwnerId
            FROM Asset
            WHERE UsageEndDate >= TODAY AND UsageEndDate <= NEXT_N_DAYS:30
        ];
        MaturityAlertBatch batch = new MaturityAlertBatch();
        batch.execute(null, inScopeAssets);

        // Then — the open Task blocks re-creation
        Integer afterSecondRun = [SELECT COUNT() FROM Task];
        Assert.areEqual(afterFirstRun, afterSecondRun, 'Re-run must not create a duplicate Task for the same Asset');
    }

    @isTest
    static void shouldScheduleJob_WhenScheduleDailyCalled() {
        // When
        Test.startTest();
        String jobId = MaturityAlertBatch.scheduleDaily();
        Test.stopTest();

        // Then
        CronTrigger ct = [SELECT Id, CronExpression FROM CronTrigger WHERE Id = :jobId];
        Assert.areEqual(MaturityAlertBatch.CRON_WEEKDAYS_6AM, ct.CronExpression, 'Job should register with the weekday 6AM CRON');
    }
}