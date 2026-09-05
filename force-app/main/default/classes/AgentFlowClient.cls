/**
 * docs/60 — RM_Assistant 에이전트를 자동 실행 Flow `Agent_Recommend_Meeting_Note`(에이전트 액션)로 호출하는 얇은 클라이언트.
 * Agent API / Named Credential 없이 org 안에서 동작하며, sessionId 를 넘기면 같은 대화를 이어간다.
 * 에이전트 액션의 agentResponse 는 {"type":"InformMessage","value":{"message":"..."}} 형태의 JSON 이라 본문만 뽑아 돌려준다.
 */
public with sharing class AgentFlowClient {

    public static final String FLOW_NAME = 'Agent_Recommend_Meeting_Note';

    public class AgentFlowException extends Exception {}

    public class Reply {
        public String sessionId;
        public String text;
    }

    /** 테스트용 스텁: 설정되면 Flow 를 호출하지 않고 이 값을 돌려준다. */
    @TestVisible
    private static Reply stubReply;
    @TestVisible
    private static String stubError;
    @TestVisible
    private static List<String> capturedMessages = new List<String>();

    /** 새 대화를 시작한다. */
    public static Reply ask(String userMessage) {
        return ask(userMessage, null);
    }

    /** sessionId 가 있으면 그 대화를 이어간다. */
    public static Reply ask(String userMessage, String sessionId) {
        if (String.isBlank(userMessage)) {
            throw new AgentFlowException('에이전트에 보낼 메시지가 비어 있습니다.');
        }
        capturedMessages.add(userMessage);
        if (stubError != null) {
            throw new AgentFlowException(stubError);
        }
        if (stubReply != null) {
            return stubReply;
        }
        Map<String, Object> inputs = new Map<String, Object>{ 'userMessage' => userMessage };
        if (!String.isBlank(sessionId)) {
            inputs.put('sessionIdIn', sessionId);
        }
        Flow.Interview interview = Flow.Interview.createInterview(FLOW_NAME, inputs);
        interview.start();
        Reply reply = new Reply();
        reply.sessionId = (String) interview.getVariableValue('sessionIdOut');
        reply.text = extractMessage((String) interview.getVariableValue('agentResponse'));
        if (String.isBlank(reply.text)) {
            throw new AgentFlowException('에이전트 응답이 비어 있습니다.');
        }
        return reply;
    }

    /** 에이전트 액션 JSON 봉투에서 사람이 읽을 본문만 꺼낸다. JSON 이 아니면 원문 그대로. */
    @TestVisible
    private static String extractMessage(String raw) {
        if (String.isBlank(raw)) {
            return null;
        }
        String trimmed = raw.trim();
        if (!trimmed.startsWith('{')) {
            return trimmed;
        }
        try {
            Map<String, Object> envelope = (Map<String, Object>) JSON.deserializeUntyped(trimmed);
            Object value = envelope.get('value');
            if (value instanceof Map<String, Object>) {
                Object msg = ((Map<String, Object>) value).get('message');
                if (msg != null && !String.isBlank(String.valueOf(msg))) {
                    return String.valueOf(msg);
                }
            }
            Object topMsg = envelope.get('message');
            if (topMsg != null) {
                return String.valueOf(topMsg);
            }
        } catch (Exception e) {
            // JSON 이 아니면 원문 반환
        }
        return trimmed;
    }
}