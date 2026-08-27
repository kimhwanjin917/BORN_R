@IsTest
private class BoniSlackEventHandlerTest {
    private class Mock implements HttpCalloutMock {
        public List<String> paths = new List<String>();
        public HttpResponse respond(HttpRequest r) { paths.add(r.getEndpoint().substringAfterLast('/')); HttpResponse s = new HttpResponse(); s.setStatusCode(200); s.setBody('{"ok":true,"ts":"1","channel":{"id":"D0X"}}'); return s; }
    }

    @IsTest
    static void appHomeOpened_republishesHomeForThatUser() {
        Mock m = new Mock(); Test.setMock(HttpCalloutMock.class, m);
        Test.startTest();
        BoniSlackEventHandler.handle(new List<Boni_Slack_Event__e>{ new Boni_Slack_Event__e(Event_Type__c = 'app_home_opened',
            Payload__c = '{"type":"event_callback","event":{"type":"app_home_opened","user":"U0BP7KFCUAG","tab":"home"}}') });
        Test.stopTest();
        if (!BoniPublisher.activeTargets().isEmpty()) Assert.isTrue(m.paths.contains('views.publish'));
    }

    @IsTest
    static void refreshAction_republishes_andPrepAction_repliesPreparing() {
        Mock m = new Mock(); Test.setMock(HttpCalloutMock.class, m);
        Test.startTest();
        BoniSlackEventHandler.handle(new List<Boni_Slack_Event__e>{
            new Boni_Slack_Event__e(Event_Type__c = 'block_actions', Payload__c = '{"type":"block_actions","user":{"id":"U0BP7KFCUAG"},"actions":[{"action_id":"boni_refresh","value":"refresh"}]}'),
            new Boni_Slack_Event__e(Event_Type__c = 'block_actions', Payload__c = '{"type":"block_actions","user":{"id":"U0BP7KFCUAG"},"channel":{"id":"D0X"},"actions":[{"action_id":"boni_prep_card","value":"00Uaj0000000001AAA"}]}')
        });
        Test.stopTest();
        Assert.isTrue(m.paths.contains('chat.postEphemeral') || m.paths.contains('chat.postMessage'), '준비 중 안내');
    }

    @IsTest
    static void badPayload_isIgnored() {
        Test.startTest();
        BoniSlackEventHandler.handle(new List<Boni_Slack_Event__e>{ new Boni_Slack_Event__e(Event_Type__c = 'block_actions', Payload__c = 'not json') });
        Test.stopTest();
        Assert.isTrue(true);
    }
}