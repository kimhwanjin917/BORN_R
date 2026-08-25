/**
 * SlackLeadChannelService 테스트.
 * Slack 호출은 전부 HttpCalloutMock 으로 대체한다 (실제 Slack 호출 없음).
 * 테스트 데이터는 이 클래스의 @TestSetup 에서 직접 만든다 (팀 공용 TestDataFactory 는 동결 파일이라 사용하지 않음).
 */
@IsTest
private class SlackLeadChannelServiceTest {

    private static final String LEAD_LAST_NAME = '테스트고객';
    private static final String LEAD_COMPANY = 'Acme Korea Co.';
    private static final String LEAD_EMAIL = 'customer@example.com';
    private static final String EXISTING_CHANNEL_ID = 'C0EXISTING1';
    private static final String EXISTING_CHANNEL_LINK = 'https://slack-demo-39110.enterprise.slack.com/archives/C0EXISTING1';
    private static final String NEW_CHANNEL_ID = 'C0NEWCHAN1';
    private static final String NEW_CHANNEL_NAME = 'lead-acme-korea-co-abcde';

    private static final String TEST_USER_USERNAME = 'slack.lead.channel.test@newborn.example.com';
    private static final String PERMISSION_SET_NAME = 'Slack_Lead_Channel';
    private static final String TEST_PROFILE_NAME = 'Standard User';

