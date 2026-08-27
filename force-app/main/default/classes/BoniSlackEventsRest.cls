/**
 * Slack → 본이 inbound. 공개 Site 게스트가 실행. 검증 후 플랫폼 이벤트만 발행하고 즉시 200.
 * 게스트는 CRM 데이터를 못 읽으므로 처리 자체는 BoniSlackEventTrigger(시스템 컨텍스트)에서 한다.
 *
 * 검증 방식 2가지:
 *  - JSON 본문(Events API: url_verification, app_home_opened): Signing Secret HMAC 서명 검증.
 *  - form-urlencoded(Interactivity: block_actions): Apex REST 가 본문을 params 로 분해해 requestBody 가 비고
 *    원문을 바이트 동일하게 복원할 수 없어 서명 재계산이 불가능하다(실측). 대신 payload 안의
 *    Verification Token + api_app_id + timestamp 신선도로 검증한다.
 */
@RestResource(urlMapping='/boni/slack/*')
global with sharing class BoniSlackEventsRest {

    private static final Integer MAX_SKEW_SECONDS = 300;
    @TestVisible private static final String APP_ID = 'A0BSJ6W4F96';

    @HttpPost
    global static void doPost() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;
        String body = req.requestBody == null ? '' : req.requestBody.toString();
        String ts = req.headers.get('X-Slack-Request-Timestamp');
        String sig = req.headers.get('X-Slack-Signature');
        Boni_Secret__c sec = Boni_Secret__c.getOrgDefaults();

        String jsonBody;
        Boolean valid = false;
        if (String.isBlank(body) && req.params != null && req.params.containsKey('payload')) {
            // Interactivity (form-urlencoded)
            jsonBody = req.params.get('payload');
            valid = isFresh(ts) && isValidToken(sec.Verification_Token__c, jsonBody);
        } else {
            // Events API (JSON)
            jsonBody = body.startsWith('payload=') ? EncodingUtil.urlDecode(body.substring(8), 'UTF-8') : body;
            valid = String.isNotBlank(sec.Signing_Secret__c) && isValidSignature(sec.Signing_Secret__c, ts, body, sig);
        }
        if (!valid) { res.statusCode = 401; res.responseBody = Blob.valueOf('invalid signature'); return; }

        Map<String, Object> parsed;
        try { parsed = (Map<String, Object>) JSON.deserializeUntyped(jsonBody); }
        catch (Exception e) { res.statusCode = 400; res.responseBody = Blob.valueOf('bad json'); return; }

        String type = String.valueOf(parsed.get('type'));
        if (type == 'url_verification') {
            res.statusCode = 200; res.addHeader('Content-Type', 'text/plain'); res.responseBody = Blob.valueOf(String.valueOf(parsed.get('challenge'))); return;
        }
        String eventType = type;
        if (type == 'event_callback' && parsed.get('event') instanceof Map<String, Object>) {
            eventType = String.valueOf(((Map<String, Object>) parsed.get('event')).get('type'));
        }
        // 게스트 컨텍스트에서 직접 처리(Queueable 로 콜아웃). 플랫폼 이벤트 경로는 Automated Process 가
        // Named Credential 에 접근하지 못해(실측: "We couldn't access the credential(s)") 사용하지 않는다.
        // 게스트 사용자에게 Slack_Access 권한세트를 부여해야 한다.
        BoniSlackEventHandler.handle(new List<Boni_Slack_Event__e>{
            new Boni_Slack_Event__e(Event_Type__c = eventType.left(40), Payload__c = jsonBody.left(131072)) });
        res.statusCode = 200; res.responseBody = Blob.valueOf('');
    }

    public static Boolean isFresh(String timestamp) {
        if (String.isBlank(timestamp) || !timestamp.isNumeric()) return false;
        Long now = Datetime.now().getTime() / 1000;
        return Math.abs(now - Long.valueOf(timestamp)) <= MAX_SKEW_SECONDS;
    }

    /** payload.token == Verification Token 이고 api_app_id 가 본이 앱이면 true */
    public static Boolean isValidToken(String expectedToken, String payloadJson) {
        if (String.isBlank(expectedToken) || String.isBlank(payloadJson)) return false;
        try {
            Map<String, Object> p = (Map<String, Object>) JSON.deserializeUntyped(payloadJson);
            return expectedToken == String.valueOf(p.get('token')) && APP_ID == String.valueOf(p.get('api_app_id'));
        } catch (Exception e) { return false; }
    }

    public static Boolean isValidSignature(String secret, String timestamp, String body, String signature) {
        if (String.isBlank(signature) || !isFresh(timestamp)) return false;
        Blob mac = Crypto.generateMac('hmacSHA256', Blob.valueOf('v0:' + timestamp + ':' + body), Blob.valueOf(secret));
        String expected = 'v0=' + EncodingUtil.convertToHex(mac);
        return expected == signature;
    }
}