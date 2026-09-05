@IsTest
private class TeamCoachingServiceTest {

    private static final String RM_EMAIL = 'coaching.rm.test@example.com';

    @TestSetup
    static void setup() {
        // 팀 공용 TestDataFactory 는 건드리지 않는다(AGENTS.md 3항). 이 클래스 안에서만 만든다.
        Profile standard = [SELECT Id FROM Profile WHERE UserType = 'Standard' LIMIT 1];
        User rm = new User(
            FirstName = '하은',
            LastName = '강',
            Alias = 'khe',
            Email = RM_EMAIL,
            Username = 'coaching.rm.' + DateTime.now().getTime() + '@example.com.invalid',
            ProfileId = standard.Id,
            TimeZoneSidKey = 'Asia/Seoul',
            LocaleSidKey = 'ko_KR',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'ko'
        );
        insert rm;
    }

    private static User rm() {
        return [SELECT Id, Name, Email FROM User WHERE Email = :RM_EMAIL LIMIT 1];
    }

    /** Slack Web API 흉내. 경로별 응답과 실패 지점을 지정할 수 있다. */
    private class SlackMock implements HttpCalloutMock {
        public List<String> paths = new List<String>();
        public Boolean channelExists = true;
        public String failingPath;
        public String failureCode = 'invalid_auth';

        public HttpResponse respond(HttpRequest req) {
            // 엔드포인트는 "callout:Slack/chat.postMessage?..." 형태다. 이름 뒤부터가 경로다.
            String path = req.getEndpoint().substringAfter('callout:Slack').substringBefore('?');
            paths.add(path);

            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);

