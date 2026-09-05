/**
 * Tests for MaturityAlertService. Builds its own data in @TestSetup (AGENTS.md freezes
 * TestDataFactory.cls), including a distinct RM user so the owner-copy behaviour is
 * genuinely exercised rather than defaulting to the running user.
 */
@IsTest
private class MaturityAlertServiceTest {
    private static final String ACCOUNT_NAME = '만기알림_테스트고객';

    @TestSetup
    static void setup() {
        // User is a setup object: isolate its DML inside runAs to avoid MIXED_DML with the
        // Account/Asset/Task DML that follows.
        User rm = buildRmUser();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert rm;
        }

        Account acc = new Account(
            Name = ACCOUNT_NAME,
            OwnerId = rm.Id,
            Business_Registration_Number__c = '7010000010' // org-required field on Account
        );
        insert acc;

        insert new List<Asset>{
            newAsset('within10', acc.Id, Date.today().addDays(10)),
            newAsset('within30', acc.Id, Date.today().addDays(30)), // window boundary (inclusive)
            newAsset('outside31', acc.Id, Date.today().addDays(31)), // just outside
            newAsset('past5', acc.Id, Date.today().addDays(-5)),     // already matured
            newAsset('dup15', acc.Id, Date.today().addDays(15))      // will get a pre-existing alert
        };

        // Pre-existing OPEN maturity alert on dup15 → the service must not duplicate it.
        Asset dup = [SELECT Id FROM Asset WHERE Name = 'dup15' LIMIT 1];
        insert new Task(
            Subject = MaturityAlertService.SUBJECT_PREFIX + ' - dup15',
            WhatId = dup.Id,
            OwnerId = rm.Id,
            Status = 'Not Started',
            Priority = 'High',
            ActivityDate = Date.today().addDays(15)
        );
    }

    @IsTest
    static void createsAlertForMaturingAssetWithAccountOwner() {
        Test.startTest();
        MaturityAlertService.generateAlerts();
        Test.stopTest();

        Asset within10 = [SELECT Id, UsageEndDate FROM Asset WHERE Name = 'within10' LIMIT 1];
        Account acc = [SELECT OwnerId FROM Account WHERE Name = :ACCOUNT_NAME LIMIT 1];
        List<Task> tasks = [
            SELECT Subject, WhatId, OwnerId, ActivityDate, Status, Priority
            FROM Task
            WHERE WhatId = :within10.Id AND IsClosed = false
        ];

        System.assertEquals(1, tasks.size(), 'Expected exactly one alert for the maturing asset');
        Task t = tasks[0];
        System.assert(
            t.Subject.startsWith(MaturityAlertService.SUBJECT_PREFIX),
            'Subject must match the home card LIKE pattern: ' + t.Subject
        );
        System.assertEquals(acc.OwnerId, t.OwnerId, 'Task owner must be the Account owner (RM)');
        System.assertEquals(within10.UsageEndDate, t.ActivityDate, 'ActivityDate must be the maturity date');
        System.assertEquals('Not Started', t.Status);
    }

    @IsTest
    static void excludesAssetsOutsideThirtyDayWindow() {
        Test.startTest();
        MaturityAlertService.generateAlerts();
        Test.stopTest();

        Set<Id> outsideIds = new Map<Id, Asset>([
            SELECT Id FROM Asset WHERE Name IN ('outside31', 'past5')
        ]).keySet();
        Integer count = [SELECT COUNT() FROM Task WHERE WhatId IN :outsideIds AND IsClosed = false];
        System.assertEquals(0, count, 'Assets maturing outside the 30-day window must not get alerts');
    }

    @IsTest
    static void doesNotDuplicateExistingOpenAlert() {
        Asset dup = [SELECT Id FROM Asset WHERE Name = 'dup15' LIMIT 1];

        Test.startTest();
        MaturityAlertService.generateAlerts(); // runs twice to prove idempotency
        MaturityAlertService.generateAlerts();
        Test.stopTest();

        Integer count = [SELECT COUNT() FROM Task WHERE WhatId = :dup.Id AND IsClosed = false];
        System.assertEquals(1, count, 'An asset with an existing open alert must not be duplicated');
    }

    @IsTest
    static void bulkCreatesOneAlertPerAsset() {
        Id accId = [SELECT Id FROM Account WHERE Name = :ACCOUNT_NAME LIMIT 1].Id;
        List<Asset> bulkAssets = new List<Asset>();
        for (Integer i = 0; i < 200; i++) {
            bulkAssets.add(newAsset('bulk' + i, accId, Date.today().addDays(5)));
        }
        insert bulkAssets;

        Set<Id> bulkIds = new Map<Id, Asset>(bulkAssets).keySet();

        Test.startTest();
        MaturityAlertService.generateAlerts();
        Test.stopTest();

        Integer bulkCount = [SELECT COUNT() FROM Task WHERE WhatId IN :bulkIds AND IsClosed = false];
        System.assertEquals(200, bulkCount, 'Each maturing asset should produce exactly one alert');
    }

    // ─── helpers ────────────────────────────────────────────────────────────
    private static Asset newAsset(String name, Id accountId, Date usageEnd) {
        return new Asset(Name = name, AccountId = accountId, UsageEndDate = usageEnd);
    }

    private static User buildRmUser() {
        String unique = String.valueOf(DateTime.now().getTime()) + Crypto.getRandomInteger();
        return new User(
            LastName = '담당RM',
            Email = 'maturity.rm@newborn.test.invalid',
            Username = 'maturity.rm.' + unique + '@newborn.test.invalid',
            Alias = 'mrm',
            TimeZoneSidKey = 'Asia/Seoul',
            LocaleSidKey = 'ko_KR',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'ko',
            ProfileId = UserInfo.getProfileId()
        );
    }
}