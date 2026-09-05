/**
 * DealApprovalService 테스트 (Scene 3 · CASE B 딸깍①②).
 * TestDataFactory(팀 동결)는 쓰지 않고 이 클래스 @TestSetup 으로 데이터를 만든다.
 * Slack 콜아웃은 SlackMock(다중 엔드포인트)으로 대체. 승인은 org 의 Deal_Manager_Approval 프로세스를 그대로 탄다.
 */
@IsTest
private class DealApprovalServiceTest {

    private static final String PDF_TITLE = '테스트딜_RP_확정조건_20260901'; // findLatestTermPdfId 패턴 포함

    @TestSetup
    static void setup() {
        // 이 org 의 검증 규칙상 Account 는 Industry + 사업자등록번호가 필수(RpTermConfirmControllerTest 주석 참고).
        Account acc = new Account(Name = '테스트딜상대', Industry = '금융', Business_Registration_Number__c = '1234567890');
        insert acc;
        // 딸깍① 용 Case(대기)
        Opportunity opp1 = new Opportunity(
            Name = '테스트딜', StageName = 'Prospecting', CloseDate = Date.today().addDays(30), AccountId = acc.Id
        );
        insert opp1;
        insert new Case(Subject = '수수료 검토', Opportunity__c = opp1.Id, Status = 'New');
        // 딸깍② 용 Case(이미 승인 — @TestSetup 에서 커밋되므로, 테스트 메서드에서 DML 없이 콜아웃 가능)
        Opportunity opp2 = new Opportunity(
            Name = '테스트딜2', StageName = 'Prospecting', CloseDate = Date.today().addDays(30), AccountId = acc.Id
        );
        insert opp2;
        insert new Case(Subject = '수수료 검토2', Opportunity__c = opp2.Id, Status = 'New',
            Approval_Status__c = DealApprovalHandler.STATUS_APPROVED);
        insert new ContentVersion(Title = PDF_TITLE, PathOnClient = PDF_TITLE + '.pdf',
            VersionData = Blob.valueOf('PDF-BYTES'), FirstPublishLocationId = opp2.Id); // opp2 에 확정조건서
    }

    private static Case theCase() {
        return [SELECT Id, Opportunity__c, Deal_Slack_Channel__c, Approval_Status__c FROM Case WHERE Subject = '수수료 검토' LIMIT 1];
    }

    private static Case approvedCase() {
        return [SELECT Id, Opportunity__c, Approval_Status__c FROM Case WHERE Subject = '수수료 검토2' LIMIT 1];
    }

    private static void attachTermPdf(Id oppId) {
        insert new ContentVersion(
            Title = PDF_TITLE, PathOnClient = PDF_TITLE + '.pdf',
            VersionData = Blob.valueOf('PDF-BYTES'), FirstPublishLocationId = oppId
        );
    }

    // ── 딸깍① ───────────────────────────────────────────────────────────

    @IsTest
    static void requestManagerApproval_createsChannel_sharesPdf_postsCard_submits() {
        Case cse = theCase();
        attachTermPdf(cse.Opportunity__c);
        SlackMock mock = new SlackMock();

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, mock);
        DealApprovalService.Result r = DealApprovalService.requestManagerApproval(cse.Id);
        Test.stopTest();

        System.assert(r.success, '승인 요청이 성공해야 한다. 실제 메시지=' + r.message);
        System.assert(mock.createCount == 1, '채널 생성 1회. 실제=' + mock.createCount);
        System.assert(mock.postMessageCount >= 1, '승인 카드 게시 1회 이상. 실제=' + mock.postMessageCount);
        System.assert(mock.uploadUrlCount == 1, 'PDF 첨부(업로드 URL) 1회. 실제=' + mock.uploadUrlCount);

