@IsTest
private class IBDealSharingServiceTest {

    private static final String REASON = Schema.IB_Deal__Share.RowCause.IB_Deal_Team__c;

    @TestSetup
    static void setup() {
        Profile p = [SELECT Id FROM Profile WHERE UserType = 'Standard' LIMIT 1];
        String stamp = String.valueOf(Datetime.now().getTime());

        List<User> users = new List<User>();
        for (Integer i = 0; i < 3; i++) {
            users.add(new User(
                FirstName         = 'IBD',
                LastName          = 'Tester' + i,
                Alias             = 'ibd' + i,
                Email             = 'ibdeal' + i + '@example.com',
                Username          = 'ibdeal' + i + '.' + stamp + '@example.com.ibdtest',
                ProfileId         = p.Id,
                TimeZoneSidKey    = 'Asia/Seoul',
                LocaleSidKey      = 'en_US',
                EmailEncodingKey  = 'UTF-8',
                LanguageLocaleKey = 'en_US'
            ));
        }
        insert users;

        // User(설정 오브젝트)와 커스텀 오브젝트 DML을 한 트랜잭션에 섞지 않으려고 runAs로 감싼다
        System.runAs(new User(Id = UserInfo.getUserId())) {
            // IB_Deal__c 는 발행사(Account)와 원천 영업기회(Opportunity)가 필수다
            Account acc = new Account(
                Name = 'IBD Test Issuer',
                Business_Registration_Number__c = stamp.right(10)
            );
            insert acc;

            Opportunity opp = new Opportunity(
                Name      = 'IBD Test Opp',
                StageName = '미팅',
                CloseDate = Date.today().addDays(30),
                AccountId = acc.Id
            );
            insert opp;

            insert new List<IB_Deal__c>{
                new IB_Deal__c(Status__c = 'Pipeline',  Issuer_Account__c = acc.Id, Source_Opportunity__c = opp.Id),
                new IB_Deal__c(Status__c = 'Mandated', Issuer_Account__c = acc.Id, Source_Opportunity__c = opp.Id)
            };
        }
    }

    private static List<User> testers() {
        return [SELECT Id FROM User WHERE Alias LIKE 'ibd%' ORDER BY Alias];
    }

    private static List<IB_Deal__c> deals() {
        return [SELECT Id, OwnerId FROM IB_Deal__c ORDER BY CreatedDate];
    }

    private static List<IB_Deal__Share> sharesOf(Id dealId) {
        return [
            SELECT UserOrGroupId, AccessLevel
            FROM IB_Deal__Share
            WHERE ParentId = :dealId AND RowCause = :REASON
        ];
    }

    @IsTest
    static void readMemberGetsReadShare() {
        IB_Deal__c d = deals()[0];
        User u = testers()[0];

        Test.startTest();
        insert new IB_Deal_Team_Member__c(
            IB_Deal__c = d.Id, User__c = u.Id, Access_Level__c = 'Read', Role__c = 'Member'
        );
        Test.stopTest();

        List<IB_Deal__Share> s = sharesOf(d.Id);
        Assert.areEqual(1, s.size(), 'Read 멤버에게 공유 1건이 생겨야 한다');
        Assert.areEqual(u.Id, s[0].UserOrGroupId);
        Assert.areEqual('Read', s[0].AccessLevel);
    }

    @IsTest
    static void fullMemberGetsEditShare() {
        IB_Deal__c d = deals()[0];
        User u = testers()[0];

        Test.startTest();
        insert new IB_Deal_Team_Member__c(
            IB_Deal__c = d.Id, User__c = u.Id, Access_Level__c = 'Full', Role__c = 'Lead'
        );
        Test.stopTest();

        List<IB_Deal__Share> s = sharesOf(d.Id);
        Assert.areEqual(1, s.size());
        Assert.areEqual('Edit', s[0].AccessLevel, 'Full은 Edit로 매핑되어야 한다');
    }

    @IsTest
    static void noneLevelGetsNoShare() {
        IB_Deal__c d = deals()[0];

        Test.startTest();
        insert new IB_Deal_Team_Member__c(
            IB_Deal__c = d.Id, User__c = testers()[0].Id, Access_Level__c = 'None', Role__c = 'Support'
        );
        Test.stopTest();

        Assert.areEqual(0, sharesOf(d.Id).size(), 'None은 공유가 생기면 안 된다');
    }

