/**
 * 지정한 Slack 채널 ID 에 텍스트 메시지 1건을 게시하는 Flow 호출용(Invocable) 서비스.
 * (백로그 28번: 미팅 요약을 내부 상품팀 채널 #상품팀-검토 로 자동 전송)
 *
 * - Slack 호출은 Named Credential "Slack" (callout:Slack → https://slack.com/api) 로 나간다. 코드에 토큰 없음.
 * - 채널은 호출자(Flow)가 넘긴다. 봇(born-briefing-bot)이 그 채널의 멤버여야 한다.
 *   비공개 채널은 봇이 스스로 들어갈 수 없으므로, not_in_channel 이면 "초대 필요" 안내를 돌려준다.
 * - 실패는 예외를 던지지 않고 Response.isSuccess=false + errorMessage 로 보고한다 (Flow 가 분기 처리).
 * - 14/15번 클래스(SlackLeadChannelService, SlackProposalShareService)는 수정하지 않고 독립적으로 동작한다.
 */
public with sharing class SlackChannelMessageService {

    private static final String NAMED_CREDENTIAL = 'callout:Slack';
    private static final Integer CALLOUT_TIMEOUT_MS = 60000;
    private static final String CONTENT_TYPE_JSON = 'application/json; charset=utf-8';

    /** Slack chat.postMessage 의 text 상한(안전치). 초과분은 잘라내고 표시한다. */
    @TestVisible private static final Integer MAX_TEXT_LENGTH = 12000;
    @TestVisible private static final String TRUNCATED_SUFFIX = '\n…(이하 생략)';

    private static final String ERR_MISSING_SCOPE = 'missing_scope';
    private static final String ERR_NOT_IN_CHANNEL = 'not_in_channel';
    private static final String ERR_CHANNEL_NOT_FOUND = 'channel_not_found';
    private static final String ERR_IS_ARCHIVED = 'is_archived';

    @InvocableMethod(
        label='Slack: 채널에 메시지 게시'
        description='채널 ID 로 지정한 Slack 채널에 텍스트 메시지 1건을 게시합니다. 봇이 채널 멤버가 아니면 실패(초대 필요)를 돌려줍니다.'
        category='Slack'
        callout=true
    )
    public static List<Response> postMessages(List<Request> requests) {
        List<Response> responses = new List<Response>();
        if (requests == null || requests.isEmpty()) {
            return responses;
        }
        for (Request request : requests) {
            responses.add(processRequest(request));
        }
        return responses;
    }

    private static Response processRequest(Request request) {
        Response response = new Response();
        response.isSuccess = false;

        if (request == null || String.isBlank(request.channelId)) {
            return fail(response, 'VALIDATION', 'channelId 가 비어 있습니다.');
        }
        if (String.isBlank(request.text)) {
            return fail(response, 'VALIDATION', '보낼 메시지(text)가 비어 있습니다.');
        }
        response.channelId = request.channelId.trim();

        String text = request.text;
        if (text.length() > MAX_TEXT_LENGTH) {
            text = text.substring(0, MAX_TEXT_LENGTH - TRUNCATED_SUFFIX.length()) + TRUNCATED_SUFFIX;
        }

        try {
            Map<String, Object> result = postJson('/chat.postMessage', new Map<String, Object>{
                'channel' => response.channelId,
                'text' => text
            });
            if (result.get('ok') != true) {
                String errorCode = String.valueOf(result.get('error'));
                return fail(response, errorCode, describeSlackError(result));
            }
            response.isSuccess = true;
            response.messageTs = String.valueOf(result.get('ts'));
            return response;
        } catch (SlackChannelMessageException e) {
            return fail(response, e.slackErrorCode, e.getMessage());
        } catch (CalloutException e) {
            return fail(response, e.getTypeName(), 'Slack 호출 오류: ' + e.getMessage());
        } catch (Exception e) {
            return fail(response, e.getTypeName(), e.getMessage());
        }
    }

    private static Response fail(Response response, String errorType, String message) {
        response.isSuccess = false;
        response.errorType = errorType;
        response.errorMessage = message;
        return response;
    }

    // ─── HTTP plumbing ───────────────────────────────────────────────────

    private static Map<String, Object> postJson(String path, Map<String, Object> body) {
        HttpRequest httpRequest = new HttpRequest();
        httpRequest.setEndpoint(NAMED_CREDENTIAL + path);
        httpRequest.setMethod('POST');
        httpRequest.setHeader('Content-Type', CONTENT_TYPE_JSON);
        httpRequest.setTimeout(CALLOUT_TIMEOUT_MS);
        httpRequest.setBody(JSON.serialize(body));

        HttpResponse httpResponse = new Http().send(httpRequest);
        if (httpResponse.getStatusCode() < 200 || httpResponse.getStatusCode() >= 300) {
            throw new SlackChannelMessageException(
                'Slack HTTP ' + httpResponse.getStatusCode() + ' ' + httpResponse.getStatus(),
                'HTTP_' + httpResponse.getStatusCode()
            );
        }
        Object parsed = JSON.deserializeUntyped(httpResponse.getBody());
        if (!(parsed instanceof Map<String, Object>)) {
            throw new SlackChannelMessageException('Slack 응답을 해석할 수 없습니다.', 'INVALID_RESPONSE');
        }
        return (Map<String, Object>) parsed;
    }

    @TestVisible
    private static String describeSlackError(Map<String, Object> result) {
        String errorCode = String.valueOf(result.get('error'));
        if (errorCode == ERR_MISSING_SCOPE) {
            return 'Slack 앱 권한(scope) 부족: ' + String.valueOf(result.get('needed'))
                + ' 가 필요합니다. api.slack.com 에서 scope 추가 후 Reinstall 하세요.';
        }
        if (errorCode == ERR_NOT_IN_CHANNEL) {
            return 'not_in_channel — 봇(born-briefing-bot)이 이 채널의 멤버가 아닙니다. Slack 에서 채널에 봇을 초대(/invite @born-briefing-bot)한 뒤 다시 실행하세요.';
        }
        if (errorCode == ERR_CHANNEL_NOT_FOUND) {
            return 'channel_not_found — 채널 ID 가 틀렸거나 봇이 볼 수 없는 채널입니다(비공개 채널은 봇 초대 필요).';
        }
        if (errorCode == ERR_IS_ARCHIVED) {
            return 'is_archived — 채널이 아카이브되어 메시지를 보낼 수 없습니다.';
        }
        return errorCode;
    }

    // ─── Request / Response DTOs ─────────────────────────────────────────

    public class Request {
        @InvocableVariable(label='채널 ID' description='메시지를 게시할 Slack 채널 ID (예: C0BRTMCTUN5)' required=true)
        public String channelId;

        @InvocableVariable(label='메시지 본문' description='게시할 텍스트 (Slack mrkdwn 허용)' required=true)
        public String text;
    }

    public class Response {
        @InvocableVariable(label='성공 여부')
        public Boolean isSuccess;

        @InvocableVariable(label='채널 ID')
        public String channelId;

        @InvocableVariable(label='메시지 ts' description='게시된 메시지의 Slack timestamp')
        public String messageTs;

        @InvocableVariable(label='오류 메시지')
        public String errorMessage;

        @InvocableVariable(label='오류 유형' description='Slack error 코드 또는 예외 타입')
        public String errorType;
    }

    public class SlackChannelMessageException extends Exception {
        public String slackErrorCode;
        public SlackChannelMessageException(String message, String slackErrorCode) {
            this.setMessage(message);
            this.slackErrorCode = slackErrorCode;
        }
    }
}