        Case after1 = theCase();
        System.assertNotEquals(null, after1.Deal_Slack_Channel__c, '생성된 채널 id 가 Case 에 저장되어야 한다.');
        System.assertEquals(DealApprovalHandler.STATUS_REQUESTED, after1.Approval_Status__c, '상태가 승인요청이어야 한다.');
    }

    @IsTest
    static void requestManagerApproval_noPdf_stillPostsCardAndSubmits() {
        Case cse = theCase();
        SlackMock mock = new SlackMock();

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, mock);
        DealApprovalService.Result r = DealApprovalService.requestManagerApproval(cse.Id);
        Test.stopTest();

        System.assert(r.success, 'PDF 가 없어도 성공해야 한다. 실제=' + r.message);
        System.assertEquals(0, mock.uploadUrlCount, 'PDF 가 없으면 업로드 콜아웃이 없어야 한다.');
        System.assert(mock.postMessageCount >= 1, '카드는 게시되어야 한다.');
    }

    @IsTest
    static void requestManagerApproval_reusesExistingChannel_noCreate() {
        Case cse = theCase();
        update new Case(Id = cse.Id, Deal_Slack_Channel__c = 'C_EXISTING');
        SlackMock mock = new SlackMock();

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, mock);
        DealApprovalService.Result r = DealApprovalService.requestManagerApproval(cse.Id);
        Test.stopTest();

        System.assert(r.success, r.message);
        System.assertEquals(0, mock.createCount, '이미 채널이 있으면 새로 만들지 않는다.');
        System.assertEquals('C_EXISTING', r.channelId, '기존 채널을 그대로 쓴다.');
    }

    @IsTest
    static void requestManagerApproval_nullOrNoOpp_returnsFailure() {
        // null caseId
        DealApprovalService.Result r1 = DealApprovalService.requestManagerApproval(null);
        System.assert(!r1.success, 'null caseId 는 실패여야 한다.');

        // Opportunity 미연결 Case
        Case orphan = new Case(Subject = '무연결', Status = 'New');
        insert orphan;
        DealApprovalService.Result r2 = DealApprovalService.requestManagerApproval(orphan.Id);
        System.assert(!r2.success, 'Opportunity 미연결 Case 는 실패여야 한다.');
    }

    // ── 딸깍② ───────────────────────────────────────────────────────────

    @IsTest
    static void sendResultToRM_afterApproved_dmsRmAndSharesPdf() {
        // 이미 승인된 Case(@TestSetup 커밋본) — 메서드 내 선행 DML 없이 콜아웃만 수행(실제 딸깍②는 별도 트랜잭션).
        Case cse = approvedCase();
        SlackMock mock = new SlackMock();

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, mock);
        DealApprovalService.Result r = DealApprovalService.sendResultToRM(cse.Id);
        Test.stopTest();

        System.assert(r.success, 'RM 전달이 성공해야 한다. 실제=' + r.message);
        System.assert(mock.openDmCount >= 1, 'RM DM 채널을 열어야 한다. 실제=' + mock.openDmCount);
        System.assert(mock.uploadUrlCount == 1, '확정조건서 PDF 도 전달되어야 한다. 실제=' + mock.uploadUrlCount);
    }

    @IsTest
    static void sendResultToRM_notApproved_returnsFailure() {
        Case cse = theCase(); // 기본 상태(대기)
        SlackMock mock = new SlackMock();

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, mock);
        DealApprovalService.Result r = DealApprovalService.sendResultToRM(cse.Id);
        Test.stopTest();

        System.assert(!r.success, '승인 전에는 RM 전달이 실패여야 한다.');
        System.assertEquals(0, mock.openDmCount, '승인 전에는 콜아웃이 없어야 한다.');
    }

    // ── 카드 블록 ─────────────────────────────────────────────────────────

    @IsTest
    static void buildApprovalCardBlocks_hasDecisionButtonsWithOppValue() {
        Case cse = theCase();
        Case full = [SELECT Id, CaseNumber, Opportunity__c, Opportunity__r.Name FROM Case WHERE Id = :cse.Id];

        Test.startTest();
        List<Object> blocks = DealApprovalService.buildApprovalCardBlocks(full, true);
        Test.stopTest();

        Boolean approve = false, reject = false;
        String oppVal = String.valueOf(cse.Opportunity__c);
        for (Object o : blocks) {
            Map<String, Object> b = (Map<String, Object>) o;
            if (b.get('type') == 'actions') {
                for (Object el : (List<Object>) b.get('elements')) {
                    Map<String, Object> e = (Map<String, Object>) el;
                    String aid = String.valueOf(e.get('action_id'));
                    if (aid == OpportunityDealChannelService.ACTION_APPROVAL_APPROVE) {
                        approve = true;
                        System.assertEquals(oppVal, String.valueOf(e.get('value')), '승인 버튼 value 는 Opportunity Id 여야 한다(기존 라우팅 재사용).');
                    }
                    if (aid == OpportunityDealChannelService.ACTION_APPROVAL_REJECT) { reject = true; }
                }
            }
        }
        System.assert(approve && reject, '[승인]/[반려] 버튼이 있어야 한다.');
    }

    // ── Slack 다중 엔드포인트 목 ─────────────────────────────────────────

    private class SlackMock implements HttpCalloutMock {
        Integer createCount = 0, lookupCount = 0, inviteCount = 0, postMessageCount = 0, openDmCount = 0, uploadUrlCount = 0;

        public HttpResponse respond(HttpRequest req) {
            String url = req.getEndpoint();
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');

            if (url.contains('/conversations.create')) {
                createCount++;
                res.setBody('{"ok":true,"channel":{"id":"C_NEW_APPROVAL"}}');
            } else if (url.contains('/users.lookupByEmail')) {
                lookupCount++;
                res.setBody('{"ok":true,"user":{"id":"U123"}}');
            } else if (url.contains('/conversations.invite')) {
                inviteCount++;
                res.setBody('{"ok":true}');
            } else if (url.contains('/conversations.setPurpose')) {
                res.setBody('{"ok":true}');
            } else if (url.contains('/conversations.open')) {
                openDmCount++;
                res.setBody('{"ok":true,"channel":{"id":"D_DM_RM"}}');
            } else if (url.contains('/chat.postMessage')) {
                postMessageCount++;
                res.setBody('{"ok":true,"ts":"1725000000.000100"}');
            } else if (url.contains('/files.getUploadURLExternal')) {
                uploadUrlCount++;
                res.setBody('{"ok":true,"upload_url":"https://files.slack.com/upload/test","file_id":"F123"}');
            } else if (url.contains('files.slack.com/upload')) {
                res.setBody('OK');
            } else if (url.contains('/files.completeUploadExternal')) {
                res.setBody('{"ok":true,"files":[{"id":"F123"}]}');
            } else {
                res.setBody('{"ok":true}');
            }
            return res;
        }
    }
}