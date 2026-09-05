@IsTest
private class IBDealAccessExpiryBatchTest {

    private static final String REASON = Schema.IB_Deal__Share.RowCause.IB_Deal_Team__c;

    @TestSetup
    static void setup() {
        Profile p = [SELECT Id FROM Profile WHERE UserType = 'Standard' LIMIT 1];
        String stamp = String.valueOf(Datetime.now().getTime());

        insert new User(
            FirstName         = 'IBX',
            LastName          = 'Expiry',
            Alias             = 'ibx0',
            Email             = 'ibxexpiry@example.com',
            Username          = 'ibxexpiry.' + stamp + '@example.com.ibxtest',
            ProfileId         = p.Id,
            TimeZoneSidKey    = 'Asia/Seoul',
            LocaleSidKey      = 'en_US',
            EmailEncodingKey  = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );

        System.runAs(new User(Id = UserInfo.getUserId())) {
            // IB_Deal__c 는 발행사(Account)와 원천 영업기회(Opportunity)가 필수다
            Account acc = new Account(
                Name = 'IBX Test Issuer',
                Business_Registration_Number__c = stamp.right(10)
            );
            insert acc;

            Opportunity opp = new Opportunity(
                Name      = 'IBX Test Opp',
                StageName = '미팅',
                CloseDate = Date.today().addDays(30),
                AccountId = acc.Id
            );
            insert opp;

            insert new IB_Deal__c(
                Status__c                     = 'Execution',
                Issuer_Account__c             = acc.Id,
                Source_Opportunity__c         = opp.Id,
                // 배치는 차단벽이 살아 있는 딜만 훑는다
                Information_Barrier_Status__c = 'Active'
            );
        }
    }

    private static User tester() {
        return [SELECT Id FROM User WHERE Alias = 'ibx0' LIMIT 1];
    }

    private static IB_Deal__c deal() {
        return [SELECT Id FROM IB_Deal__c LIMIT 1];
    }

    private static Integer shareCount(Id dealId) {
        return [
            SELECT COUNT()
            FROM IB_Deal__Share
            WHERE ParentId = :dealId AND RowCause = :REASON
        ];
    }

    /**
     * 기간이 지난 멤버인데 공유가 남아 있는 상황(시간 경과로 트리거가 돌지 않은 경우)을
     * 만들어 두고, 배치가 그 공유를 회수하는지 확인한다.
     */
    @IsTest
    static void batchRevokesExpiredAccess() {
        IB_Deal__c d = deal();
        User u = tester();

        // 아직 유효한 멤버 → 트리거가 공유를 만든다
        IB_Deal_Team_Member__c m = new IB_Deal_Team_Member__c(
            IB_Deal__c         = d.Id,
            User__c            = u.Id,
            Access_Level__c    = 'Full',
            Access_Ended_At__c = Datetime.now().addDays(1)
        );
        insert m;
        Assert.areEqual(1, shareCount(d.Id), '사전 조건: 공유가 있어야 한다');

        // 트리거를 거치지 않고 만료 상태로 만든다 (시간이 흐른 상황을 흉내)
        update new IB_Deal_Team_Member__c(
            Id = m.Id, Access_Ended_At__c = Datetime.now().addMinutes(-1)
        );

        Test.startTest();
        Database.executeBatch(new IBDealAccessExpiryBatch(), 200);
        Test.stopTest();

        Assert.areEqual(0, shareCount(d.Id), '배치가 만료된 접근을 회수해야 한다');
    }

    /** 유효한 멤버의 접근은 배치가 건드리지 않는다. */
    @IsTest
    static void batchKeepsValidAccess() {
        IB_Deal__c d = deal();

        insert new IB_Deal_Team_Member__c(
            IB_Deal__c         = d.Id,
            User__c            = tester().Id,
            Access_Level__c    = 'Read',
            Access_Ended_At__c = Datetime.now().addDays(30)
        );
        Assert.areEqual(1, shareCount(d.Id));

        Test.startTest();
        Database.executeBatch(new IBDealAccessExpiryBatch(), 200);
        Test.stopTest();

        Assert.areEqual(1, shareCount(d.Id), '유효한 접근은 유지되어야 한다');
    }

    /**
     * 멤버는 아직 유효한데 딜의 차단 기간만 끝난 경우.
     * 트리거는 돌지 않으므로 배치가 잡아야 한다.
     */
    @IsTest
    static void batchRevokesWhenBarrierEnded() {
        IB_Deal__c d = deal();

        insert new IB_Deal_Team_Member__c(
            IB_Deal__c         = d.Id,
            User__c            = tester().Id,
            Access_Level__c    = 'Full',
            Access_Ended_At__c = Datetime.now().addDays(90)
        );
        Assert.areEqual(1, shareCount(d.Id), '사전 조건: 공유가 있어야 한다');

        // 딜만 수정한다 — 멤버 트리거는 돌지 않는다
        update new IB_Deal__c(Id = d.Id, Barrier_End_At__c = Datetime.now().addMinutes(-1));
        Assert.areEqual(1, shareCount(d.Id), '사전 조건: 배치 전에는 그대로 남아 있어야 한다');

        Test.startTest();
        Database.executeBatch(new IBDealAccessExpiryBatch(), 200);
        Test.stopTest();

        Assert.areEqual(0, shareCount(d.Id), '배치가 차단 기간이 끝난 딜을 회수해야 한다');
    }

    /** 스케줄 진입점이 배치를 띄우는지 확인한다. */
    @IsTest
    static void schedulableStartsBatch() {
        Test.startTest();
        String jobId = System.schedule(
            'IBDealAccessExpiryBatchTest',
            '0 0 3 * * ?',
            new IBDealAccessExpiryBatch()
        );
        Test.stopTest();

        CronTrigger ct = [SELECT Id, CronExpression FROM CronTrigger WHERE Id = :jobId];
        Assert.areEqual('0 0 3 * * ?', ct.CronExpression);
    }
}