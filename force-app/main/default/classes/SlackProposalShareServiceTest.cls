/**
 * SlackProposalShareService 테스트.
 * Slack 호출(callout:Slack 및 files.slack.com 업로드 URL)은 전부 HttpCalloutMock 으로 대체한다.
 * 테스트 데이터는 이 클래스의 @TestSetup 에서 직접 만든다 (팀 공용 TestDataFactory 는 동결 파일이라 사용하지 않음).
 */
@IsTest
private class SlackProposalShareServiceTest {

    private static final String CHANNEL_ID = 'C0PROPOSAL1';
    private static final String LEAD_WITH_CHANNEL_COMPANY = 'Proposal Target Co.';
    private static final String LEAD_WITHOUT_CHANNEL_COMPANY = 'No Channel Inc';
    private static final String FILE_NAME_1 = 'RP_상품소개서.pdf';
    private static final String FILE_NAME_2 = 'company_brief.pptx';
    private static final String PROPOSAL_TEXT = '안녕하세요, RP 상품을 제안드립니다.';
    private static final String UPLOAD_URL_BASE = 'https://files.slack.com/upload/v1/';

    private static final String TEST_USER_USERNAME = 'slack.proposal.share.test@newborn.example.com';
    private static final String PERMISSION_SET_NAME = 'Slack_Lead_Channel';
    private static final String TEST_PROFILE_NAME = 'Standard User';

