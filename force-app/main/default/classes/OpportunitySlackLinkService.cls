/**
 * 봇이 만든 Slack 채널을 Salesforce 레코드에 "Salesforce 채널"로 연결한다.
 *
 * Slack `admin.conversations.linkObjects` 는 봇 토큰으로는 호출할 수 없고(not_allowed_token_type),
 * 조직 단위로 설치된 앱의 관리자 사용자 토큰(scope: admin.conversations:manage_objects)이 필요하다.
 * 그 토큰은 Named Credential `Slack_Admin` 에 들어 있다(봇 토큰은 `Slack`).
 *
 * 연결에 성공하면 레코드 페이지의 표준 "Slack Channel" 카드에 그 채널 대화가 바로 표시된다.
 * 연결 실패는 채널 생성·카드 게시에 영향을 주면 안 되므로 예외를 밖으로 던지지 않는다.
 */
public with sharing class OpportunitySlackLinkService {

    @TestVisible private static final String NC = 'callout:Slack_Admin';
    private static final Integer TIMEOUT_MS = 20000;

    /** 이미 다른 채널/레코드에 묶여 있어서 "연결된 상태"로 간주해도 되는 Slack 오류. */
    private static final Set<String> ALREADY_LINKED = new Set<String>{ 'channel_already_exists', 'record_channel_already_exists' };

    /** 마지막 호출 결과(테스트·디버그용). */
    @TestVisible private static String lastError;

    /**
     * 채널을 레코드에 연결한다. 성공 또는 이미 연결돼 있으면 true, 그 외 false.
     * 어떤 경우에도 예외를 던지지 않는다.
     */
    public static Boolean link(String channelId, Id recordId) {
        lastError = null;
        if (String.isBlank(channelId) || recordId == null) {
            lastError = 'missing_arguments';
            return false;
        }
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(NC + '/admin.conversations.linkObjects');
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json; charset=utf-8');
            req.setTimeout(TIMEOUT_MS);
            req.setBody(JSON.serialize(new Map<String, Object>{
                'channel' => channelId,
                'record_id' => String.valueOf(recordId),
                'salesforce_org_id' => String.valueOf(UserInfo.getOrganizationId())
            }));
            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
                lastError = 'http_' + res.getStatusCode();
                System.debug(LoggingLevel.ERROR, 'Slack 채널 연결 실패 ' + recordId + ': HTTP ' + res.getStatusCode());
                return false;
            }
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            if (body.get('ok') == true) {
                return true;
            }
            String err = String.valueOf(body.get('error'));
            if (ALREADY_LINKED.contains(err)) {
                return true;
            }
            lastError = err;
            System.debug(LoggingLevel.ERROR, 'Slack 채널 연결 실패 ' + recordId + ' / ' + channelId + ': ' + err);
            return false;
        } catch (Exception e) {
            lastError = e.getMessage();
            System.debug(LoggingLevel.ERROR, 'Slack 채널 연결 예외 ' + recordId + ': ' + e.getMessage());
            return false;
        }
    }
}