@isTest
private class DealApprovalPollerTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(Name = '폴러물산', Business_Registration_Number__c = '1112233449');
        insert acc;
        Product2 prod = new Product2(Name = 'RP', Family = 'RP', IsActive = true, Default_Fee_Rate__c = 0.15);
        insert prod;
        Opportunity opp = new Opportunity(Name = '폴러물산 - RP', AccountId = acc.Id, StageName = 'Prospecting',
            CloseDate = Date.today().addMonths(1), Amount = 1000000000L, Primary_Product__c = prod.Id,
            RP_Maturity_Date__c = Date.today().addMonths(3),
            Pending_Yield__c = 8.5, RP_Yield__c = 3.0, Slack_Channel_ID__c = 'C0POLLER1');
        insert opp;
        insert new Case(Opportunity__c = opp.Id, AccountId = acc.Id, OwnerId = UserInfo.getUserId(),
            Subject = '판매 승인 요청', Agreed_Yield_Rate__c = 8.5, Description = '상한 초과');
        // 확정 조건서 1부 — "(심사 완료)" 렌더링 대상
        insert new ContentVersion(Title = '폴러물산 - RP_RP_확정조건_20260902',
            PathOnClient = '폴러물산 - RP_RP_확정조건_20260902.pdf',
            VersionData = Blob.valueOf('PDF'), FirstPublishLocationId = opp.Id);
    }

    private static Opportunity theOpp() {
        return [SELECT Id, Slack_Channel_ID__c, RP_Yield__c, Pending_Yield__c FROM Opportunity LIMIT 1];
    }

    /** 엔드포인트별 응답 목 — conversations.info 는 지정한 토픽을 돌려준다. */
    private class SlackMock implements HttpCalloutMock {
        public List<String> paths = new List<String>();
        private final String topicValue;
        public SlackMock(String topicValue) { this.topicValue = topicValue; }
        public HttpResponse respond(HttpRequest req) {
            paths.add(req.getEndpoint());
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            if (req.getEndpoint().contains('/conversations.info')) {
                res.setBody(JSON.serialize(new Map<String, Object>{ 'ok' => true,
                    'channel' => new Map<String, Object>{ 'topic' => new Map<String, Object>{ 'value' => topicValue } } }));
            } else if (req.getEndpoint().contains('/files.getUploadURLExternal')) {
                res.setBody('{"ok":true,"upload_url":"https://files.example.com/up","file_id":"F0TEST"}');
            } else {
                res.setBody('{"ok":true,"ts":"1700000000.000200"}');
            }
            return res;
        }
    }

    private static String marker(Long clickedAt) {
        // Slack 이 저장한 형태를 흉내낸다: 이모지는 쇼트코드로 변환돼 돌아온다(2026-09-02 실측).
        return ':hourglass_flowing_sand: ' + DealApprovalHandler.TOPIC_MARKER_TEXT + '1700000000.000100/' + clickedAt + ')';
    }

    @isTest
    static void processOnePending_approvesAndPostsEverything() {
        SlackMock mock = new SlackMock(marker(System.currentTimeMillis() - 60000)); // 클릭 후 60초 경과
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        DealApprovalPoller.processOnePending();
        Test.stopTest();

        // 레코드: Case '승인' + 수익률 승격
        Assert.areEqual('승인', [SELECT Approval_Status__c FROM Case LIMIT 1].Approval_Status__c, 'Case 승인');
        Opportunity after = theOpp();
        Assert.areEqual(8.5, after.RP_Yield__c, 'Pending→RP 승격');
        Assert.isNull(after.Pending_Yield__c, 'Pending 비워짐');
        // Slack: 완료 카드 + 새 메시지 + PDF 업로드 완료 + 토픽 정리
        String all = String.join(mock.paths, ' ');
        Assert.isTrue(all.contains('/chat.update'), '완료 카드 교체');
        Assert.isTrue(all.contains('/chat.postMessage'), '새 메시지');
        Assert.isTrue(all.contains('/files.completeUploadExternal'), 'PDF 채널 공유');
        Assert.isTrue(all.contains('/conversations.setTopic'), '토픽 정리');
    }

    @isTest
    static void processOnePending_ignoresNonMarkerTopic() {
        SlackMock mock = new SlackMock('일반 토픽 문구');
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        DealApprovalPoller.processOnePending();
        Test.stopTest();

        Assert.areNotEqual('승인', [SELECT Approval_Status__c FROM Case LIMIT 1].Approval_Status__c, '표식 아니면 무시');
    }

    // start()/stopAll() 은 테스트하지 않는다 — CronTrigger 는 테스트에서 격리되지 않아
    // 테스트 실행이 실제 운영 중인 폴러 크론을 죽인다(2026-09-02). 폴 처리 본체 테스트만 유지한다.
}