            if (path == failingPath) {
                res.setBody('{"ok":false,"error":"' + failureCode + '"}');
                return res;
            }
            if (path == '/conversations.list') {
                String channels = channelExists
                    ? '{"id":"C-EXIST","name":"rm-강하은과의-채널"}'
                    : '{"id":"C-OTHER","name":"rm-다른사람과의-채널"}';
                res.setBody('{"ok":true,"channels":[' + channels + '],"response_metadata":{"next_cursor":""}}');
            } else if (path == '/conversations.create') {
                res.setBody('{"ok":true,"channel":{"id":"C-NEW","name":"rm-강하은과의-채널"}}');
            } else if (path == '/users.lookupByEmail') {
                res.setBody('{"ok":true,"user":{"id":"U-1"}}');
            } else if (path == '/conversations.invite') {
                res.setBody('{"ok":true}');
            } else if (path == '/chat.postMessage') {
                res.setBody('{"ok":true,"ts":"1700000000.000100"}');
            } else {
                res.setBody('{"ok":true}');
            }
            return res;
        }
    }

    private static TeamCoachingService.CoachingRequest request(User rm) {
        TeamCoachingService.CoachingRequest req = new TeamCoachingService.CoachingRequest();
        req.rmUserId = rm.Id;
        req.rmName = rm.Name;
        req.stageLabel = '미팅';
        req.message = '강 하은 님, 미팅 단계 평균 체류가 32일로 팀 평균(22일)보다 깁니다.';
        return req;
    }

    @IsTest
    static void reusesExistingChannelAndCreatesTask() {
        User rm = rm();
        SlackMock mock = new SlackMock();
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        TeamCoachingService.CoachingResult result = TeamCoachingService.sendCoaching(request(rm));
        Test.stopTest();

        Assert.isTrue(result.slackSent, 'Slack 발송이 성공해야 한다');
        Assert.areEqual('rm-강하은과의-채널', result.channelName, '채널명은 RM 이름으로 정해진다');
        Assert.isFalse(mock.paths.contains('/conversations.create'), '이미 있는 채널이면 새로 만들지 않는다');
        Assert.isTrue(mock.paths.contains('/chat.postMessage'), '메시지를 보내야 한다');

        Task t = [SELECT OwnerId, Subject, ActivityDate, Description FROM Task WHERE Id = :result.taskId];
        Assert.areEqual(rm.Id, t.OwnerId, 'Task 소유자는 RM 이다');
        Assert.areEqual('미팅 단계 체류 점검', t.Subject);
        Assert.areEqual(Date.today().addDays(3), t.ActivityDate, '마감은 3일 뒤');
        Assert.isTrue(t.Description.contains('32일'), '발송한 메시지 전문이 남아야 한다');
    }

    @IsTest
    static void createsChannelWhenMissing() {
        User rm = rm();
        SlackMock mock = new SlackMock();
        mock.channelExists = false;
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        TeamCoachingService.CoachingResult result = TeamCoachingService.sendCoaching(request(rm));
        Test.stopTest();

        Assert.isTrue(result.slackSent, '새 채널을 만들고 발송까지 성공해야 한다');
        Assert.isTrue(mock.paths.contains('/conversations.create'), '없으면 비공개 채널을 만든다');
    }

    @IsTest
    static void slackFailureStillLeavesTask() {
        // 스펙 9장: 부분 성공을 사실대로 표시한다. Slack 이 죽어도 기록은 남아야 한다.
        User rm = rm();
        SlackMock mock = new SlackMock();
        mock.failingPath = '/chat.postMessage';
        mock.failureCode = 'channel_not_found';
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        TeamCoachingService.CoachingResult result = TeamCoachingService.sendCoaching(request(rm));
        Test.stopTest();

        Assert.isFalse(result.slackSent, 'Slack 실패는 실패로 표시한다');
        Assert.isNotNull(result.taskId, 'Slack 이 실패해도 Task 는 남는다');
        Assert.isTrue(result.summary.contains('Slack 전달만 실패'), '부분 성공임을 알려야 한다');
    }

    @IsTest
    static void benignInviteErrorDoesNotFailSend() {
        User rm = rm();
        SlackMock mock = new SlackMock();
        mock.failingPath = '/conversations.invite';
        mock.failureCode = 'already_in_channel';
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        TeamCoachingService.CoachingResult result = TeamCoachingService.sendCoaching(request(rm));
        Test.stopTest();

        Assert.isTrue(result.slackSent, '이미 채널에 있는 것은 실패가 아니다');
    }

    @IsTest
    static void missingRmUserIdIsRejected() {
        // 이름 문자열로 추측 매칭하지 않는다 — User Id 가 없으면 조치 자체를 막는다(스펙 9장).
        TeamCoachingService.CoachingRequest req = new TeamCoachingService.CoachingRequest();
        req.rmName = '강 하은';
        req.message = '메시지';

        Test.startTest();
        try {
            TeamCoachingService.sendCoaching(req);
            Assert.fail('User Id 없이는 발송되면 안 된다');
        } catch (TeamCoachingService.TeamCoachingException e) {
            Assert.isTrue(e.getMessage().contains('RM 을 특정할 수 없습니다'), e.getMessage());
        }
        Test.stopTest();
    }

    @IsTest
    static void blankMessageIsRejected() {
        User rm = rm();
        TeamCoachingService.CoachingRequest req = request(rm);
        req.message = '   ';

        Test.startTest();
        try {
            TeamCoachingService.sendCoaching(req);
            Assert.fail('빈 메시지는 발송되면 안 된다');
        } catch (TeamCoachingService.TeamCoachingException e) {
            Assert.isTrue(e.getMessage().contains('비어 있습니다'), e.getMessage());
        }
        Test.stopTest();
    }

    @IsTest
    static void taskSubjectFallsBackWhenStageMissing() {
        // 팀원 KPI 에서 온 코칭은 단계 문맥이 없다.
        User rm = rm();
        Test.setMock(HttpCalloutMock.class, new SlackMock());
        TeamCoachingService.CoachingRequest req = request(rm);
        req.stageLabel = null;

        Test.startTest();
        TeamCoachingService.CoachingResult result = TeamCoachingService.sendCoaching(req);
        Test.stopTest();

        Assert.areEqual('팀장 코칭 확인', [SELECT Subject FROM Task WHERE Id = :result.taskId].Subject);
    }

    @IsTest
    static void channelNameFollowsSlackRules() {
        // Slack 은 대문자·공백을 허용하지 않는다. 한글은 그대로 쓸 수 있다.
        Assert.areEqual('rm-강하은과의-채널', TeamCoachingService.buildChannelName('강 하은'));
        Assert.areEqual('rm-과의-채널', TeamCoachingService.normalizeChannelName('RM  과의   채널'));
        Assert.areEqual('a-b', TeamCoachingService.normalizeChannelName('  A.B  '));
    }
}