    @IsTest
    static void expiredMemberGetsNoShare() {
        IB_Deal__c d = deals()[0];

        Test.startTest();
        insert new IB_Deal_Team_Member__c(
            IB_Deal__c         = d.Id,
            User__c            = testers()[0].Id,
            Access_Level__c    = 'Full',
            Access_Ended_At__c = Datetime.now().addDays(-1)
        );
        Test.stopTest();

        Assert.areEqual(0, sharesOf(d.Id).size(), '기간이 지난 멤버는 접근이 없어야 한다');
    }

    @IsTest
    static void futureWallCrossGetsNoShare() {
        IB_Deal__c d = deals()[0];

        Test.startTest();
        insert new IB_Deal_Team_Member__c(
            IB_Deal__c         = d.Id,
            User__c            = testers()[0].Id,
            Access_Level__c    = 'Read',
            Wall_Crossed_At__c = Datetime.now().addDays(3)
        );
        Test.stopTest();

        Assert.areEqual(0, sharesOf(d.Id).size(), '월크로스 전에는 접근이 없어야 한다');
    }

    @IsTest
    static void ownerIsSkipped() {
        IB_Deal__c d = deals()[0];

        Test.startTest();
        insert new IB_Deal_Team_Member__c(
            IB_Deal__c = d.Id, User__c = d.OwnerId, Access_Level__c = 'Full'
        );
        Test.stopTest();

        Assert.areEqual(0, sharesOf(d.Id).size(), '소유자에게는 공유를 만들지 않는다');
    }

    @IsTest
    static void deletingMemberIsBlocked() {
        IB_Deal__c d = deals()[0];
        IB_Deal_Team_Member__c m = new IB_Deal_Team_Member__c(
            IB_Deal__c = d.Id, User__c = testers()[0].Id, Access_Level__c = 'Read'
        );
        insert m;

        Test.startTest();
        String msg = '';
        try {
            delete m;
            Assert.fail('딜팀 멤버 삭제가 막혀야 한다');
        } catch (DmlException e) {
            msg = e.getMessage();
        }
        Test.stopTest();

        Assert.isTrue(msg.contains('접근 종료 일시'), '무엇을 대신 하라는지 안내해야 한다. 실제: ' + msg);
        Assert.areEqual(1, sharesOf(d.Id).size(), '삭제가 막혔으니 공유도 그대로여야 한다');
    }

    /** 접근 종료 일시를 채워도 삭제는 여전히 막혀야 한다. 채우는 것은 삭제의 조건이 아니다. */
    @IsTest
    static void deletingStaysBlockedAfterAccessEnded() {
        IB_Deal__c d = deals()[0];
        IB_Deal_Team_Member__c m = new IB_Deal_Team_Member__c(
            IB_Deal__c = d.Id, User__c = testers()[0].Id, Access_Level__c = 'Read'
        );
        insert m;
        update new IB_Deal_Team_Member__c(
            Id = m.Id, Access_Ended_At__c = Datetime.now().addMinutes(-1)
        );
        Assert.areEqual(0, sharesOf(d.Id).size(), '사전 조건: 접근은 이미 회수됐어야 한다');

        Test.startTest();
        Boolean blocked = false;
        try {
            delete m;
        } catch (DmlException e) {
            blocked = true;
        }
        Test.stopTest();

        Assert.isTrue(blocked, '종료 일시를 채웠어도 삭제는 막혀야 한다');
        Assert.areEqual(1, [SELECT COUNT() FROM IB_Deal_Team_Member__c WHERE Id = :m.Id],
            '명단 레코드는 남아 있어야 한다');
    }

    @IsTest
    static void endingAccessRevokesShare() {
        IB_Deal__c d = deals()[0];
        IB_Deal_Team_Member__c m = new IB_Deal_Team_Member__c(
            IB_Deal__c = d.Id, User__c = testers()[0].Id, Access_Level__c = 'Read'
        );
        insert m;
        Assert.areEqual(1, sharesOf(d.Id).size(), '사전 조건: 공유가 있어야 한다');

        Test.startTest();
        update new IB_Deal_Team_Member__c(
            Id = m.Id, Access_Ended_At__c = Datetime.now().addMinutes(-1)
        );
        Test.stopTest();

        Assert.areEqual(0, sharesOf(d.Id).size(), '접근 종료 일시를 채우면 회수되어야 한다');
    }