    /**
     * 실제 영업 사용자와 같은 조건(Standard User + Slack_Lead_Channel 권한 집합)의 테스트 유저를 만들고,
     * 그 유저로 Lead 를 만든다. (User/PermissionSetAssignment 는 설정 객체라 Lead 와 같은 트랜잭션에서
     * 섞어 쓰면 MIXED_DML 이 나므로 각각 runAs 블록으로 분리한다.)
     */
    @TestSetup
    static void setupTestData() {
        User testUser;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            testUser = buildTestUser();
            insert testUser;
            PermissionSet permissionSet = [SELECT Id FROM PermissionSet WHERE Name = :PERMISSION_SET_NAME LIMIT 1];
            insert new PermissionSetAssignment(AssigneeId = testUser.Id, PermissionSetId = permissionSet.Id);
        }
        System.runAs(testUser) {
            List<Lead> leads = new List<Lead>{
                new Lead(LastName = LEAD_LAST_NAME, name_new__c = LEAD_LAST_NAME, Company = LEAD_COMPANY, Email = LEAD_EMAIL),
                new Lead(LastName = '기존채널고객', name_new__c = '기존채널고객', Company = 'Existing Inc', Email = 'existing@example.com',
                         Slack_Channel_ID__c = EXISTING_CHANNEL_ID, Slack_Channel_Link__c = EXISTING_CHANNEL_LINK)
            };
            insert leads;
        }
    }

    private static User buildTestUser() {
        Profile standardProfile = [SELECT Id FROM Profile WHERE Name = :TEST_PROFILE_NAME LIMIT 1];
        return new User(
            FirstName = 'Slack',
            LastName = 'Tester',
            Alias = 'slacktst',
            Email = 'slack.tester@example.com',
            Username = TEST_USER_USERNAME,
            ProfileId = standardProfile.Id,
            TimeZoneSidKey = 'Asia/Seoul',
            LocaleSidKey = 'ko_KR',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'ko'
        );
    }

    private static User getTestUser() {
        return [SELECT Id, Email FROM User WHERE Username = :TEST_USER_USERNAME LIMIT 1];
    }

    // ─── Happy path ──────────────────────────────────────────────────────

    @IsTest
    static void shouldCreateChannelInviteAndPost_WhenLeadHasNoChannel() {
        // Given
        Lead lead = getLeadByCompany(LEAD_COMPANY);
        SlackApiMock mock = new SlackApiMock();
        Test.setMock(HttpCalloutMock.class, mock);
        SlackLeadChannelService.Request request = buildRequest(lead.Id);

        // When
        List<SlackLeadChannelService.Response> responses =
            callService(new List<SlackLeadChannelService.Request>{ request });

        // Then
        Assert.areEqual(1, responses.size(), '요청 1건당 응답 1건');
        SlackLeadChannelService.Response response = responses[0];
        Assert.isTrue(response.isSuccess, '성공해야 함: ' + response.errorMessage);
        Assert.isFalse(response.alreadyExisted, '새로 만든 채널이어야 함');
        Assert.areEqual(NEW_CHANNEL_ID, response.channelId, '채널 ID는 Slack 응답값');
        Assert.areEqual(NEW_CHANNEL_NAME, response.channelName, '채널 이름은 Slack 응답값');
        Assert.areEqual('https://slack-demo-39110.enterprise.slack.com/archives/' + NEW_CHANNEL_ID, response.deepLink,
            '딥링크 = Slack__mdt Org_Url + /archives/ + 채널ID');
        Assert.isTrue(response.invitedEmails.contains(LEAD_EMAIL), '고객 이메일은 초대 목록에 있어야 함');
        Assert.isTrue(mock.calledPaths.contains('/conversations.create'), '채널 생성 호출');
        Assert.isTrue(mock.calledPaths.contains('/conversations.invite'), '초대 호출');
        Assert.isTrue(mock.calledPaths.contains('/chat.postMessage'), '환영 메시지 호출');
        Assert.isTrue(mock.lastCreateBody.contains('"is_private":true'), '기본은 비공개 채널');
        Assert.isTrue(mock.lastCreateBody.contains('"name":"acme-korea-co-테스트고객"'), '채널 이름은 {회사명}-{성이름} 규칙');
    }

    @IsTest
    static void shouldUseCustomNameAndMessage_WhenProvided() {
        // Given
        Lead lead = getLeadByCompany(LEAD_COMPANY);
        SlackApiMock mock = new SlackApiMock();
        Test.setMock(HttpCalloutMock.class, mock);
        SlackLeadChannelService.Request request = buildRequest(lead.Id);
        request.channelName = 'VIP 고객.채널!!';
        request.welcomeMessage = '커스텀 환영 문구';
        request.isPrivate = false;

        // When
        SlackLeadChannelService.Response response = callService(request);

        // Then
        Assert.isTrue(response.isSuccess, '성공해야 함: ' + response.errorMessage);
        Assert.isTrue(mock.lastCreateBody.contains('"name":"vip-고객-채널"'), '공백/마침표는 -, 구두점은 제거, 소문자화');
        Assert.isTrue(mock.lastCreateBody.contains('"is_private":false'), 'isPrivate=false 반영');
        Assert.isTrue(mock.lastPostMessageBody.contains('커스텀 환영 문구'), '커스텀 메시지 사용');
    }

    @IsTest
    static void shouldSkipCustomer_WhenEmailNotInWorkspace() {
        // Given
        Lead lead = getLeadByCompany(LEAD_COMPANY);
        SlackApiMock mock = new SlackApiMock();
        mock.notFoundEmails.add(LEAD_EMAIL);
        Test.setMock(HttpCalloutMock.class, mock);

        // When
        SlackLeadChannelService.Response response = callService(buildRequest(lead.Id));

        // Then
        Assert.isTrue(response.isSuccess, '고객이 워크스페이스에 없어도 전체는 성공');
        Assert.areEqual(LEAD_EMAIL, response.skippedEmails, '고객 이메일은 건너뛴 목록에');
        Assert.isFalse(response.invitedEmails.contains(LEAD_EMAIL), '초대 목록에는 없어야 함');
    }

    @IsTest
    static void shouldNotInviteLeadEmail_WhenInviteLeadEmailFalse() {
        // Given
        Lead lead = getLeadByCompany(LEAD_COMPANY);
        SlackApiMock mock = new SlackApiMock();
        Test.setMock(HttpCalloutMock.class, mock);
        SlackLeadChannelService.Request request = buildRequest(lead.Id);
        request.inviteLeadEmail = false;

        // When
        SlackLeadChannelService.Response response = callService(request);

        // Then
        Assert.isTrue(response.isSuccess, '성공해야 함');
        Assert.isFalse(mock.lookedUpEmails.contains(LEAD_EMAIL), 'Lead 이메일은 조회조차 하지 않아야 함');
    }

    // ─── Idempotency ─────────────────────────────────────────────────────

    @IsTest
    static void shouldReturnExistingChannel_WhenLeadAlreadyHasChannelId() {
        // Given
        Lead lead = getLeadByCompany('Existing Inc');
        SlackApiMock mock = new SlackApiMock();
        Test.setMock(HttpCalloutMock.class, mock);

        // When
        SlackLeadChannelService.Response response = callService(buildRequest(lead.Id));

        // Then
        Assert.isTrue(response.isSuccess, '성공');
        Assert.isTrue(response.alreadyExisted, '기존 채널 재사용 플래그');
        Assert.areEqual(EXISTING_CHANNEL_ID, response.channelId, '기존 채널 ID 반환');
        Assert.areEqual(EXISTING_CHANNEL_LINK, response.deepLink, '기존 링크 반환');
        Assert.areEqual(0, mock.calledPaths.size(), 'Slack 호출이 전혀 없어야 함');
    }

    // ─── Error paths ─────────────────────────────────────────────────────

    @IsTest
    static void shouldRetryWithSuffix_WhenChannelNameTaken() {
        // Given
        Lead lead = getLeadByCompany(LEAD_COMPANY);
        SlackApiMock mock = new SlackApiMock();
        mock.failFirstCreateWith = 'name_taken';
        Test.setMock(HttpCalloutMock.class, mock);

        // When
        SlackLeadChannelService.Response response = callService(buildRequest(lead.Id));

        // Then
        Assert.isTrue(response.isSuccess, 'name_taken 이면 -2 붙여 재시도 후 성공');
        Assert.areEqual(2, mock.createCallCount, '채널 생성은 2번 호출');
        Assert.isTrue(mock.lastCreateBody.contains('"name":"acme-korea-co-테스트고객-2"'), '재시도 이름은 원래이름-2');
    }

    @IsTest
    static void shouldFailWithScopeHint_WhenMissingScope() {
        // Given
        Lead lead = getLeadByCompany(LEAD_COMPANY);
        SlackApiMock mock = new SlackApiMock();
        mock.failFirstCreateWith = 'missing_scope';
        mock.failSecondCreateToo = true;
        Test.setMock(HttpCalloutMock.class, mock);

        // When
        SlackLeadChannelService.Response response = callService(buildRequest(lead.Id));

        // Then
        Assert.isFalse(response.isSuccess, 'missing_scope 는 실패');
        Assert.areEqual('missing_scope', response.errorType, 'Slack error 코드 보존');
        Assert.isTrue(response.errorMessage.contains('groups:write'), '부족한 scope 이름이 메시지에 포함');
        Assert.isNull(response.channelId, '채널 ID 없음');
    }

    @IsTest
    static void shouldFail_WhenPostMessageFails() {
        // Given
        Lead lead = getLeadByCompany(LEAD_COMPANY);
        SlackApiMock mock = new SlackApiMock();
        mock.failPostMessageWith = 'channel_not_found';
        Test.setMock(HttpCalloutMock.class, mock);

        // When
        SlackLeadChannelService.Response response = callService(buildRequest(lead.Id));

        // Then
        Assert.isFalse(response.isSuccess, '메시지 게시 실패는 실패로 보고');
        Assert.areEqual('channel_not_found', response.errorType, 'Slack error 코드 보존');
        Assert.areEqual(NEW_CHANNEL_ID, response.channelId, '채널은 이미 만들어졌으므로 ID는 돌려줌');
    }

    @IsTest
    static void shouldFail_WhenHttpStatusNot2xx() {
        // Given
        Lead lead = getLeadByCompany(LEAD_COMPANY);
        SlackApiMock mock = new SlackApiMock();
        mock.httpStatusOverride = 500;
        Test.setMock(HttpCalloutMock.class, mock);

        // When
        SlackLeadChannelService.Response response = callService(buildRequest(lead.Id));

        // Then
        Assert.isFalse(response.isSuccess, 'HTTP 500 은 실패');
        Assert.areEqual('HTTP_500', response.errorType, 'HTTP 상태코드 기반 오류 유형');
    }

    @IsTest
    static void shouldReturnNotFound_WhenLeadIdDoesNotExist() {
        // Given: 만들었다가 지운 Lead 의 Id → 형식은 유효하지만 존재하지 않음
        Id deletedLeadId;
        System.runAs(getTestUser()) {
            Lead deletedLead = new Lead(LastName = '삭제될고객', name_new__c = '삭제될고객', Company = 'Deleted Co', Email = 'deleted@example.com');
            insert deletedLead;
            deletedLeadId = deletedLead.Id;
            delete deletedLead;
        }
        Test.setMock(HttpCalloutMock.class, new SlackApiMock());

        // When
        SlackLeadChannelService.Response response = callService(buildRequest(deletedLeadId));

        // Then
        Assert.isFalse(response.isSuccess, '없는 Lead 는 실패');
        Assert.areEqual('NOT_FOUND', response.errorType, 'NOT_FOUND 유형');
    }

    @IsTest
    static void shouldReturnValidationError_WhenLeadIdNull() {
        // Given
        SlackLeadChannelService.Request request = new SlackLeadChannelService.Request();
        Test.setMock(HttpCalloutMock.class, new SlackApiMock());

        // When
        SlackLeadChannelService.Response response = callService(request);

        // Then
        Assert.isFalse(response.isSuccess, 'leadId null 은 실패');
        Assert.areEqual('VALIDATION', response.errorType, 'VALIDATION 유형');
    }

    @IsTest
    static void shouldReturnEmpty_WhenRequestsNull() {
        // When
        List<SlackLeadChannelService.Response> responses = callService((List<SlackLeadChannelService.Request>) null);

        // Then
        Assert.areEqual(0, responses.size(), 'null 입력이면 빈 목록');
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    private static Lead getLeadByCompany(String company) {
        return [SELECT Id, Email, Company FROM Lead WHERE Company = :company LIMIT 1];
    }

    /** 테스트 유저(Standard User + Slack_Lead_Channel)로 서비스를 실행한다. */
    private static SlackLeadChannelService.Response callService(SlackLeadChannelService.Request request) {
        return callService(new List<SlackLeadChannelService.Request>{ request })[0];
    }

    private static List<SlackLeadChannelService.Response> callService(List<SlackLeadChannelService.Request> requests) {
        List<SlackLeadChannelService.Response> responses;
        System.runAs(getTestUser()) {
            Test.startTest();
            responses = SlackLeadChannelService.createChannelForLeads(requests);
            Test.stopTest();
        }
        return responses;
    }

    private static SlackLeadChannelService.Request buildRequest(Id leadId) {
        SlackLeadChannelService.Request request = new SlackLeadChannelService.Request();
        request.leadId = leadId;
        return request;
    }

    /**
     * Slack Web API 흉내. 경로별로 성공 JSON 을 돌려주고, 필드로 실패 시나리오를 제어한다.
     */
    private class SlackApiMock implements HttpCalloutMock {
        public List<String> calledPaths = new List<String>();
        public List<String> lookedUpEmails = new List<String>();
        public Set<String> notFoundEmails = new Set<String>();
        public String lastCreateBody;
        public String lastPostMessageBody;
        public Integer createCallCount = 0;
        public String failFirstCreateWith;
        public Boolean failSecondCreateToo = false;
        public String failPostMessageWith;
        public Integer httpStatusOverride;

        public HttpResponse respond(HttpRequest request) {
            String endpoint = request.getEndpoint();
            String path = endpoint.substringAfter('callout:Slack').substringBefore('?');
            calledPaths.add(path);

            HttpResponse response = new HttpResponse();
            response.setHeader('Content-Type', 'application/json');
            response.setStatusCode(httpStatusOverride ?? 200);
            if (httpStatusOverride != null) {
                response.setStatus('Server Error');
                response.setBody('{"ok":false,"error":"internal_error"}');
                return response;
            }

            if (path == '/conversations.create') {
                response.setBody(bodyForCreate(request));
            } else if (path == '/users.lookupByEmail') {
                response.setBody(bodyForLookup(endpoint));
            } else if (path == '/conversations.invite') {
                response.setBody('{"ok":true,"channel":{"id":"' + NEW_CHANNEL_ID + '"}}');
            } else if (path == '/chat.postMessage') {
                response.setBody(bodyForPostMessage(request));
            } else {
                response.setBody('{"ok":false,"error":"unknown_method"}');
            }
            return response;
        }

        private String bodyForCreate(HttpRequest request) {
            createCallCount++;
            lastCreateBody = request.getBody();
            Boolean shouldFail = (createCallCount == 1 && failFirstCreateWith != null)
                || (createCallCount == 2 && failSecondCreateToo);
            return shouldFail
                ? '{"ok":false,"error":"' + failFirstCreateWith + '","needed":"groups:write"}'
                : '{"ok":true,"channel":{"id":"' + NEW_CHANNEL_ID + '","name":"' + NEW_CHANNEL_NAME + '"}}';
        }

        private String bodyForLookup(String endpoint) {
            String email = EncodingUtil.urlDecode(endpoint.substringAfter('email='), 'UTF-8');
            lookedUpEmails.add(email);
            return notFoundEmails.contains(email)
                ? '{"ok":false,"error":"users_not_found"}'
                : '{"ok":true,"user":{"id":"U' + String.valueOf(Math.abs(email.hashCode())) + '"}}';
        }

        private String bodyForPostMessage(HttpRequest request) {
            lastPostMessageBody = request.getBody();
            return failPostMessageWith != null
                ? '{"ok":false,"error":"' + failPostMessageWith + '"}'
                : '{"ok":true,"ts":"1700000000.000100"}';
        }
    }
}