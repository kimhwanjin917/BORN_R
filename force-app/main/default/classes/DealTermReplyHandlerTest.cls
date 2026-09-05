@IsTest
private class DealTermReplyHandlerTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(Name = '근본물산', Business_Registration_Number__c = '1234567890');
        insert acc;
        insert new Opportunity(Name = '근본물산 - RP', AccountId = acc.Id, StageName = 'Prospecting', CloseDate = Date.today().addMonths(1),
            Amount = 5000000000L, Fee_Rate__c = 0.12, Slack_Channel_ID__c = 'C0DEAL1');
    }

    private static Map<String, Object> payload(String value, String yield, String coupon, String issuer) {
        return payload(value, yield, null, coupon, issuer);
    }

    private static Map<String, Object> payload(String value, String yield, String appliedFee, String coupon, String issuer) {
        return new Map<String, Object>{
            'type' => 'block_actions',
            'user' => new Map<String, Object>{ 'id' => 'UREP', 'username' => 'rep', 'name' => '이주연' },
            'channel' => new Map<String, Object>{ 'id' => 'C0DEAL1' },
            'message' => new Map<String, Object>{ 'ts' => '1700000000.000100' },
            'actions' => new List<Object>{ new Map<String, Object>{ 'action_id' => 'deal_term_reply', 'value' => value } },
            'state' => new Map<String, Object>{ 'values' => new Map<String, Object>{
                'rp_yield' => new Map<String, Object>{ 'rp_yield_in' => new Map<String, Object>{ 'value' => yield } },
                'applied_fee' => new Map<String, Object>{ 'applied_fee_in' => new Map<String, Object>{ 'value' => appliedFee } },
                'coupon_rate' => new Map<String, Object>{ 'coupon_rate_in' => new Map<String, Object>{ 'value' => coupon } },
                'issuer' => new Map<String, Object>{ 'issuer_in' => new Map<String, Object>{ 'value' => issuer } }
            } }
        };
    }

    private class Mock implements HttpCalloutMock {
        public List<String> paths = new List<String>();
        public String lastBody;
        public HttpResponse respond(HttpRequest req) {
            paths.add(req.getEndpoint().substringAfter('callout:Slack'));
            lastBody = req.getBody();
            HttpResponse r = new HttpResponse();
            r.setStatusCode(200);
            r.setBody('{"ok":true,"ts":"1700000000.000100"}');
            return r;
        }
    }

    private static Opportunity getOpp() {
        return [SELECT Id, RP_Yield__c, Fee_Rate__c, Coupon_Rate__c, Issuer_Name__c, Product_Team_Reply_By__c, Product_Team_Reply_At__c, Slack_Reply_Link__c, Approval_Status__c
                FROM Opportunity LIMIT 1];
    }

    @IsTest
    static void handle_savesValuesAndUpdatesCard() {
        Opportunity opp = getOpp();
        Mock m = new Mock();
        Test.setMock(HttpCalloutMock.class, m);

        Test.startTest();
        DealTermReplyHandler.handle(payload(String.valueOf(opp.Id), '3.8', '0.2', '4.0', '근본캐피탈'));
        Test.stopTest();

        Opportunity after = getOpp();
        Assert.areEqual(3.8, after.RP_Yield__c);
        Assert.areEqual(0.2, after.Fee_Rate__c, '적용 수수료율이 Fee_Rate__c 에 저장');
        Assert.areEqual(4.0, after.Coupon_Rate__c);
        Assert.areEqual('근본캐피탈', after.Issuer_Name__c);
        Assert.areEqual('이주연', after.Product_Team_Reply_By__c);
        Assert.isNotNull(after.Product_Team_Reply_At__c);
        Assert.isTrue(after.Slack_Reply_Link__c.endsWith('/archives/C0DEAL1/p1700000000000100'), after.Slack_Reply_Link__c);
        Assert.isNull(after.Approval_Status__c, '회신은 승인이 아니다');
        Assert.isTrue(m.paths.contains('/chat.update'), '카드가 회신 완료로 갱신된다: ' + m.paths);
    }

    @IsTest
    static void handle_blankYield_savesRestAndUpdatesCard() {
        Opportunity opp = getOpp();
        Mock m = new Mock();
        Test.setMock(HttpCalloutMock.class, m);

        Test.startTest();
        DealTermReplyHandler.handle(payload(String.valueOf(opp.Id), '', '4.0', '근본캐피탈'));
        Test.stopTest();

        Opportunity after = getOpp();
        Assert.isNull(after.RP_Yield__c, '빈 수익률은 저장 안 함');
        Assert.areEqual(4.0, after.Coupon_Rate__c, '들어온 값은 저장');
        Assert.areEqual('근본캐피탈', after.Issuer_Name__c);
        Assert.areEqual('이주연', after.Product_Team_Reply_By__c, '비어도 회신자는 기록');
        Assert.isTrue(m.paths.contains('/chat.update'), '경고 없이 회신 완료로 잠근다: ' + m.paths);
        Assert.isFalse(m.paths.contains('/chat.postEphemeral'), '강제 재제출 경고 없음');
    }

    @IsTest
    static void handle_nonNumericYield_skipsYieldSavesRest() {
        Opportunity opp = getOpp();
        Mock m = new Mock();
        Test.setMock(HttpCalloutMock.class, m);

        Test.startTest();
        DealTermReplyHandler.handle(payload(String.valueOf(opp.Id), '삼점팔', '4.0', '근본캐피탈'));
        Test.stopTest();

        Opportunity after = getOpp();
        Assert.isNull(after.RP_Yield__c, '숫자 아닌 수익률은 건너뜀');
        Assert.areEqual(4.0, after.Coupon_Rate__c);
        Assert.isTrue(m.paths.contains('/chat.update'));
        Assert.isFalse(m.paths.contains('/chat.postEphemeral'));
    }

    /** Salesforce 화면 경로: ts 없이 applyReply → 필드 갱신 + chat.postMessage 로 회신 완료 카드 새로 게시 + 링크 저장. */
    @IsTest
    static void applyReply_withoutTs_postsNewCardAndStoresLink() {
        Opportunity opp = getOpp();
        Mock m = new Mock();
        Test.setMock(HttpCalloutMock.class, m);

        Test.startTest();
        DealTermReplyHandler.applyReply(opp.Id, '이상윤', 'C0DEAL1', null, 3.8, 0.2, 4.0, '근본캐피탈');
        Test.stopTest();

        Opportunity after = getOpp();
        Assert.areEqual(3.8, after.RP_Yield__c);
        Assert.areEqual(0.2, after.Fee_Rate__c);
        Assert.areEqual(4.0, after.Coupon_Rate__c);
        Assert.areEqual('근본캐피탈', after.Issuer_Name__c);
        Assert.areEqual('이상윤', after.Product_Team_Reply_By__c);
        Assert.isNotNull(after.Product_Team_Reply_At__c);
        Assert.isTrue(m.paths.contains('/chat.postMessage'), '새 카드 게시: ' + m.paths);
        Assert.isFalse(m.paths.contains('/chat.update'), 'ts 없으니 교체는 안 함');
        Assert.isTrue(after.Slack_Reply_Link__c.endsWith('/archives/C0DEAL1/p1700000000000100'), '게시된 메시지 링크: ' + after.Slack_Reply_Link__c);
    }

    @IsTest
    static void handle_nonOpportunityValue_isIgnored() {
        Mock m = new Mock();
        Test.setMock(HttpCalloutMock.class, m);

        Test.startTest();
        DealTermReplyHandler.handle(payload('SPIKE-TEST', '3.8', '4.0', '근본캐피탈'));
        Test.stopTest();

        Assert.isNull(getOpp().RP_Yield__c);
        Assert.areEqual(0, m.paths.size(), 'Slack 호출 없음');
    }

    /**
     * 게스트(Site Guest User) 경로: 표준 오브젝트 Edit 을 줄 수 없어 시스템 모드 DML 도 SecurityException 이 난다(2026-08-31 실측).
     * 그래서 게스트면 Boni_Slack_Event__e 를 발행하고, 트리거(Automated Process)가 Opportunity 를 갱신한다.
     * 카드 교체(chat.update)는 게스트 Worker 가 값을 직접 들고 수행한다.
     */
    @IsTest
    static void handle_asGuest_publishesEventAndTriggerAppliesValues() {
        Opportunity opp = getOpp();
        Mock m = new Mock();
        Test.setMock(HttpCalloutMock.class, m);
        DealTermReplyHandler.forceEventPath = true;

        Test.startTest();
        DealTermReplyHandler.handle(payload(String.valueOf(opp.Id), '3.8', '0.2', '4.0', '근본캐피탈'));
        Assert.isNull(getOpp().RP_Yield__c, '게스트 컨텍스트에서는 직접 DML 하지 않는다');
        Test.getEventBus().deliver();
        Test.stopTest();

        Opportunity after = getOpp();
        Assert.areEqual(3.8, after.RP_Yield__c, '트리거 경로로 갱신');
        Assert.areEqual(0.2, after.Fee_Rate__c);
        Assert.areEqual(4.0, after.Coupon_Rate__c);
        Assert.areEqual('근본캐피탈', after.Issuer_Name__c);
        Assert.areEqual('이주연', after.Product_Team_Reply_By__c);
        Assert.isNotNull(after.Product_Team_Reply_At__c);
        Assert.isTrue(after.Slack_Reply_Link__c.endsWith('/archives/C0DEAL1/p1700000000000100'), after.Slack_Reply_Link__c);
        Assert.isTrue(m.paths.contains('/chat.update'), '카드는 값을 들고 있는 Worker 가 교체: ' + m.paths);
    }

    /** 게스트는 Opportunity 를 조회할 수 없으므로(실측 QueryException), 원본 카드 블록을 변환해 조회 없이 교체한다. */
    @IsTest
    static void handle_withMessageBlocks_updatesCardWithoutQuery() {
        Opportunity opp = getOpp();
        Mock m = new Mock();
        Test.setMock(HttpCalloutMock.class, m);
        Map<String, Object> p = payload(String.valueOf(opp.Id), '3.8', '0.2', '4.0', '근본캐피탈');
        ((Map<String, Object>) p.get('message')).put('blocks', new List<Object>{
            new Map<String, Object>{ 'type' => 'header', 'text' => new Map<String, Object>{ 'type' => 'plain_text', 'text' => '조건 검토 요청' } },
            new Map<String, Object>{ 'type' => 'section', 'text' => new Map<String, Object>{ 'type' => 'mrkdwn', 'text' => ':moneybag: *수수료 조건*' } },
            new Map<String, Object>{ 'type' => 'section', 'text' => new Map<String, Object>{ 'type' => 'mrkdwn', 'text' => ':pencil2: *상품팀 회신* — 안내' } },
            new Map<String, Object>{ 'type' => 'input', 'block_id' => 'rp_yield' },
            new Map<String, Object>{ 'type' => 'actions', 'block_id' => 'deal_reply' }
        });

        Test.startTest();
        DealTermReplyHandler.handle(p);
        Test.stopTest();

        Assert.isTrue(m.paths.contains('/chat.update'), '카드 교체: ' + m.paths);
        Assert.isTrue(m.lastBody.contains('회신 완료'), m.lastBody);
        Assert.isTrue(m.lastBody.contains('3.8'), '값을 들고 그린다: ' + m.lastBody);
        Assert.isFalse(m.lastBody.contains('"input"'), '입력칸 제거: ' + m.lastBody);
        Assert.isFalse(m.lastBody.contains('deal_reply'), '버튼 제거: ' + m.lastBody);
        Assert.isFalse(m.lastBody.contains('상품팀 회신'), '안내 섹션 제거: ' + m.lastBody);
    }

    @IsTest
    static void applyFromEvent_updatesOpportunity() {
        Opportunity opp = getOpp();
        Map<String, Object> p = new Map<String, Object>{
            'oppId' => String.valueOf(opp.Id), 'replyBy' => '이주연', 'channelId' => 'C0DEAL1', 'ts' => '1700000000.000100',
            'yieldVal' => 3.8, 'appliedFeeVal' => 0.2, 'couponVal' => null, 'issuer' => ' 근본캐피탈 '
        };

        Test.startTest();
        DealTermReplyHandler.applyFromEvent(p);
        Test.stopTest();

        Opportunity after = getOpp();
        Assert.areEqual(3.8, after.RP_Yield__c);
        Assert.areEqual(0.2, after.Fee_Rate__c);
        Assert.isNull(after.Coupon_Rate__c, 'null 은 건너뜀');
        Assert.areEqual('근본캐피탈', after.Issuer_Name__c, 'trim');
        Assert.areEqual('이주연', after.Product_Team_Reply_By__c);
        Assert.isTrue(after.Slack_Reply_Link__c.endsWith('/archives/C0DEAL1/p1700000000000100'));
    }

    @IsTest
    static void eventHandler_routesDealTermApply() {
        Opportunity opp = getOpp();
        Boni_Slack_Event__e ev = new Boni_Slack_Event__e(
            Event_Type__c = DealTermReplyHandler.EVENT_APPLY,
            Payload__c = JSON.serialize(new Map<String, Object>{ 'oppId' => String.valueOf(opp.Id), 'replyBy' => '이주연',
                'channelId' => 'C0DEAL1', 'ts' => '1700000000.000100', 'yieldVal' => 3.8 })
        );

        Test.startTest();
        BoniSlackEventHandler.handle(new List<Boni_Slack_Event__e>{ ev });
        Test.stopTest();

        Assert.areEqual(3.8, getOpp().RP_Yield__c);
        Assert.areEqual('이주연', getOpp().Product_Team_Reply_By__c);
    }

    @IsTest
    static void eventHandler_routesDealTermReply() {
        Opportunity opp = getOpp();
        Mock m = new Mock();
        Test.setMock(HttpCalloutMock.class, m);
        Boni_Slack_Event__e ev = new Boni_Slack_Event__e(
            Event_Type__c = 'block_actions',
            Payload__c = JSON.serialize(payload(String.valueOf(opp.Id), '3.8', '4.0', '근본캐피탈'))
        );

        Test.startTest();
        BoniSlackEventHandler.handle(new List<Boni_Slack_Event__e>{ ev });
        Test.stopTest();

        Assert.areEqual(3.8, getOpp().RP_Yield__c);
    }
}