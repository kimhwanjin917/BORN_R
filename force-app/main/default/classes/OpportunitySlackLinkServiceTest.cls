/**
 * OpportunitySlackLinkService 테스트. Slack 호출은 HttpCalloutMock. DML 없이 Opportunity Id 만 필요하므로
 * 테스트 데이터는 @TestSetup 에서 직접 생성(TestDataFactory 미사용).
 */
@IsTest
private class OpportunitySlackLinkServiceTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(Name = '링크테스트 주식회사', Business_Registration_Number__c = '9998877777');
        insert acc;
        insert new Opportunity(Name = '링크테스트 - RP', AccountId = acc.Id, StageName = '미팅', CloseDate = Date.today().addDays(30));
    }

    private static Id oppId() {
        return [SELECT Id FROM Opportunity LIMIT 1].Id;
    }

    private class LinkMock implements HttpCalloutMock {
        public String endpoint;
        public String body;
        public Integer status = 200;
        public String responseBody = '{"ok":true}';
        public HttpResponse respond(HttpRequest req) {
            endpoint = req.getEndpoint();
            body = req.getBody();
            HttpResponse res = new HttpResponse();
            res.setStatusCode(status);
            res.setBody(responseBody);
            return res;
        }
    }

    @IsTest
    static void linkSuccess_callsAdminEndpointWithRecordAndOrg() {
        LinkMock mock = new LinkMock();
        Test.setMock(HttpCalloutMock.class, mock);
        Id opp = oppId();

        Test.startTest();
        Boolean ok = OpportunitySlackLinkService.link('C0LINK1', opp);
        Test.stopTest();

        Assert.isTrue(ok, '정상 응답이면 true');
        Assert.isTrue(mock.endpoint.startsWith('callout:Slack_Admin/admin.conversations.linkObjects'), '관리자 Named Credential 로 linkObjects 호출: ' + mock.endpoint);
        Map<String, Object> sent = (Map<String, Object>) JSON.deserializeUntyped(mock.body);
        Assert.areEqual('C0LINK1', sent.get('channel'));
        Assert.areEqual(String.valueOf(opp), sent.get('record_id'), '18자리 레코드 Id');
        Assert.areEqual(String.valueOf(UserInfo.getOrganizationId()), sent.get('salesforce_org_id'), '현재 org Id');
        Assert.isNull(OpportunitySlackLinkService.lastError);
    }

    @IsTest
    static void alreadyLinked_isTreatedAsSuccess() {
        LinkMock mock = new LinkMock();
        mock.responseBody = '{"ok":false,"error":"record_channel_already_exists"}';
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        Boolean ok = OpportunitySlackLinkService.link('C0LINK1', oppId());
        Test.stopTest();

        Assert.isTrue(ok, '이미 연결된 경우도 성공으로 본다');
    }

    @IsTest
    static void slackError_returnsFalseWithoutThrowing() {
        LinkMock mock = new LinkMock();
        mock.responseBody = '{"ok":false,"error":"not_allowed_token_type"}';
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        Boolean ok = OpportunitySlackLinkService.link('C0LINK1', oppId());
        Test.stopTest();

        Assert.isFalse(ok);
        Assert.areEqual('not_allowed_token_type', OpportunitySlackLinkService.lastError);
    }

    @IsTest
    static void httpError_returnsFalse() {
        LinkMock mock = new LinkMock();
        mock.status = 500;
        mock.responseBody = 'boom';
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        Boolean ok = OpportunitySlackLinkService.link('C0LINK1', oppId());
        Test.stopTest();

        Assert.isFalse(ok);
        Assert.areEqual('http_500', OpportunitySlackLinkService.lastError);
    }

    @IsTest
    static void missingArguments_returnsFalseWithoutCallout() {
        LinkMock mock = new LinkMock();
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        Boolean ok = OpportunitySlackLinkService.link('', oppId());
        Test.stopTest();

        Assert.isFalse(ok);
        Assert.isNull(mock.endpoint, '콜아웃 안 나감');
        Assert.areEqual('missing_arguments', OpportunitySlackLinkService.lastError);
    }
}