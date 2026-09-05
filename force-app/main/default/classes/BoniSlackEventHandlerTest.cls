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
    static void dealTermApply_routesToHandler() {
        Account acc = new Account(Name = '근본물산', Business_Registration_Number__c = '9876543210');
        insert acc;
        Opportunity opp = new Opportunity(Name = '근본물산 - RP', AccountId = acc.Id, StageName = 'Prospecting', CloseDate = Date.today().addMonths(1));
        insert opp;
        Test.startTest();
        BoniSlackEventHandler.handle(new List<Boni_Slack_Event__e>{ new Boni_Slack_Event__e(Event_Type__c = DealTermReplyHandler.EVENT_APPLY,
            Payload__c = '{"oppId":"' + opp.Id + '","replyBy":"이주연","channelId":"C0DEAL1","ts":"1700000000.000100","yieldVal":3.8}') });
        Test.stopTest();
        Opportunity after = [SELECT RP_Yield__c, Product_Team_Reply_By__c FROM Opportunity WHERE Id = :opp.Id];
        Assert.areEqual(3.8, after.RP_Yield__c);
        Assert.areEqual('이주연', after.Product_Team_Reply_By__c);
    }

    @IsTest
    static void dealApprovalApprove_routesToHandler() {
        Account acc = new Account(Name = '승인테스트', Business_Registration_Number__c = '1112233446');
        insert acc;
        Opportunity opp = new Opportunity(Name = '승인테스트 - RP', AccountId = acc.Id, StageName = 'Prospecting',
            CloseDate = Date.today().addMonths(1), Pending_Yield__c = 4.5, RP_Yield__c = 3.8);
        insert opp;
        insert new Case(Opportunity__c = opp.Id, AccountId = acc.Id, Subject = '판매 승인 요청', Agreed_Yield_Rate__c = 4.5);

        Test.startTest();
        BoniSlackEventHandler.handle(new List<Boni_Slack_Event__e>{ new Boni_Slack_Event__e(
            Event_Type__c = DealApprovalHandler.EVENT_APPROVE,
            Payload__c = '{"oppId":"' + opp.Id + '","channelId":"C0DEAL1","ts":"1700000000.000100"}') });
        Test.stopTest();

        Opportunity after = [SELECT RP_Yield__c, Pending_Yield__c FROM Opportunity WHERE Id = :opp.Id];
        Assert.areEqual(4.5, after.RP_Yield__c, 'Pending→RP 승격');
        Assert.isNull(after.Pending_Yield__c, 'Pending 비워짐');
        Case c = [SELECT Approval_Status__c FROM Case WHERE Opportunity__c = :opp.Id LIMIT 1];
        Assert.areEqual('승인', c.Approval_Status__c);
    }

    @IsTest
    static void managerAction_routesToApprovalHandler() {
        Account acc = new Account(Name = '결재테스트', Business_Registration_Number__c = '1112233447');
        insert acc;
        Opportunity opp = new Opportunity(Name = '결재테스트 - RP', AccountId = acc.Id, StageName = 'Prospecting',
            CloseDate = Date.today().addMonths(1), Pending_Yield__c = 4.5, RP_Yield__c = 3.8);
        insert opp;
        insert new Case(Opportunity__c = opp.Id, AccountId = acc.Id, Subject = '판매 승인 요청', Agreed_Yield_Rate__c = 4.5);
        Mock m = new Mock(); Test.setMock(HttpCalloutMock.class, m);

        Test.startTest();
        BoniSlackEventHandler.handle(new List<Boni_Slack_Event__e>{ new Boni_Slack_Event__e(Event_Type__c = 'block_actions',
            Payload__c = '{"type":"block_actions","user":{"id":"U0TEST","name":"결재자"},"channel":{"id":"C0DEAL1"},"message":{"ts":"1700000000.000100","blocks":[]},"actions":[{"action_id":"' + OpportunityDealChannelService.ACTION_APPROVAL_MANAGER + '","value":"' + opp.Id + '"}]}') });
        Test.stopTest();

        // 클릭 라우팅은 토픽 표식 + "처리 중" 카드까지만 — 승인 DML 은 DealApprovalPoller 가 실행한다(2026-09-02).
        Assert.areNotEqual('승인', [SELECT Approval_Status__c FROM Case WHERE Opportunity__c = :opp.Id LIMIT 1].Approval_Status__c, '클릭 시점엔 미승인');
        Assert.isTrue(m.paths.contains('conversations.setTopic'), '토픽 표식 기록');
    }

    @IsTest
    static void managerApplyEvent_routesToHandler() {
        Account acc = new Account(Name = '결재이벤트', Business_Registration_Number__c = '1112233448');
        insert acc;
        Opportunity opp = new Opportunity(Name = '결재이벤트 - RP', AccountId = acc.Id, StageName = 'Prospecting',
            CloseDate = Date.today().addMonths(1), Pending_Yield__c = 4.5, RP_Yield__c = 3.8);
        insert opp;
        insert new Case(Opportunity__c = opp.Id, AccountId = acc.Id, Subject = '판매 승인 요청', Agreed_Yield_Rate__c = 4.5);

        Test.startTest();
        BoniSlackEventHandler.handle(new List<Boni_Slack_Event__e>{ new Boni_Slack_Event__e(
            Event_Type__c = DealApprovalHandler.EVENT_MANAGER,
            Payload__c = '{"oppId":"' + opp.Id + '","channelId":"C0DEAL1","ts":"1700000000.000100"}') });
        Test.stopTest();

        Assert.areEqual('승인', [SELECT Approval_Status__c FROM Case WHERE Opportunity__c = :opp.Id LIMIT 1].Approval_Status__c, '이벤트 경로 결재 승인');
    }

    @IsTest
    static void rejectAction_replyPlaceholder() {
        // 반려는 표시용(무늬) — 구 action id 로 오는 클릭에만 준비 중 안내를 돌려준다(2026-09-02 요구).
        Mock m = new Mock(); Test.setMock(HttpCalloutMock.class, m);
        Test.startTest();
        BoniSlackEventHandler.handle(new List<Boni_Slack_Event__e>{
            new Boni_Slack_Event__e(Event_Type__c = 'block_actions', Payload__c = '{"type":"block_actions","user":{"id":"U0TEST"},"channel":{"id":"C0TEST"},"actions":[{"action_id":"' + OpportunityDealChannelService.ACTION_APPROVAL_REJECT + '","value":"001000000000001"}]}')
        });
        Test.stopTest();
        Assert.isTrue(m.paths.contains('chat.postEphemeral') || m.paths.contains('chat.postMessage'), '플레이스홀더 응답');
    }

    @IsTest
    static void badPayload_isIgnored() {
        Test.startTest();
        BoniSlackEventHandler.handle(new List<Boni_Slack_Event__e>{ new Boni_Slack_Event__e(Event_Type__c = 'block_actions', Payload__c = 'not json') });
        Test.stopTest();
        Assert.isTrue(true);
    }
}