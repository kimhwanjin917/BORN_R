/** 본이 전용 Slack Web API 래퍼. Named Credential "Slack" 사용. DM·홈 탭·에페메랄 지원(기존 SlackChannelMessageService 는 채널 텍스트 전용). */
public with sharing class BoniSlackClient {

    public class SlackApiException extends Exception { public String errorCode; }

    private static final String NC = 'callout:Slack';
    private static final Integer TIMEOUT_MS = 60000;

    public static String openDm(String slackUserId) {
        Map<String, Object> r = call('/conversations.open', new Map<String, Object>{ 'users' => slackUserId });
        return String.valueOf(((Map<String, Object>) r.get('channel')).get('id'));
    }

    public static String postBlocks(String channelId, String fallbackText, List<Object> blocks) {
        Map<String, Object> r = call('/chat.postMessage', new Map<String, Object>{ 'channel' => channelId, 'text' => fallbackText, 'blocks' => blocks });
        return String.valueOf(r.get('ts'));
    }

    public static void publishHome(String slackUserId, Map<String, Object> view) {
        call('/views.publish', new Map<String, Object>{ 'user_id' => slackUserId, 'view' => view });
    }

    public static void postEphemeral(String channelId, String slackUserId, String text) {
        call('/chat.postEphemeral', new Map<String, Object>{ 'channel' => channelId, 'user' => slackUserId, 'text' => text });
    }

    public static String lookupUserIdByEmail(String email) {
        try {
            Map<String, Object> r = call('/users.lookupByEmail', new Map<String, Object>{ 'email' => email });
            return String.valueOf(((Map<String, Object>) r.get('user')).get('id'));
        } catch (SlackApiException e) {
            if (e.errorCode == 'users_not_found') return null;
            throw e;
        }
    }

    private static Map<String, Object> call(String path, Map<String, Object> body) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(NC + path);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json; charset=utf-8');
        req.setTimeout(TIMEOUT_MS);
        req.setBody(JSON.serialize(body));
        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() == 429) {
            SlackApiException e = new SlackApiException('rate_limited retry-after=' + res.getHeader('Retry-After')); e.errorCode = 'rate_limited'; throw e;
        }
        if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
            SlackApiException e = new SlackApiException('HTTP ' + res.getStatusCode()); e.errorCode = 'HTTP_' + res.getStatusCode(); throw e;
        }
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        if (parsed.get('ok') != true) {
            SlackApiException e = new SlackApiException('Slack ' + path + ' 실패: ' + parsed.get('error')); e.errorCode = String.valueOf(parsed.get('error')); throw e;
        }
        return parsed;
    }
}