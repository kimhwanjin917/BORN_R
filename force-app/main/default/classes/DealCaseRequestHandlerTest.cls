@IsTest
private class DealCaseRequestHandlerTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(Name = '근본물산', Business_Registration_Number__c = '1234567890');
        insert acc;
        insert new Opportunity(
            Name = '근본물산 - RP', AccountId = acc.Id, StageName = 'Prospecting',
            CloseDate = Date.today().addMonths(1), Amount = 5000000000L,
            RP_Yield__c = 3.8, Slack_Channel_ID__c = 'C0DEAL1'
        );
    }

    /** block_actions 페이로드 — [판매 승인 요청(Case 생성)] 클릭. */
    private static Map<String, Object> payload(String value, String termMonths, String reason) {
        return new Map<String, Object>{
            'type' => 'block_actions',
            'user' => new Map<String, Object>{ 'id' => 'UREP', 'username' => 'rep', 'name' => '이주연' },
            'channel' => new Map<String, Object>{ 'id' => 'C0DEAL1' },
            'message' => new Map<String, Object>{ 'ts' => '1700000000.000100' },
            'actions' => new List<Object>{ new Map<String, Object>{ 'action_id' => 'deal_case_create', 'value' => value } },
            'state' => new Map<String, Object>{ 'values' => new Map<String, Object>{
                'case_term_months' => new Map<String, Object>{ 'case_term_months_in' => new Map<String, Object>{ 'value' => termMonths } },
                'case_reason' => new Map<String, Object>{ 'case_reason_in' => new Map<String, Object>{ 'value' => reason } }
            } }
        };
    }

    private class Mock implements HttpCalloutMock {
        public List<String> paths = new List<String>();
        public HttpResponse respond(HttpRequest req) {
            paths.add(req.getEndpoint().substringAfterLast('/'));
            HttpResponse r = new HttpResponse();
            r.setStatusCode(200);
            r.setBody('{"ok":true,"ts":"1"}');
            return r;
        }
    }

    private static Id oppId() {
        return [SELECT Id FROM Opportunity LIMIT 1].Id;
    }

    private static List<Case> screeningCases() {
        return [SELECT Id, AccountId, Opportunity__c, OwnerId, Agreed_Yield_Rate__c, Contract_Term_Months__c,
                       Description, Subject, RecordType.DeveloperName
                FROM Case WHERE Opportunity__c = :oppId()];
    }

    @IsTest
    static void directCreate_buildsScreeningCaseFromOpportunityAndInputs() {
        Test.startTest();
        DealCaseRequestHandler.handle(payload(String.valueOf(oppId()), '12', '5% 초과 판매 승인 요청'));
        Test.stopTest();

        List<Case> cases = screeningCases();
        Assert.areEqual(1, cases.size(), '심사 Case 1건 생성');
        Case c = cases[0];
        // 심사 RT 는 실행 사용자에게 할당돼 있을 때만 설정된다(미할당이면 기본 RT). 가용할 때만 단언한다.
        Schema.RecordTypeInfo rt = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Screening');
        if (rt != null && rt.isAvailable()) {
            Assert.areEqual('Screening', c.RecordType.DeveloperName, '심사 레코드타입');
        }
        Assert.areEqual(oppId(), c.Opportunity__c, '영업기회 연결');
        Assert.areEqual(UserInfo.getUserId(), c.OwnerId, 'Owner = 영업기회 Owner(요청 RM)');
        Assert.areEqual(3.8, c.Agreed_Yield_Rate__c, '확정 약정수익률(RP_Yield__c) 복사');
        Assert.isTrue(c.Contract_Term_Months__c == 12, '입력 계약 기간: ' + c.Contract_Term_Months__c);
        Assert.areEqual('5% 초과 판매 승인 요청', c.Description, '입력 사유');
        Assert.isTrue(c.Subject.contains('근본물산'), 'Subject 에 법인명: ' + c.Subject);
        Assert.isNotNull(c.AccountId, '법인 연결');
    }

    @IsTest
    static void secondCall_updatesSameCase_noDuplicate() {
        DealCaseRequestHandler.handle(payload(String.valueOf(oppId()), '12', '첫 요청'));
        Test.startTest();
        DealCaseRequestHandler.handle(payload(String.valueOf(oppId()), '24', '조건 변경 재요청'));
        Test.stopTest();

        List<Case> cases = screeningCases();
        Assert.areEqual(1, cases.size(), '중복 생성하지 않고 갱신');
        Assert.isTrue(cases[0].Contract_Term_Months__c == 24, '계약 기간 갱신: ' + cases[0].Contract_Term_Months__c);
        Assert.areEqual('조건 변경 재요청', cases[0].Description, '사유 갱신');
    }

    @IsTest
    static void blankInputs_stillCreatesCaseWithOpportunityFields() {
        Test.startTest();
        DealCaseRequestHandler.handle(payload(String.valueOf(oppId()), '', ''));
        Test.stopTest();

        List<Case> cases = screeningCases();
        Assert.areEqual(1, cases.size(), '입력이 비어도 Case 는 생성');
        Assert.isNull(cases[0].Contract_Term_Months__c, '빈 계약기간은 저장 안 함');
        Assert.areEqual(3.8, cases[0].Agreed_Yield_Rate__c, '약정수익률은 기회에서 채움');
    }

    @IsTest
    static void pendingYield_usedWhenRpYieldIsNull() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        opp.RP_Yield__c = null;
        opp.Pending_Yield__c = 8.5;
        update opp;

        Test.startTest();
        DealCaseRequestHandler.handle(payload(String.valueOf(opp.Id), '12', '상한 초과'));
        Test.stopTest();

        List<Case> cases = screeningCases();
        Assert.areEqual(1, cases.size());
        Assert.areEqual(8.5, cases[0].Agreed_Yield_Rate__c, 'Pending_Yield__c 가 Case 에 반영돼야 한다');
    }

    @IsTest
    static void nonOpportunityValue_isIgnored() {
        Test.startTest();
        DealCaseRequestHandler.handle(payload('SPIKE-TEST', '12', '사유'));
        Test.stopTest();
        Assert.areEqual(0, screeningCases().size(), 'Opportunity Id 가 아니면 무시');
    }

    /** 게스트 경로: 직접 DML 하지 않고 이벤트 발행 → 트리거가 심사 Case 생성. */
    @IsTest
    static void asGuest_publishesEventAndTriggerCreatesCase() {
        DealCaseRequestHandler.forceEventPath = true;

        Test.startTest();
        DealCaseRequestHandler.handle(payload(String.valueOf(oppId()), '12', '게스트 요청'));
        Assert.areEqual(0, screeningCases().size(), '게스트 컨텍스트에서는 직접 DML 하지 않는다');
        Test.getEventBus().deliver();
        Test.stopTest();

        List<Case> cases = screeningCases();
        Assert.areEqual(1, cases.size(), '트리거 경로로 생성');
        Assert.isTrue(cases[0].Contract_Term_Months__c == 12, '계약 기간: ' + cases[0].Contract_Term_Months__c);
        Assert.areEqual('게스트 요청', cases[0].Description);
    }

    @IsTest
    static void createFromEvent_createsCase() {
        Map<String, Object> p = new Map<String, Object>{
            'oppId' => String.valueOf(oppId()), 'termMonths' => 18, 'reason' => '이벤트 직접'
        };
        Test.startTest();
        DealCaseRequestHandler.createFromEvent(p);
        Test.stopTest();

        List<Case> cases = screeningCases();
        Assert.areEqual(1, cases.size());
        Assert.isTrue(cases[0].Contract_Term_Months__c == 18, '계약 기간: ' + cases[0].Contract_Term_Months__c);
    }

    /** BoniSlackEventHandler 라우팅: block_actions → Case 생성 + 확인 메시지(콜아웃). */
    @IsTest
    static void eventHandler_routesCaseCreateAction() {
        Mock m = new Mock();
        Test.setMock(HttpCalloutMock.class, m);
        Boni_Slack_Event__e ev = new Boni_Slack_Event__e(
            Event_Type__c = 'block_actions',
            Payload__c = JSON.serialize(payload(String.valueOf(oppId()), '12', '라우팅 사유'))
        );

        Test.startTest();
        BoniSlackEventHandler.handle(new List<Boni_Slack_Event__e>{ ev });
        Test.stopTest();

        Assert.areEqual(1, screeningCases().size(), '버튼 라우팅으로 Case 생성');
        Assert.isTrue(m.paths.contains('chat.postEphemeral') || m.paths.contains('chat.postMessage'), '확인 메시지 게시: ' + m.paths);
    }

    /** BoniSlackEventHandler 라우팅: EVENT_CREATE 이벤트 → createFromEvent. */
    @IsTest
    static void eventHandler_routesCreateEvent() {
        Boni_Slack_Event__e ev = new Boni_Slack_Event__e(
            Event_Type__c = DealCaseRequestHandler.EVENT_CREATE,
            Payload__c = JSON.serialize(new Map<String, Object>{ 'oppId' => String.valueOf(oppId()), 'termMonths' => 6, 'reason' => '이벤트 라우팅' })
        );

        Test.startTest();
        BoniSlackEventHandler.handle(new List<Boni_Slack_Event__e>{ ev });
        Test.stopTest();

        Assert.areEqual(1, screeningCases().size());
        Assert.isTrue(screeningCases()[0].Contract_Term_Months__c == 6, '계약 기간: ' + screeningCases()[0].Contract_Term_Months__c);
    }
}