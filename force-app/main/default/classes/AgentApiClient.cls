/**
 * docs/51 · ADR-0002 — Agentforce Agent API 클라이언트.
 * Apex(비동기 트리거·화면 Flow)가 RM_Assistant 에이전트에게 말을 걸어 답을 받는 단일 통로.
 *
 * 호출 경로: callout:Agentforce_Agent_API (Named Credential, JWT Bearer → https://api.salesforce.com)
 *   POST   /einstein/ai-agent/v1/agents/{botId}/sessions   (bypassUser=false: 직원용 에이전트는 사용자 컨텍스트 필수 — 스파이크로 확인)
 *   POST   /einstein/ai-agent/v1/sessions/{sid}/messages
 *   DELETE /einstein/ai-agent/v1/sessions/{sid}
 *
 * - 세션은 질문 1건마다 열고 닫는다(추천은 단발 요청).
 * - 실패는 AgentApiException 으로 올리고, Invocable 래퍼는 isSuccess=false 로 흡수한다.
 * - 에이전트 액션은 Named Credential 의 실행 사용자 권한으로 돈다(로그인 RM 아님) — 통합 사용자에 RM 과 같은 권한 세트 필요.
 */
public with sharing class AgentApiClient {

    public static final String NAMED_CREDENTIAL = 'Agentforce_Agent_API';
    public static final String API_PATH = '/einstein/ai-agent/v1';
    @TestVisible
    private static String agentDeveloperName = 'RM_Assistant';
    @TestVisible
    private static Integer timeoutMillis = 120000;

    public class AgentApiException extends Exception {}

    /** 에이전트 답 1건 */
    public class Reply {
        public String sessionId;
        public String text;          // Inform 메시지들을 줄바꿈으로 이은 본문
        public String planId;
    }

    // ─── Public API ───────────────────────────────────────────────────────

    /** 세션 열기 → 발화 1건 → 세션 닫기. 답 본문을 돌려준다. */
    public static Reply ask(String utterance) {
        if (String.isBlank(utterance)) {
            throw new AgentApiException('발화가 비어 있습니다.');
        }
        Id botId = resolveBotId();
        String sessionId = startSession(botId);
        try {
            Reply reply = sendMessage(sessionId, utterance);
            reply.sessionId = sessionId;
            return reply;
        } finally {
            endSessionQuietly(sessionId);
        }
    }

    // ─── Invocable (화면 Flow · 후속 추천) ────────────────────────────────

    public class Request {
        @InvocableVariable(label='발화' description='에이전트에게 보낼 문장' required=true)
        public String utterance;
    }

    public class Response {
        @InvocableVariable(label='성공 여부')
        public Boolean isSuccess;
        @InvocableVariable(label='에이전트 답변')
        public String reply;
        @InvocableVariable(label='오류 메시지')
        public String errorMessage;
    }

    @InvocableMethod(
        label='RM 어시스턴트에게 묻기 (Agent API)'
        description='RM_Assistant 에이전트에 발화를 보내고 답변 본문을 돌려줍니다. 실패하면 isSuccess=false 와 오류 메시지를 반환합니다.'
        category='근본증권 RM')
    public static List<Response> askAgent(List<Request> requests) {
        List<Response> responses = new List<Response>();
        if (requests == null) {
            return responses;
        }
        for (Request req : requests) {
            Response res = new Response();
            try {
                res.reply = ask(req == null ? null : req.utterance).text;
                res.isSuccess = true;
            } catch (Exception e) {
                res.isSuccess = false;
                res.errorMessage = e.getMessage();
            }
            responses.add(res);
        }
        return responses;
    }

    // ─── HTTP steps ───────────────────────────────────────────────────────

    @TestVisible
    private static Id resolveBotId() {
        List<BotDefinition> bots = [
            SELECT Id FROM BotDefinition WHERE DeveloperName = :agentDeveloperName LIMIT 1
        ];
        if (bots.isEmpty()) {
            throw new AgentApiException('에이전트를 찾을 수 없습니다: ' + agentDeveloperName);
        }
        return bots[0].Id;
    }

    private static String startSession(Id botId) {
        Map<String, Object> body = new Map<String, Object>{
            'externalSessionKey' => newUuid(),
            'instanceConfig' => new Map<String, Object>{ 'endpoint' => URL.getOrgDomainUrl().toExternalForm() },
            'streamingCapabilities' => new Map<String, Object>{ 'chunkTypes' => new List<String>{ 'Text' } },
            'bypassUser' => false
        };
        HttpResponse res = send('POST', API_PATH + '/agents/' + botId + '/sessions', JSON.serialize(body));
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        String sessionId = (String) parsed.get('sessionId');
        if (String.isBlank(sessionId)) {
            throw new AgentApiException('세션 Id 가 응답에 없습니다: ' + res.getBody().abbreviate(300));
        }
        return sessionId;
    }

    private static Reply sendMessage(String sessionId, String utterance) {
        Map<String, Object> body = new Map<String, Object>{
            'message' => new Map<String, Object>{ 'sequenceId' => 1, 'type' => 'Text', 'text' => utterance }
        };
        HttpResponse res = send('POST', API_PATH + '/sessions/' + sessionId + '/messages', JSON.serialize(body));
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        Reply reply = new Reply();
        List<String> texts = new List<String>();
        Object messages = parsed.get('messages');
        if (messages instanceof List<Object>) {
            for (Object m : (List<Object>) messages) {
                Map<String, Object> msg = (Map<String, Object>) m;
                String text = (String) msg.get('message');
                if (!String.isBlank(text)) {
                    texts.add(text);
                }
                if (reply.planId == null) {
                    reply.planId = (String) msg.get('planId');
                }
            }
        }
        if (texts.isEmpty()) {
            throw new AgentApiException('에이전트 답변이 비어 있습니다: ' + res.getBody().abbreviate(300));
        }
        reply.text = String.join(texts, '\n');
        return reply;
    }

    private static void endSessionQuietly(String sessionId) {
        try {
            HttpRequest req = buildRequest('DELETE', API_PATH + '/sessions/' + sessionId, null);
            req.setHeader('x-session-end-reason', 'UserRequest');
            new Http().send(req);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Agent API 세션 종료 실패(무시): ' + e.getMessage());
        }
    }

    private static HttpResponse send(String method, String path, String body) {
        HttpResponse res = new Http().send(buildRequest(method, path, body));
        if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
            throw new AgentApiException('Agent API ' + method + ' ' + path + ' → HTTP ' + res.getStatusCode()
                + ' ' + (res.getBody() == null ? '' : res.getBody().abbreviate(300)));
        }
        return res;
    }

    private static HttpRequest buildRequest(String method, String path, String body) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:' + NAMED_CREDENTIAL + path);
        req.setMethod(method);
        req.setTimeout(timeoutMillis);
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Accept', 'application/json');
        req.setHeader('x-client-name', 'newborn-apex');
        if (body != null) {
            req.setBody(body);
        }
        return req;
    }

    private static String newUuid() {
        String h = EncodingUtil.convertToHex(Crypto.generateAesKey(128));
        return h.substring(0, 8) + '-' + h.substring(8, 12) + '-4' + h.substring(13, 16) + '-'
            + h.substring(16, 20) + '-' + h.substring(20, 32);
    }
}