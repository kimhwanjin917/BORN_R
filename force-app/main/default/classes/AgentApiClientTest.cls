@IsTest
public class AgentApiClientTest {

    /** Agent API 3단계(세션 생성·메시지·종료)를 흉내 내는 목 */
    public class AgentApiMock implements HttpCalloutMock {
        public Integer messageStatus = 200;
        public String messageBody = '{"messages":[{"type":"Inform","message":"추천 1순위 RP","planId":"p1"},{"type":"Inform","message":"근거: 현금성자산"}]}';
        public List<String> calls = new List<String>();

        public HttpResponse respond(HttpRequest req) {
            calls.add(req.getMethod() + ' ' + req.getEndpoint());
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            if (req.getEndpoint().endsWith('/sessions') && req.getMethod() == 'POST') {
                res.setStatusCode(200);
                res.setBody('{"sessionId":"sess-1","messages":[{"type":"Inform","message":"안녕하세요"}]}');
            } else if (req.getEndpoint().contains('/messages')) {
                res.setStatusCode(messageStatus);
                res.setBody(messageBody);
            } else {
                res.setStatusCode(204);
                res.setBody('');
            }
            return res;
        }
    }

    @IsTest
    static void shouldOpenSendAndCloseSession() {
        AgentApiMock mock = new AgentApiMock();
        Test.setMock(HttpCalloutMock.class, mock);
        AgentApiClient.agentDeveloperName = anyBotName();

        Test.startTest();
        AgentApiClient.Reply reply = AgentApiClient.ask('대성정밀 추천해줘');
        Test.stopTest();

        Assert.areEqual('sess-1', reply.sessionId);
        Assert.areEqual('추천 1순위 RP\n근거: 현금성자산', reply.text);
        Assert.areEqual('p1', reply.planId);
        Assert.areEqual(3, mock.calls.size(), '세션 생성·메시지·종료 3회 호출');
        Assert.isTrue(mock.calls[0].startsWith('POST callout:' + AgentApiClient.NAMED_CREDENTIAL + AgentApiClient.API_PATH + '/agents/'));
        Assert.isTrue(mock.calls[2].startsWith('DELETE '), '실패 여부와 무관하게 세션 종료');
    }

    @IsTest
    static void shouldThrowOnHttpError_AndStillCloseSession() {
        AgentApiMock mock = new AgentApiMock();
        mock.messageStatus = 500;
        mock.messageBody = '{"error":"boom"}';
        Test.setMock(HttpCalloutMock.class, mock);
        AgentApiClient.agentDeveloperName = anyBotName();

        Test.startTest();
        try {
            AgentApiClient.ask('x');
            Assert.fail('예외가 나야 함');
        } catch (AgentApiClient.AgentApiException e) {
            Assert.isTrue(e.getMessage().contains('HTTP 500'), e.getMessage());
        }
        Test.stopTest();
        Assert.areEqual(3, mock.calls.size(), '오류 뒤에도 DELETE 호출');
    }

    @IsTest
    static void shouldThrowWhenReplyEmpty() {
        AgentApiMock mock = new AgentApiMock();
        mock.messageBody = '{"messages":[]}';
        Test.setMock(HttpCalloutMock.class, mock);
        AgentApiClient.agentDeveloperName = anyBotName();
        try {
            AgentApiClient.ask('x');
            Assert.fail();
        } catch (AgentApiClient.AgentApiException e) {
            Assert.isTrue(e.getMessage().contains('비어'));
        }
    }

    @IsTest
    static void shouldRejectBlankUtterance() {
        try {
            AgentApiClient.ask('  ');
            Assert.fail();
        } catch (AgentApiClient.AgentApiException e) {
            Assert.isTrue(e.getMessage().contains('발화'));
        }
    }

    @IsTest
    static void shouldThrowWhenAgentMissing() {
        AgentApiClient.agentDeveloperName = 'No_Such_Agent_Xyz';
        try {
            AgentApiClient.ask('x');
            Assert.fail();
        } catch (AgentApiClient.AgentApiException e) {
            Assert.isTrue(e.getMessage().contains('No_Such_Agent_Xyz'));
        }
    }

    @IsTest
    static void invocableShouldAbsorbFailures() {
        AgentApiMock mock = new AgentApiMock();
        mock.messageStatus = 503;
        Test.setMock(HttpCalloutMock.class, mock);
        AgentApiClient.agentDeveloperName = anyBotName();
        AgentApiClient.Request ok = new AgentApiClient.Request();
        ok.utterance = 'x';

        List<AgentApiClient.Response> out = AgentApiClient.askAgent(new List<AgentApiClient.Request>{ ok });

        Assert.areEqual(1, out.size());
        Assert.isFalse(out[0].isSuccess);
        Assert.isTrue(out[0].errorMessage.contains('HTTP 503'));
        Assert.areEqual(0, AgentApiClient.askAgent(null).size());
    }

    @IsTest
    static void invocableShouldReturnReply() {
        Test.setMock(HttpCalloutMock.class, new AgentApiMock());
        AgentApiClient.agentDeveloperName = anyBotName();
        AgentApiClient.Request r = new AgentApiClient.Request();
        r.utterance = '후속 추천';
        AgentApiClient.Response res = AgentApiClient.askAgent(new List<AgentApiClient.Request>{ r })[0];
        Assert.isTrue(res.isSuccess, 'reply failed: ' + res.errorMessage);
        Assert.isTrue(res.reply.startsWith('추천 1순위'));
    }

    /** BotDefinition 은 테스트에서 만들 수 없어 org 에 있는 아무 에이전트 이름을 쓴다 (없으면 테스트 스킵용 더미). */
    private static String anyBotName() {
        List<BotDefinition> bots = [SELECT DeveloperName FROM BotDefinition LIMIT 1];
        return bots.isEmpty() ? 'RM_Assistant' : bots[0].DeveloperName;
    }
}