    /**
     * 실제 영업 사용자와 같은 조건(Standard User + Slack_Lead_Channel 권한 집합)의 테스트 유저로
     * Lead 와 첨부파일을 만든다. (User 와 Lead 는 MIXED_DML 방지를 위해 runAs 블록 분리)
     */
    @TestSetup
    static void setupTestData() {
        User testUser;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            testUser = buildTestUser();
            insert testUser;
            PermissionSet permissionSet = [SELECT Id FROM PermissionSet WHERE Name = :PERMISSION_SET_NAME LIMIT 1];
            insert new PermissionSetAssignment(AssigneeId = testUser.Id, PermissionSetId = permissionSet.Id);
        }
        System.runAs(testUser) {
            Lead leadWithChannel = new Lead(LastName = '제안고객', name_new__c = '제안고객', Company = LEAD_WITH_CHANNEL_COMPANY,
                Email = 'proposal@example.com', Slack_Channel_ID__c = CHANNEL_ID,
                Slack_Channel_Link__c = 'https://slack-demo-39110.enterprise.slack.com/archives/' + CHANNEL_ID);
            Lead leadWithoutChannel = new Lead(LastName = '채널없음', name_new__c = '채널없음', Company = LEAD_WITHOUT_CHANNEL_COMPANY);
            insert new List<Lead>{ leadWithChannel, leadWithoutChannel };

            List<ContentVersion> versions = new List<ContentVersion>{
                new ContentVersion(Title = 'RP_상품소개서', PathOnClient = FILE_NAME_1,
                    VersionData = Blob.valueOf('PDF-BYTES-1')),
                new ContentVersion(Title = 'company_brief', PathOnClient = FILE_NAME_2,
                    VersionData = Blob.valueOf('PPTX-BYTES-2'))
            };
            insert versions;
            List<ContentDocumentLink> links = new List<ContentDocumentLink>();
            for (ContentVersion version : [SELECT ContentDocumentId FROM ContentVersion WHERE Id IN :versions]) {
                links.add(new ContentDocumentLink(ContentDocumentId = version.ContentDocumentId,
                    LinkedEntityId = leadWithChannel.Id, ShareType = 'V', Visibility = 'AllUsers'));
            }
            insert links;
        }
    }

    private static User buildTestUser() {
        Profile standardProfile = [SELECT Id FROM Profile WHERE Name = :TEST_PROFILE_NAME LIMIT 1];
        return new User(
            FirstName = 'Proposal',
            LastName = 'Tester',
            Alias = 'proptst',
            Email = 'proposal.tester@example.com',
            Username = TEST_USER_USERNAME,
            ProfileId = standardProfile.Id,
            TimeZoneSidKey = 'Asia/Seoul',
            LocaleSidKey = 'ko_KR',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'ko'
        );
    }

    private static User getTestUser() {
        return [SELECT Id FROM User WHERE Username = :TEST_USER_USERNAME LIMIT 1];
    }

    private static Lead getLeadByCompany(String company) {
        return [SELECT Id, Slack_Channel_ID__c FROM Lead WHERE Company = :company LIMIT 1];
    }

    private static SlackProposalShareService.Request buildRequest(Id leadId, String messageText) {
        SlackProposalShareService.Request request = new SlackProposalShareService.Request();
        request.leadId = leadId;
        request.messageText = messageText;
        return request;
    }

    private static List<SlackProposalShareService.Response> callService(SlackProposalShareService.Request request) {
        Test.startTest();
        List<SlackProposalShareService.Response> responses =
            SlackProposalShareService.shareProposal(new List<SlackProposalShareService.Request>{ request });
        Test.stopTest();
        return responses;
    }

    // ─── Happy path ──────────────────────────────────────────────────────

    @IsTest
    static void shouldPostMessageAndShareAllFiles_WhenLeadHasChannelAndFiles() {
        // Given
        Lead lead = getLeadByCompany(LEAD_WITH_CHANNEL_COMPANY);
        SlackApiMock mock = new SlackApiMock();
        Test.setMock(HttpCalloutMock.class, mock);

        // When
        List<SlackProposalShareService.Response> responses;
        System.runAs(getTestUser()) {
            responses = callService(buildRequest(lead.Id, PROPOSAL_TEXT));
        }

        // Then
        Assert.areEqual(1, responses.size(), '요청 1건당 응답 1건');
        SlackProposalShareService.Response response = responses[0];
        Assert.isTrue(response.isSuccess, '성공. 오류: ' + response.errorMessage);
        Assert.isTrue(response.messagePosted, '메시지 게시됨');
        Assert.areEqual(CHANNEL_ID, response.channelId, '채널 ID 반환');
        Assert.areEqual(2, response.sharedFileCount, '파일 2개 공유');
        Assert.isTrue(response.allFilesShared, '건너뛴 파일 없음');
        Assert.isTrue(String.isBlank(response.skippedFiles), 'skippedFiles 비어 있음');
        Assert.isTrue(response.sharedFiles.contains(FILE_NAME_1) && response.sharedFiles.contains(FILE_NAME_2),
            '공유 파일명 2개 포함. 실제: ' + response.sharedFiles);
        Assert.isNull(response.errorMessage, '오류 없음');

        // 호출 순서/횟수: postMessage 1 + (getUploadURL + upload + complete) × 2
        Assert.areEqual(1, mock.countOf('/chat.postMessage'), 'chat.postMessage 1회');
        Assert.areEqual(2, mock.countOf('/files.getUploadURLExternal'), 'getUploadURLExternal 2회');
        Assert.areEqual(2, mock.uploadCallCount, '업로드 URL POST 2회');
        Assert.areEqual(2, mock.countOf('/files.completeUploadExternal'), 'completeUploadExternal 2회');

        // 메시지 본문/채널 확인
        Map<String, Object> postBody = (Map<String, Object>) JSON.deserializeUntyped(mock.lastPostMessageBody);
        Assert.areEqual(CHANNEL_ID, postBody.get('channel'), '채널 ID 로 게시');
        Assert.areEqual(PROPOSAL_TEXT, postBody.get('text'), '제안 본문 그대로 게시');

        // complete 호출에 channel_id 와 file_id 가 들어갔는지
        Map<String, Object> completeBody = (Map<String, Object>) JSON.deserializeUntyped(mock.lastCompleteBody);
        Assert.areEqual(CHANNEL_ID, completeBody.get('channel_id'), 'completeUploadExternal 에 channel_id');
        List<Object> files = (List<Object>) completeBody.get('files');
        Assert.areEqual(1, files.size(), '파일 1건씩 완료 호출');
        Assert.isTrue(String.valueOf(((Map<String, Object>) files[0]).get('id')).startsWith('F0MOCK'), 'file_id 전달');

        // getUploadURLExternal 쿼리에 파일명/길이
        Assert.isTrue(mock.uploadUrlQueries[0].contains('filename=') && mock.uploadUrlQueries[0].contains('length='),
            'filename/length 쿼리. 실제: ' + mock.uploadUrlQueries[0]);
    }

    @IsTest
    static void shouldPostMessageOnly_WhenShareFilesFalse() {
        // Given
        Lead lead = getLeadByCompany(LEAD_WITH_CHANNEL_COMPANY);
        SlackApiMock mock = new SlackApiMock();
        Test.setMock(HttpCalloutMock.class, mock);
        SlackProposalShareService.Request request = buildRequest(lead.Id, PROPOSAL_TEXT);
        request.shareFiles = false;

        // When
        SlackProposalShareService.Response response = callService(request)[0];

        // Then
        Assert.isTrue(response.isSuccess, '성공');
        Assert.isTrue(response.messagePosted, '메시지 게시됨');
        Assert.areEqual(0, response.sharedFileCount, '파일 공유 안 함');
        Assert.isTrue(response.allFilesShared, '건너뛴 파일 없음');
        Assert.areEqual(0, mock.countOf('/files.getUploadURLExternal'), '파일 API 미호출');
    }

    @IsTest
    static void shouldSucceedWithZeroFiles_WhenLeadHasNoAttachments() {
        // Given: 채널은 있지만 파일은 없는 Lead
        Lead lead = getLeadByCompany(LEAD_WITHOUT_CHANNEL_COMPANY);
        lead.Slack_Channel_ID__c = 'C0NOFILES1';
        update lead;
        SlackApiMock mock = new SlackApiMock();
        Test.setMock(HttpCalloutMock.class, mock);

        // When
        SlackProposalShareService.Response response = callService(buildRequest(lead.Id, PROPOSAL_TEXT))[0];

        // Then
        Assert.isTrue(response.isSuccess, '성공');
        Assert.areEqual(0, response.sharedFileCount, '파일 0개');
        Assert.isTrue(response.allFilesShared, '파일 0개여도 allFilesShared true');
        Assert.isTrue(String.isBlank(response.sharedFiles), 'sharedFiles 비어 있음');
    }

    // ─── Validation ──────────────────────────────────────────────────────

    @IsTest
    static void shouldFail_WhenLeadHasNoChannel() {
        // Given
        Lead lead = getLeadByCompany(LEAD_WITHOUT_CHANNEL_COMPANY);
        SlackApiMock mock = new SlackApiMock();
        Test.setMock(HttpCalloutMock.class, mock);

        // When
        SlackProposalShareService.Response response = callService(buildRequest(lead.Id, PROPOSAL_TEXT))[0];

        // Then
        Assert.isFalse(response.isSuccess, '실패');
        Assert.areEqual('NO_CHANNEL', response.errorType, '채널 없음 오류 유형');
        Assert.isTrue(response.errorMessage.contains('Slack 채널이 없습니다'), '안내 메시지. 실제: ' + response.errorMessage);
        Assert.areEqual(0, mock.calledPaths.size(), 'Slack 호출 없음');
    }

    @IsTest
    static void shouldFail_WhenMessageTextBlank() {
        // Given
        Lead lead = getLeadByCompany(LEAD_WITH_CHANNEL_COMPANY);
        Test.setMock(HttpCalloutMock.class, new SlackApiMock());

        // When
        SlackProposalShareService.Response response = callService(buildRequest(lead.Id, '   '))[0];

        // Then
        Assert.isFalse(response.isSuccess, '실패');
        Assert.areEqual('VALIDATION', response.errorType, '검증 오류');
        Assert.isTrue(response.errorMessage.contains('제안 메시지가 비어'), '안내 메시지. 실제: ' + response.errorMessage);
    }

    @IsTest
    static void shouldFail_WhenLeadIdNullOrNotFound() {
        // Given
        Test.setMock(HttpCalloutMock.class, new SlackApiMock());
        SlackProposalShareService.Request nullRequest = buildRequest(null, PROPOSAL_TEXT);
        Id fakeLeadId = Lead.SObjectType.getDescribe().getKeyPrefix() + '000000000001AAA';
        SlackProposalShareService.Request missingRequest = buildRequest(fakeLeadId, PROPOSAL_TEXT);

        // When
        Test.startTest();
        List<SlackProposalShareService.Response> responses = SlackProposalShareService.shareProposal(
            new List<SlackProposalShareService.Request>{ nullRequest, missingRequest });
        Test.stopTest();

        // Then
        Assert.areEqual(2, responses.size(), '요청 순서대로 응답 2건');
        Assert.isFalse(responses[0].isSuccess, 'null leadId 실패');
        Assert.areEqual('VALIDATION', responses[0].errorType, 'null → VALIDATION');
        Assert.isFalse(responses[1].isSuccess, '없는 Lead 실패');
        Assert.areEqual('NOT_FOUND', responses[1].errorType, '없는 Lead → NOT_FOUND');
    }

    @IsTest
    static void shouldReturnEmptyList_WhenNoRequests() {
        Assert.isTrue(SlackProposalShareService.shareProposal(null).isEmpty(), 'null → 빈 응답');
        Assert.isTrue(SlackProposalShareService.shareProposal(new List<SlackProposalShareService.Request>()).isEmpty(), '빈 목록 → 빈 응답');
    }

    // ─── Slack error handling ────────────────────────────────────────────

    @IsTest
    static void shouldFailAndSkipFiles_WhenPostMessageFails() {
        // Given
        Lead lead = getLeadByCompany(LEAD_WITH_CHANNEL_COMPANY);
        SlackApiMock mock = new SlackApiMock();
        mock.failPostMessageWith = 'not_in_channel';
        Test.setMock(HttpCalloutMock.class, mock);

        // When
        SlackProposalShareService.Response response = callService(buildRequest(lead.Id, PROPOSAL_TEXT))[0];

        // Then
        Assert.isFalse(response.isSuccess, '메시지 실패 → 전체 실패');
        Assert.isFalse(response.messagePosted, '메시지 미게시');
        Assert.areEqual('not_in_channel', response.errorType, 'Slack 오류 코드 보존');
        Assert.isTrue(response.errorMessage.contains('제안 메시지 게시 실패'), '오류 메시지. 실제: ' + response.errorMessage);
        Assert.areEqual(0, mock.countOf('/files.getUploadURLExternal'), '메시지 실패 시 파일 업로드 시도 안 함');
    }

    @IsTest
    static void shouldReportMissingScope_WhenGetUploadUrlFails() {
        // Given
        Lead lead = getLeadByCompany(LEAD_WITH_CHANNEL_COMPANY);
        SlackApiMock mock = new SlackApiMock();
        mock.failUploadUrlWith = 'missing_scope';
        Test.setMock(HttpCalloutMock.class, mock);

        // When
        SlackProposalShareService.Response response = callService(buildRequest(lead.Id, PROPOSAL_TEXT))[0];

        // Then
        Assert.isTrue(response.isSuccess, '메시지는 게시되었으므로 isSuccess true');
        Assert.isTrue(response.messagePosted, '메시지 게시됨');
        Assert.areEqual(0, response.sharedFileCount, '파일 0개 공유');
        Assert.isFalse(response.allFilesShared, '파일 실패 있음');
        Assert.areEqual('FILE_PARTIAL', response.errorType, '파일 부분 실패 유형');
        Assert.isTrue(response.skippedFiles.contains('files:write'), 'missing_scope 안내에 needed scope 포함. 실제: ' + response.skippedFiles);
        Assert.isTrue(response.skippedFiles.contains(FILE_NAME_1) && response.skippedFiles.contains(FILE_NAME_2),
            '두 파일 모두 건너뜀 목록에. 실제: ' + response.skippedFiles);
    }

    @IsTest
    static void shouldSkipOnlyFailedFile_WhenUploadHttpFailsForOne() {
        // Given: 두 번째 파일 업로드만 HTTP 500
        Lead lead = getLeadByCompany(LEAD_WITH_CHANNEL_COMPANY);
        SlackApiMock mock = new SlackApiMock();
        mock.failUploadOnCall = 2;
        Test.setMock(HttpCalloutMock.class, mock);

        // When
        SlackProposalShareService.Response response = callService(buildRequest(lead.Id, PROPOSAL_TEXT))[0];

        // Then
        Assert.isTrue(response.isSuccess, '메시지 게시 성공');
        Assert.areEqual(1, response.sharedFileCount, '파일 1개만 공유');
        Assert.isFalse(response.allFilesShared, '부분 실패');
        Assert.isTrue(response.skippedFiles.contains('HTTP 500'), '업로드 HTTP 오류 사유. 실제: ' + response.skippedFiles);
        Assert.areEqual(1, mock.countOf('/files.completeUploadExternal'), '성공한 파일만 complete 호출');
    }

    @IsTest
    static void shouldSkipFile_WhenCompleteUploadFails() {
        // Given
        Lead lead = getLeadByCompany(LEAD_WITH_CHANNEL_COMPANY);
        SlackApiMock mock = new SlackApiMock();
        mock.failCompleteWith = 'channel_not_found';
        Test.setMock(HttpCalloutMock.class, mock);

        // When
        SlackProposalShareService.Response response = callService(buildRequest(lead.Id, PROPOSAL_TEXT))[0];

        // Then
        Assert.isTrue(response.isSuccess, '메시지 게시 성공');
        Assert.areEqual(0, response.sharedFileCount, '파일 공유 0건');
        Assert.isTrue(response.skippedFiles.contains('channel_not_found'), '완료 단계 오류 사유. 실제: ' + response.skippedFiles);
    }

    @IsTest
    static void shouldFail_WhenSlackReturnsHttpError() {
        // Given
        Lead lead = getLeadByCompany(LEAD_WITH_CHANNEL_COMPANY);
        SlackApiMock mock = new SlackApiMock();
        mock.httpStatusOverride = 503;
        Test.setMock(HttpCalloutMock.class, mock);

        // When
        SlackProposalShareService.Response response = callService(buildRequest(lead.Id, PROPOSAL_TEXT))[0];

        // Then
        Assert.isFalse(response.isSuccess, 'HTTP 오류 → 실패');
        Assert.areEqual('HTTP_503', response.errorType, 'HTTP 상태 코드 보존');
    }

    @IsTest
    static void shouldSkipOversizedFile_WithoutCallingUploadApi() {
        // Given: 테스트용으로 상한을 12바이트로 낮추고(기존 테스트 파일은 11·12바이트), 13바이트 파일을 Lead 에 붙인다
        Lead lead = getLeadByCompany(LEAD_WITH_CHANNEL_COMPANY);
        SlackProposalShareService.maxFileBytes = 12;
        System.runAs(getTestUser()) {
            ContentVersion bigVersion = new ContentVersion(Title = 'big', PathOnClient = 'big.bin',
                VersionData = Blob.valueOf('1234567890123'));
            insert bigVersion;
            Id docId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :bigVersion.Id].ContentDocumentId;
            insert new ContentDocumentLink(ContentDocumentId = docId, LinkedEntityId = lead.Id,
                ShareType = 'V', Visibility = 'AllUsers');
        }
        SlackApiMock mock = new SlackApiMock();
        Test.setMock(HttpCalloutMock.class, mock);

        // When
        SlackProposalShareService.Response response = callService(buildRequest(lead.Id, PROPOSAL_TEXT))[0];

        // Then
        Assert.isTrue(response.isSuccess, '메시지 게시 성공');
        Assert.areEqual(2, response.sharedFileCount, '작은 파일 2개만 공유');
        Assert.isTrue(response.skippedFiles.contains('big.bin') && response.skippedFiles.contains('MB 초과'),
            '큰 파일은 크기 초과로 건너뜀. 실제: ' + response.skippedFiles);
        Assert.areEqual(2, mock.countOf('/files.getUploadURLExternal'), '큰 파일은 업로드 API 호출 안 함');
    }

    // ─── Mock ────────────────────────────────────────────────────────────

    /** callout:Slack 경로별 응답 + files.slack.com 업로드 URL 응답을 흉내 낸다. */
    private class SlackApiMock implements HttpCalloutMock {
        public List<String> calledPaths = new List<String>();
        public List<String> uploadUrlQueries = new List<String>();
        public String lastPostMessageBody;
        public String lastCompleteBody;
        public Integer uploadCallCount = 0;
        public Integer uploadUrlCallCount = 0;

        public String failPostMessageWith;
        public String failUploadUrlWith;
        public String failCompleteWith;
        public Integer failUploadOnCall;
        public Integer httpStatusOverride;

        public Integer countOf(String path) {
            Integer count = 0;
            for (String called : calledPaths) {
                if (called == path) {
                    count++;
                }
            }
            return count;
        }

        public HttpResponse respond(HttpRequest request) {
            String endpoint = request.getEndpoint();
            HttpResponse response = new HttpResponse();

            // 업로드 URL(files.slack.com) 로의 바이트 POST
            if (endpoint.startsWith(UPLOAD_URL_BASE)) {
                uploadCallCount++;
                if (failUploadOnCall != null && uploadCallCount == failUploadOnCall) {
                    response.setStatusCode(500);
                    response.setStatus('Internal Server Error');
                    response.setBody('upload failed');
                    return response;
                }
                Assert.isTrue(request.getBodyAsBlob() != null && request.getBodyAsBlob().size() > 0, '업로드 본문에 파일 바이트');
                response.setStatusCode(200);
                response.setBody('OK - 11');
                return response;
            }

            String path = endpoint.substringAfter('callout:Slack').substringBefore('?');
            calledPaths.add(path);
            response.setHeader('Content-Type', 'application/json');
            response.setStatusCode(httpStatusOverride ?? 200);
            if (httpStatusOverride != null) {
                response.setStatus('Service Unavailable');
                response.setBody('{"ok":false,"error":"service_unavailable"}');
                return response;
            }

            if (path == '/chat.postMessage') {
                lastPostMessageBody = request.getBody();
                response.setBody(failPostMessageWith != null
                    ? '{"ok":false,"error":"' + failPostMessageWith + '"}'
                    : '{"ok":true,"channel":"' + CHANNEL_ID + '","ts":"1700000000.000100"}');
            } else if (path == '/files.getUploadURLExternal') {
                uploadUrlCallCount++;
                uploadUrlQueries.add(endpoint.substringAfter('?'));
                if (failUploadUrlWith != null) {
                    response.setBody('{"ok":false,"error":"' + failUploadUrlWith + '","needed":"files:write","provided":"chat:write"}');
                } else {
                    response.setBody('{"ok":true,"upload_url":"' + UPLOAD_URL_BASE + 'ABC' + uploadUrlCallCount
                        + '","file_id":"F0MOCK' + uploadUrlCallCount + '"}');
                }
            } else if (path == '/files.completeUploadExternal') {
                lastCompleteBody = request.getBody();
                response.setBody(failCompleteWith != null
                    ? '{"ok":false,"error":"' + failCompleteWith + '"}'
                    : '{"ok":true,"files":[{"id":"F0MOCK","title":"t"}]}');
            } else {
                response.setBody('{"ok":false,"error":"unknown_method"}');
            }
            return response;
        }
    }
}