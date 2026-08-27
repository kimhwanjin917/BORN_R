@IsTest
private class BoniPublisherTest {
    private class Mock implements HttpCalloutMock {
        public List<String> paths = new List<String>(); private Boolean failPost;
        Mock(Boolean failPost) { this.failPost = failPost; }
        public HttpResponse respond(HttpRequest r) {
            String p = r.getEndpoint().substringAfterLast('/'); paths.add(p);
            HttpResponse res = new HttpResponse(); res.setStatusCode(200);
            if (p == 'conversations.open') res.setBody('{"ok":true,"channel":{"id":"D0X"}}');
            else if (p == 'chat.postMessage' && failPost && !r.getBody().contains('C0BSE7LMBN2')) res.setBody('{"ok":false,"error":"channel_not_found"}');
            else res.setBody('{"ok":true,"ts":"1.0"}');
            return res;
        }
    }

    @IsTest
    static void briefing_opensDmPostsAndPublishesHome() {
        Mock m = new Mock(false); Test.setMock(HttpCalloutMock.class, m);
        Test.startTest();
        Integer ok = BoniPublisher.publishNow(BoniPublisher.Mode.BRIEFING, null);
        Test.stopTest();
        Assert.areEqual(BoniPublisher.activeTargets().size(), ok);
        if (ok > 0) {
            Assert.isTrue(m.paths.contains('chat.postMessage'));
            Assert.isTrue(m.paths.contains('views.publish'));
        }
    }

    @IsTest
    static void home_onlyPublishesView() {
        Mock m = new Mock(false); Test.setMock(HttpCalloutMock.class, m);
        BoniPublisher.publishNow(BoniPublisher.Mode.HOME, null);
        Assert.isFalse(m.paths.contains('chat.postMessage'));
    }

    @IsTest
    static void failure_isIsolatedAndAlerted() {
        Mock m = new Mock(true); Test.setMock(HttpCalloutMock.class, m);
        Integer ok = BoniPublisher.publishNow(BoniPublisher.Mode.WRAPUP, null);
        Assert.areEqual(0, ok, '전송 실패 대상은 성공으로 세지 않음');
        Integer posts = 0; for (String p : m.paths) if (p == 'chat.postMessage') posts++;
        if (!BoniPublisher.activeTargets().isEmpty()) Assert.isTrue(posts >= 2, '본문 1 + 알림 1');
    }

    @IsTest
    static void queueable_runs() {
        Test.setMock(HttpCalloutMock.class, new Mock(false));
        Test.startTest();
        System.enqueueJob(new BoniPublisher(BoniPublisher.Mode.HOME, 'U0BP7KFCUAG'));
        Test.stopTest();
        Assert.isTrue(true, '예외 없이 완료');
    }
}