/**
 * SlackChannelMessageService 테스트. Slack 은 HttpCalloutMock 으로 흉내 낸다 (실제 콜아웃 없음).
 * TestDataFactory 는 사용하지 않는다 (레코드 불필요).
 */
@IsTest
private class SlackChannelMessageServiceTest {

    private class SlackMock implements HttpCalloutMock {
        private Integer statusCode;
        private String body;
        public HttpRequest lastRequest;
        public Integer callCount = 0;

        SlackMock(Integer statusCode, String body) {
            this.statusCode = statusCode;
            this.body = body;
        }
        public HttpResponse respond(HttpRequest request) {
            callCount++;
            lastRequest = request;
            HttpResponse response = new HttpResponse();
            response.setStatusCode(statusCode);
            response.setStatus(statusCode == 200 ? 'OK' : 'ERR');
            response.setBody(body);
            return response;
        }
    }

    private static SlackChannelMessageService.Request makeRequest(String channelId, String text) {
        SlackChannelMessageService.Request request = new SlackChannelMessageService.Request();
        request.channelId = channelId;
        request.text = text;
        return request;
    }

    @IsTest
    static void success_postsToChannelAndReturnsTs() {
        SlackMock mock = new SlackMock(200, '{"ok":true,"channel":"C0BRTMCTUN5","ts":"1700000000.000100"}');
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        List<SlackChannelMessageService.Response> responses = SlackChannelMessageService.postMessages(
            new List<SlackChannelMessageService.Request>{ makeRequest(' C0BRTMCTUN5 ', '미팅 요약 테스트') }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size());
        SlackChannelMessageService.Response response = responses[0];
        Assert.isTrue(response.isSuccess, 'isSuccess');
        Assert.areEqual('C0BRTMCTUN5', response.channelId, 'trim 된 채널 ID');
        Assert.areEqual('1700000000.000100', response.messageTs);
        Assert.isNull(response.errorMessage);
        Assert.areEqual(1, mock.callCount);
        Assert.isTrue(mock.lastRequest.getEndpoint().endsWith('/chat.postMessage'));
        Map<String, Object> sent = (Map<String, Object>) JSON.deserializeUntyped(mock.lastRequest.getBody());
        Assert.areEqual('C0BRTMCTUN5', sent.get('channel'));
        Assert.areEqual('미팅 요약 테스트', sent.get('text'));
    }

    @IsTest
    static void notInChannel_returnsInviteGuidance() {
        Test.setMock(HttpCalloutMock.class, new SlackMock(200, '{"ok":false,"error":"not_in_channel"}'));

        Test.startTest();
        SlackChannelMessageService.Response response = SlackChannelMessageService.postMessages(
            new List<SlackChannelMessageService.Request>{ makeRequest('C0BRTMCTUN5', 'hi') }
        )[0];
        Test.stopTest();

        Assert.isFalse(response.isSuccess);
        Assert.areEqual('not_in_channel', response.errorType);
        Assert.isTrue(response.errorMessage.contains('초대'), '초대 안내 포함: ' + response.errorMessage);
    }

    @IsTest
    static void missingScope_describesNeededScope() {
        Test.setMock(HttpCalloutMock.class,
            new SlackMock(200, '{"ok":false,"error":"missing_scope","needed":"chat:write","provided":"channels:read"}'));

        SlackChannelMessageService.Response response = SlackChannelMessageService.postMessages(
            new List<SlackChannelMessageService.Request>{ makeRequest('C1', 'hi') }
        )[0];

        Assert.isFalse(response.isSuccess);
        Assert.areEqual('missing_scope', response.errorType);
        Assert.isTrue(response.errorMessage.contains('chat:write'));
    }

    @IsTest
    static void channelNotFoundAndArchived_areDescribed() {
        Assert.isTrue(SlackChannelMessageService.describeSlackError(
            new Map<String, Object>{ 'error' => 'channel_not_found' }).contains('channel_not_found'));
        Assert.isTrue(SlackChannelMessageService.describeSlackError(
            new Map<String, Object>{ 'error' => 'is_archived' }).contains('아카이브'));
        Assert.areEqual('ratelimited', SlackChannelMessageService.describeSlackError(
            new Map<String, Object>{ 'error' => 'ratelimited' }));
    }

