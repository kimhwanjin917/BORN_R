@IsTest
private class BoniSlackClientTest {
    private class Mock implements HttpCalloutMock {
        public List<HttpRequest> requests = new List<HttpRequest>();
        private List<String> bodies; private Integer i = 0;
        Mock(List<String> bodies) { this.bodies = bodies; }
        public HttpResponse respond(HttpRequest r) {
            requests.add(r);
            HttpResponse res = new HttpResponse(); res.setStatusCode(200); res.setBody(bodies[Math.min(i++, bodies.size() - 1)]); return res;
        }
    }

    @IsTest
    static void openDm_returnsChannelId() {
        Mock m = new Mock(new List<String>{ '{"ok":true,"channel":{"id":"D0AAA"}}' });
        Test.setMock(HttpCalloutMock.class, m);
        Assert.areEqual('D0AAA', BoniSlackClient.openDm('U0BP7KFCUAG'));
        Assert.isTrue(m.requests[0].getEndpoint().endsWith('/conversations.open'));
        Assert.isTrue(m.requests[0].getBody().contains('"users":"U0BP7KFCUAG"'));
    }

    @IsTest
    static void postBlocks_sendsBlocksAndText() {
        Mock m = new Mock(new List<String>{ '{"ok":true,"ts":"1.2"}' });
        Test.setMock(HttpCalloutMock.class, m);
        String ts = BoniSlackClient.postBlocks('D0AAA', '폴백', new List<Object>{ new Map<String, Object>{ 'type' => 'divider' } });
        Assert.areEqual('1.2', ts);
        Map<String, Object> sent = (Map<String, Object>) JSON.deserializeUntyped(m.requests[0].getBody());
        Assert.areEqual('폴백', sent.get('text'));
        Assert.areEqual(1, ((List<Object>) sent.get('blocks')).size());
    }

    @IsTest
    static void publishHome_callsViewsPublishWithUser() {
        Mock m = new Mock(new List<String>{ '{"ok":true}' });
        Test.setMock(HttpCalloutMock.class, m);
        BoniSlackClient.publishHome('U0BP7KFCUAG', new Map<String, Object>{ 'type' => 'home', 'blocks' => new List<Object>() });
        Assert.isTrue(m.requests[0].getEndpoint().endsWith('/views.publish'));
        Assert.isTrue(m.requests[0].getBody().contains('"user_id":"U0BP7KFCUAG"'));
    }

    @IsTest
    static void slackError_throwsWithCode() {
        Test.setMock(HttpCalloutMock.class, new Mock(new List<String>{ '{"ok":false,"error":"invalid_blocks"}' }));
        try { BoniSlackClient.publishHome('U0', new Map<String, Object>()); Assert.fail('예외 기대'); }
        catch (BoniSlackClient.SlackApiException e) { Assert.areEqual('invalid_blocks', e.errorCode); }
    }

    @IsTest
    static void lookupUserIdByEmail_returnsNullWhenNotFound() {
        Test.setMock(HttpCalloutMock.class, new Mock(new List<String>{ '{"ok":false,"error":"users_not_found"}' }));
        Assert.isNull(BoniSlackClient.lookupUserIdByEmail('x@y.z'));
    }

    @IsTest
    static void postEphemeral_callsEndpoint() {
        Mock m = new Mock(new List<String>{ '{"ok":true}' });
        Test.setMock(HttpCalloutMock.class, m);
        BoniSlackClient.postEphemeral('D0AAA', 'U0BP7KFCUAG', '준비 중');
        Assert.isTrue(m.requests[0].getEndpoint().endsWith('/chat.postEphemeral'));
    }
}