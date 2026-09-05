@IsTest
private class TeamCoachingControllerTest {

    private static final String RM_EMAIL = 'coaching.ctrl.test@example.com';

    @TestSetup
    static void setup() {
        Profile standard = [SELECT Id FROM Profile WHERE UserType = 'Standard' LIMIT 1];
        insert new User(
            FirstName = '예은',
            LastName = '정',
            Alias = 'jye',
            Email = RM_EMAIL,
            Username = 'coaching.ctrl.' + DateTime.now().getTime() + '@example.com.invalid',
            ProfileId = standard.Id,
            TimeZoneSidKey = 'Asia/Seoul',
            LocaleSidKey = 'ko_KR',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'ko',
            Quota_Fee__c = 25000000000L // 250억
        );
    }

    private static User rm() {
        return [SELECT Id, Name FROM User WHERE Email = :RM_EMAIL LIMIT 1];
    }

    private class OkMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            if (req.getEndpoint().contains('/conversations.list')) {
                res.setBody('{"ok":true,"channels":[],"response_metadata":{"next_cursor":""}}');
            } else if (req.getEndpoint().contains('/conversations.create')) {
                res.setBody('{"ok":true,"channel":{"id":"C-1","name":"rm-정예은과의-채널"}}');
            } else if (req.getEndpoint().contains('/users.lookupByEmail')) {
                res.setBody('{"ok":true,"user":{"id":"U-1"}}');
            } else {
                res.setBody('{"ok":true,"ts":"1.1"}');
            }
            return res;
        }
    }

    private class TableauMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            if (req.getEndpoint().contains('/auth/signin')) {
                res.setStatusCode(200);
                res.setBody('{"credentials":{"token":"t","site":{"id":"s"}}}');
            } else {
                res.setStatusCode(202);
                res.setBody('{"job":{"id":"j-1"}}');
            }
            return res;
        }
    }

    @IsTest
    static void sendCoachingReturnsResult() {
        User rm = rm();
        Test.setMock(HttpCalloutMock.class, new OkMock());

        Test.startTest();
        TeamCoachingService.CoachingResult result =
            TeamCoachingController.sendCoaching(rm.Id, rm.Name, '미팅', '체류가 깁니다. 진행 상황 공유 부탁드립니다.');
        Test.stopTest();

        Assert.isTrue(result.slackSent);
        Assert.isNotNull(result.taskId);
    }

    @IsTest
    static void sendCoachingSurfacesValidationErrorToLwc() {
        Test.startTest();
        try {
            TeamCoachingController.sendCoaching(null, '강 하은', '미팅', '메시지');
            Assert.fail('User Id 없이 발송되면 안 된다');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e, 'LWC 가 받을 수 있는 예외로 감싸야 한다');
        }
        Test.stopTest();
    }

    @IsTest
    static void updateQuotaStoresWonFromEok() {
        // 화면은 억 단위, 필드는 원 단위. 변환이 어긋나면 달성률이 통째로 틀어진다.
        User rm = rm();

        Test.startTest();
        TeamCoachingController.QuotaResult result = TeamCoachingController.updateQuota(rm.Id, 480);
        Test.stopTest();

        Assert.areEqual(480, result.quotaEok);
        Assert.areEqual(48000000000L, [SELECT Quota_Fee__c FROM User WHERE Id = :rm.Id].Quota_Fee__c, '480억 = 48,000,000,000원');
        Assert.isTrue(result.message.contains('480억'), result.message);
    }

    @IsTest
    static void updateQuotaKeepsDecimals() {
        // Quota_Fee__c 는 수수료 목표라 2.5억 같은 값이 정상이다. 반올림하면 화면과 어긋난다.
        User rm = rm();

        Test.startTest();
        TeamCoachingController.QuotaResult result = TeamCoachingController.updateQuota(rm.Id, 2.5);
        Test.stopTest();

        Assert.areEqual(250000000L, [SELECT Quota_Fee__c FROM User WHERE Id = :rm.Id].Quota_Fee__c, '2.5억 = 250,000,000원');
        Assert.areEqual(2.5, result.quotaEok, '소수가 살아 있어야 한다');
        Assert.isTrue(result.message.contains('2.5억'), result.message);
    }

    @IsTest
    static void updateQuotaRejectsBadInput() {
        User rm = rm();

        Test.startTest();
        try {
            TeamCoachingController.updateQuota(rm.Id, -1);
            Assert.fail('음수 목표는 거부해야 한다');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e);
        }
        try {
            TeamCoachingController.updateQuota('', 100);
            Assert.fail('RM 없이 저장되면 안 된다');
        } catch (AuraHandledException e) {
            Assert.isNotNull(e);
        }
        Test.stopTest();
    }

    @IsTest
    static void getQuotaEokConvertsBackToEok() {
        User rm = rm();

        Test.startTest();
        Decimal eok = TeamCoachingController.getQuotaEok(rm.Id);
        Decimal none = TeamCoachingController.getQuotaEok('');
        Test.stopTest();

        Assert.areEqual(250.00, eok, '250억이 저장돼 있다');
        Assert.isNull(none, 'RM 이 없으면 null');
    }

    /**
     * User 는 테스트에서도 org 의 실제 레코드가 보인다 — @TestSetup 의 `정 예은` 은 org 에 같은 이름의
     * RM 이 실제로 있어 2명이 걸린다(그래서 resolveRmId 가 null 을 돌려준다. 안전장치가 동작한 것).
     * 이름 조회 테스트는 org 에 있을 리 없는 이름을 새로 만들어 쓴다.
     */
    private static User insertUniqueRm(String firstName, String lastName) {
        Profile standard = [SELECT Id FROM Profile WHERE UserType = 'Standard' LIMIT 1];
        String stamp = String.valueOf(DateTime.now().getTime());
        User rm = new User(
            FirstName = firstName,
            LastName = lastName,
            Alias = 'rslv',
            Email = 'coaching.resolve.' + stamp + '@example.com',
            Username = 'coaching.resolve.' + stamp + Math.abs(Crypto.getRandomInteger()) + '@example.com.invalid',
            ProfileId = standard.Id,
            TimeZoneSidKey = 'Asia/Seoul',
            LocaleSidKey = 'ko_KR',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'ko'
        );
        insert rm;
        return [SELECT Id, Name FROM User WHERE Id = :rm.Id];
    }

    @IsTest
    static void resolveRmIdFindsExactlyOneUser() {
        User rm = insertUniqueRm('테스트원', '코칭조회');

        Test.startTest();
        String found = TeamCoachingController.resolveRmId(rm.Name);
        Test.stopTest();

        Assert.areEqual(String.valueOf(rm.Id), found, '이름이 하나만 걸리면 그 사용자를 쓴다');
    }

    @IsTest
    static void resolveRmIdTrimsWhitespace() {
        User rm = insertUniqueRm('테스트투', '코칭조회');

        Test.startTest();
        String found = TeamCoachingController.resolveRmId('  ' + rm.Name + '  ');
        Test.stopTest();

        Assert.areEqual(String.valueOf(rm.Id), found, '앞뒤 공백은 무시한다');
    }

    @IsTest
    static void resolveRmIdReturnsNullWhenNoMatch() {
        Test.startTest();
        String found = TeamCoachingController.resolveRmId('없는 사람');
        Test.stopTest();

        Assert.isNull(found, '못 찾으면 추측하지 않는다');
    }

    @IsTest
    static void resolveRmIdReturnsNullForBlankName() {
        Test.startTest();
        String found = TeamCoachingController.resolveRmId('   ');
        Test.stopTest();

        Assert.isNull(found, '이름이 비면 조회하지 않는다');
    }

    @IsTest
    static void resolveRmIdRefusesAmbiguousName() {
        // 동명이인이면 조치를 보내지 않는다 — 스펙 4·9장이 금지한 추측 매칭이 되기 때문이다.
        User first = insertUniqueRm('테스트쓰리', '코칭조회');
        insertUniqueRm('테스트쓰리', '코칭조회');

        Test.startTest();
        String found = TeamCoachingController.resolveRmId(first.Name);
        Test.stopTest();

        Assert.isNull(found, '동명이인이면 누구에게 보낼지 알 수 없으므로 차단한다');
    }

    @IsTest
    static void refreshDashboardDelegatesToTableau() {
        Test.setMock(HttpCalloutMock.class, new TableauMock());

        Test.startTest();
        TableauRefreshService.RefreshResult result = TeamCoachingController.refreshDashboard();
        Test.stopTest();

        Assert.isTrue(result.success);
        Assert.areEqual('j-1', result.jobId);
    }
}