    @IsTest
    static void httpError_returnsHttpErrorType() {
        Test.setMock(HttpCalloutMock.class, new SlackMock(503, 'Service Unavailable'));

        SlackChannelMessageService.Response response = SlackChannelMessageService.postMessages(
            new List<SlackChannelMessageService.Request>{ makeRequest('C1', 'hi') }
        )[0];

        Assert.isFalse(response.isSuccess);
        Assert.areEqual('HTTP_503', response.errorType);
        Assert.isTrue(response.errorMessage.contains('503'));
    }

    @IsTest
    static void invalidJson_returnsInvalidResponse() {
        Test.setMock(HttpCalloutMock.class, new SlackMock(200, '[1,2,3]'));

        SlackChannelMessageService.Response response = SlackChannelMessageService.postMessages(
            new List<SlackChannelMessageService.Request>{ makeRequest('C1', 'hi') }
        )[0];

        Assert.isFalse(response.isSuccess);
        Assert.areEqual('INVALID_RESPONSE', response.errorType);
    }

    @IsTest
    static void validation_blankChannelOrText_failsWithoutCallout() {
        SlackMock mock = new SlackMock(200, '{"ok":true}');
        Test.setMock(HttpCalloutMock.class, mock);

        List<SlackChannelMessageService.Response> responses = SlackChannelMessageService.postMessages(
            new List<SlackChannelMessageService.Request>{ makeRequest('  ', 'hi'), makeRequest('C1', ' '), null }
        );

        Assert.areEqual(3, responses.size(), '요청 수 = 응답 수 (null 포함)');
        for (SlackChannelMessageService.Response response : responses) {
            Assert.isFalse(response.isSuccess);
            Assert.areEqual('VALIDATION', response.errorType);
        }
        Assert.areEqual(0, mock.callCount, '검증 실패는 콜아웃 없음');
    }

    @IsTest
    static void emptyOrNullRequests_returnEmptyList() {
        Assert.areEqual(0, SlackChannelMessageService.postMessages(null).size());
        Assert.areEqual(0, SlackChannelMessageService.postMessages(new List<SlackChannelMessageService.Request>()).size());
    }

    @IsTest
    static void longText_isTruncatedBeforeSending() {
        SlackMock mock = new SlackMock(200, '{"ok":true,"ts":"1.2"}');
        Test.setMock(HttpCalloutMock.class, mock);
        String longText = 'a'.repeat(SlackChannelMessageService.MAX_TEXT_LENGTH + 500);

        SlackChannelMessageService.Response response = SlackChannelMessageService.postMessages(
            new List<SlackChannelMessageService.Request>{ makeRequest('C1', longText) }
        )[0];

        Assert.isTrue(response.isSuccess);
        Map<String, Object> sent = (Map<String, Object>) JSON.deserializeUntyped(mock.lastRequest.getBody());
        String sentText = (String) sent.get('text');
        Assert.areEqual(SlackChannelMessageService.MAX_TEXT_LENGTH, sentText.length());
        Assert.isTrue(sentText.endsWith(SlackChannelMessageService.TRUNCATED_SUFFIX));
    }

    @IsTest
    static void bulk_returnsOneResponsePerRequestInOrder() {
        Test.setMock(HttpCalloutMock.class, new SlackMock(200, '{"ok":true,"ts":"9.9"}'));

        List<SlackChannelMessageService.Response> responses = SlackChannelMessageService.postMessages(
            new List<SlackChannelMessageService.Request>{ makeRequest('C1', 'one'), makeRequest('C2', 'two') }
        );

        Assert.areEqual(2, responses.size());
        Assert.areEqual('C1', responses[0].channelId);
        Assert.areEqual('C2', responses[1].channelId);
        Assert.isTrue(responses[0].isSuccess && responses[1].isSuccess);
    }
}