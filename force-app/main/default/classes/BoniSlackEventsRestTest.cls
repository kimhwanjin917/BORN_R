@IsTest
private class BoniSlackEventsRestTest {
    private static final String SECRET = 'testsecret';

    private class Mock implements HttpCalloutMock { public HttpResponse respond(HttpRequest r) { HttpResponse s = new HttpResponse(); s.setStatusCode(200); s.setBody('{"ok":true,"ts":"1","channel":{"id":"D"}}'); return s; } }

    @TestSetup
    static void setup() { insert new Boni_Secret__c(SetupOwnerId = UserInfo.getOrganizationId(), Signing_Secret__c = SECRET, Verification_Token__c = 'VTOKEN'); }

    private static String sign(String ts, String body) {
        Blob mac = Crypto.generateMac('hmacSHA256', Blob.valueOf('v0:' + ts + ':' + body), Blob.valueOf(SECRET));
        return 'v0=' + EncodingUtil.convertToHex(mac);
    }
    private static RestResponse post(String path, String body, String ts, String sig) {
        RestRequest req = new RestRequest(); req.requestUri = '/services/apexrest/boni/slack/' + path; req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(body);
        req.addHeader('X-Slack-Request-Timestamp', ts); req.addHeader('X-Slack-Signature', sig);
        RestContext.request = req; RestContext.response = new RestResponse();
        BoniSlackEventsRest.doPost();
        return RestContext.response;
    }
    private static String nowTs() { return String.valueOf(Datetime.now().getTime() / 1000); }

    @IsTest
    static void isValidSignature_trueForCorrectMac() {
        String ts = nowTs(); String body = '{"a":1}';
        Assert.isTrue(BoniSlackEventsRest.isValidSignature(SECRET, ts, body, sign(ts, body)));
        Assert.isFalse(BoniSlackEventsRest.isValidSignature(SECRET, ts, body, 'v0=deadbeef'));
    }

    @IsTest
    static void urlVerification_returnsChallenge() {
        String ts = nowTs(); String body = '{"type":"url_verification","challenge":"abc123"}';
        RestResponse res = post('events', body, ts, sign(ts, body));
        Assert.areEqual(200, res.statusCode);
        Assert.areEqual('abc123', res.responseBody.toString());
    }

    @IsTest
    static void badSignature_returns401() {
        String ts = nowTs();
        RestResponse res = post('events', '{"type":"event_callback"}', ts, 'v0=bad');
        Assert.areEqual(401, res.statusCode);
    }

    @IsTest
    static void staleTimestamp_returns401() {
        String ts = String.valueOf(Datetime.now().addMinutes(-10).getTime() / 1000); String body = '{"type":"event_callback"}';
        Assert.areEqual(401, post('events', body, ts, sign(ts, body)).statusCode);
    }

    @IsTest
    static void appHomeOpened_publishesPlatformEventAnd200() {
        Test.setMock(HttpCalloutMock.class, new Mock());
        String ts = nowTs();
        String body = '{"type":"event_callback","event":{"type":"app_home_opened","user":"U0BP7KFCUAG","tab":"home"}}';
        Test.startTest();
        RestResponse res = post('events', body, ts, sign(ts, body));
        Test.getEventBus().deliver();
        Test.stopTest();
        Assert.areEqual(200, res.statusCode);
    }

    private static RestResponse postForm(String payload, String ts) {
        RestRequest req = new RestRequest(); req.requestUri = '/services/apexrest/boni/slack/actions'; req.httpMethod = 'POST';
        req.params.put('payload', payload);   // Apex REST 가 form 본문을 params 로 분해한 상태를 재현
        req.addHeader('X-Slack-Request-Timestamp', ts); req.addHeader('X-Slack-Signature', 'v0=whatever');
        RestContext.request = req; RestContext.response = new RestResponse();
        BoniSlackEventsRest.doPost();
        return RestContext.response;
    }

    /**
     * Sites 의 Apex REST 는 form-urlencoded 본문을 params 로 분해할 때 UTF-8 을 Latin-1 로 잘못 해석해
     * 한글이 깨진다(2026-08-31 실측 — 카드 블록·회신자 이름 오염). fixEncoding 이 되돌린다.
     */
    @IsTest
    static void fixEncoding_repairsMojibakeKorean_keepsNormalStrings() {
        String korean = '{"text":"상품팀 회신 이주연"}';
        // UTF-8 바이트를 Latin-1 로 잘못 읽은 상태 재현: 각 UTF-8 바이트가 0xFF 이하 문자 하나로 풀림
        String mojibake = EncodingUtil.urlDecode(EncodingUtil.urlEncode(korean, 'UTF-8'), 'ISO-8859-1');
        Assert.areNotEqual(korean, mojibake, '재현 전제: 깨진 상태여야 함');

        Assert.areEqual(korean, BoniSlackEventsRest.fixEncoding(mojibake), '깨진 한글 복구');
        Assert.areEqual(korean, BoniSlackEventsRest.fixEncoding(korean), '정상 한글은 그대로');
        String ascii = '{"type":"block_actions","token":"VTOKEN"}';
        Assert.areEqual(ascii, BoniSlackEventsRest.fixEncoding(ascii), 'ASCII 는 그대로');
        Assert.areEqual(null, BoniSlackEventsRest.fixEncoding(null));
    }

    @IsTest
    static void blockActions_formEncoded_validToken_200() {
        Test.setMock(HttpCalloutMock.class, new Mock());
        String payload = '{"type":"block_actions","token":"VTOKEN","api_app_id":"A0BSJ6W4F96","user":{"id":"U0BP7KFCUAG"},"actions":[{"action_id":"boni_refresh","value":"refresh"}]}';
        Test.startTest();
        RestResponse res = postForm(payload, nowTs());
        Test.getEventBus().deliver();
        Test.stopTest();
        Assert.areEqual(200, res.statusCode);
    }

    @IsTest
    static void blockActions_wrongToken_401() {
        String payload = '{"type":"block_actions","token":"WRONG","api_app_id":"A0BSJ6W4F96","user":{"id":"U0"},"actions":[]}';
        Assert.areEqual(401, postForm(payload, nowTs()).statusCode);
    }

    @IsTest
    static void blockActions_wrongAppId_401() {
        String payload = '{"type":"block_actions","token":"VTOKEN","api_app_id":"AOTHER","user":{"id":"U0"},"actions":[]}';
        Assert.areEqual(401, postForm(payload, nowTs()).statusCode);
    }
}