    @IsTest
    static void deletingDealCascadesMembers() {
        IB_Deal__c d = deals()[1];
        insert new IB_Deal_Team_Member__c(
            IB_Deal__c = d.Id, User__c = testers()[0].Id, Access_Level__c = 'Read'
        );

        Test.startTest();
        delete d;
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM IB_Deal_Team_Member__c WHERE IB_Deal__c = :d.Id],
            '딜을 지우면 딸린 멤버도 함께 지워져야 한다');
    }

    /**
     * 딜 A 를 지우면서 딜 B 의 멤버를 함께 지우려 하면, B 의 멤버는 막혀야 한다.
     * 통과 여부를 참/거짓 플래그가 아니라 딜 Id 로 판단하는지 확인한다.
     */
    @IsTest
    static void otherDealsMemberStaysBlockedDuringCascade() {
        List<IB_Deal__c> ds = deals();
        IB_Deal_Team_Member__c keep = new IB_Deal_Team_Member__c(
            IB_Deal__c = ds[0].Id, User__c = testers()[0].Id, Access_Level__c = 'Read'
        );
        insert keep;

        Test.startTest();
        Boolean blocked = false;
        try {
            delete new List<SObject>{ ds[1], keep };
        } catch (DmlException e) {
            blocked = true;
        }
        Test.stopTest();

        Assert.isTrue(blocked, '다른 딜의 멤버는 연쇄 삭제에 묻어가면 안 된다');
        Assert.areEqual(1, [SELECT COUNT() FROM IB_Deal_Team_Member__c WHERE Id = :keep.Id],
            '그 멤버는 남아 있어야 한다');
    }

    @IsTest
    static void wallCrossingIsStampedWhenBlank() {
        IB_Deal__c d = deals()[0];

        Test.startTest();
        IB_Deal_Team_Member__c m = new IB_Deal_Team_Member__c(
            IB_Deal__c = d.Id, User__c = testers()[0].Id, Access_Level__c = 'Read'
        );
        insert m;
        Test.stopTest();

        IB_Deal_Team_Member__c saved = [
            SELECT Wall_Crossed_At__c FROM IB_Deal_Team_Member__c WHERE Id = :m.Id
        ];
        Assert.isNotNull(saved.Wall_Crossed_At__c, '비워두면 등록 시각이 자동으로 채워져야 한다');
        Assert.areEqual(1, sharesOf(d.Id).size(), '자동 기입이 접근을 막으면 안 된다');
    }

    @IsTest
    static void explicitWallCrossingIsKept() {
        IB_Deal__c d = deals()[0];
        Datetime crossed = Datetime.newInstance(2026, 8, 1, 9, 0, 0);

        Test.startTest();
        IB_Deal_Team_Member__c m = new IB_Deal_Team_Member__c(
            IB_Deal__c = d.Id, User__c = testers()[0].Id,
            Access_Level__c = 'Read', Wall_Crossed_At__c = crossed
        );
        insert m;
        Test.stopTest();

        IB_Deal_Team_Member__c saved = [
            SELECT Wall_Crossed_At__c FROM IB_Deal_Team_Member__c WHERE Id = :m.Id
        ];
        Assert.areEqual(crossed, saved.Wall_Crossed_At__c, '직접 넣은 값은 덮어쓰지 않아야 한다');
    }

    @IsTest
    static void loweringLevelUpdatesShare() {
        IB_Deal__c d = deals()[0];
        IB_Deal_Team_Member__c m = new IB_Deal_Team_Member__c(
            IB_Deal__c = d.Id, User__c = testers()[0].Id, Access_Level__c = 'Full'
        );
        insert m;

        Test.startTest();
        // 변경할 필드만 보낸다 (마스터-디테일 등 수정 불가 필드를 같이 보내면 DML이 거부된다)
        update new IB_Deal_Team_Member__c(Id = m.Id, Access_Level__c = 'Read');
        Test.stopTest();

        List<IB_Deal__Share> s = sharesOf(d.Id);
        Assert.areEqual(1, s.size());
        Assert.areEqual('Read', s[0].AccessLevel, '권한을 낮추면 공유도 낮아져야 한다');
    }

    @IsTest
    static void multipleMembersEachGetShare() {
        IB_Deal__c d = deals()[0];
        List<User> us = testers();

        Test.startTest();
        insert new List<IB_Deal_Team_Member__c>{
            new IB_Deal_Team_Member__c(IB_Deal__c = d.Id, User__c = us[0].Id, Access_Level__c = 'Read'),
            new IB_Deal_Team_Member__c(IB_Deal__c = d.Id, User__c = us[1].Id, Access_Level__c = 'Full'),
            new IB_Deal_Team_Member__c(IB_Deal__c = d.Id, User__c = us[2].Id, Access_Level__c = 'None')
        };
        Test.stopTest();

        Assert.areEqual(2, sharesOf(d.Id).size(), 'Read/Full 두 명만 공유가 생겨야 한다');
    }

    @IsTest
    static void otherDealIsNotAffected() {
        List<IB_Deal__c> ds = deals();

        Test.startTest();
        insert new IB_Deal_Team_Member__c(
            IB_Deal__c = ds[0].Id, User__c = testers()[0].Id, Access_Level__c = 'Read'
        );
        Test.stopTest();

        Assert.areEqual(1, sharesOf(ds[0].Id).size());
        Assert.areEqual(0, sharesOf(ds[1].Id).size(), '다른 딜은 영향을 받으면 안 된다');
    }

    @IsTest
    static void barrierEndedRevokesEveryone() {
        IB_Deal__c d = deals()[0];
        List<User> us = testers();
        insert new List<IB_Deal_Team_Member__c>{
            new IB_Deal_Team_Member__c(IB_Deal__c = d.Id, User__c = us[0].Id, Access_Level__c = 'Full'),
            new IB_Deal_Team_Member__c(IB_Deal__c = d.Id, User__c = us[1].Id, Access_Level__c = 'Read')
        };
        Assert.areEqual(2, sharesOf(d.Id).size(), '사전 조건: 두 명 모두 공유가 있어야 한다');

        Test.startTest();
        update new IB_Deal__c(Id = d.Id, Barrier_End_At__c = Datetime.now().addMinutes(-1));
        IBDealSharingService.recalculate(new Set<Id>{ d.Id });
        Test.stopTest();

        Assert.areEqual(0, sharesOf(d.Id).size(), '차단 기간이 끝나면 딜팀 전원이 회수되어야 한다');
    }

    @IsTest
    static void barrierNotYetEndedKeepsAccess() {
        IB_Deal__c d = deals()[0];
        insert new IB_Deal_Team_Member__c(
            IB_Deal__c = d.Id, User__c = testers()[0].Id, Access_Level__c = 'Read'
        );

        Test.startTest();
        update new IB_Deal__c(Id = d.Id, Barrier_End_At__c = Datetime.now().addDays(7));
        IBDealSharingService.recalculate(new Set<Id>{ d.Id });
        Test.stopTest();

        Assert.areEqual(1, sharesOf(d.Id).size(), '차단 기간이 남아 있으면 접근이 유지되어야 한다');
    }

    @IsTest
    static void barrierEndOverridesMemberDates() {
        IB_Deal__c d = deals()[0];
        // 멤버 쪽은 아직 유효하다 — 종료일이 한참 뒤고 월크로스도 지났다
        insert new IB_Deal_Team_Member__c(
            IB_Deal__c         = d.Id,
            User__c            = testers()[0].Id,
            Access_Level__c    = 'Full',
            Wall_Crossed_At__c = Datetime.now().addDays(-10),
            Access_Ended_At__c = Datetime.now().addDays(90)
        );
        Assert.areEqual(1, sharesOf(d.Id).size(), '사전 조건: 공유가 있어야 한다');

        Test.startTest();
        update new IB_Deal__c(Id = d.Id, Barrier_End_At__c = Datetime.now().addMinutes(-1));
        IBDealSharingService.recalculate(new Set<Id>{ d.Id });
        Test.stopTest();

        Assert.areEqual(0, sharesOf(d.Id).size(), '딜 차단 기간이 멤버 종료일보다 우선해야 한다');
    }

    @IsTest
    static void emptyInputIsSafe() {
        Test.startTest();
        IBDealSharingService.recalculate(null);
        IBDealSharingService.recalculate(new Set<Id>());
        Assert.areEqual(0, IBDealSharingService.dealIdsOf(null).size());
        Test.stopTest();
    }
}