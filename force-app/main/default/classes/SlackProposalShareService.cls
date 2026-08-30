/**
 * Lead 의 Slack 채널(14번 작업에서 만든 Slack_Channel_ID__c)에
 *   1) RP 제안 메시지(프롬프트 템플릿 RP_Proposal_Message 출력)를 게시하고
 *   2) Lead 에 첨부된 파일(ContentDocumentLink → 최신 ContentVersion)을 채널에 공유하는
 * Flow 호출용(Invocable) 서비스. (백로그 15번: 준비 자료 공유 + RP 제안 메시지)
 *
 * Slack 호출은 Named Credential "Slack" (callout:Slack → https://slack.com/api) 을 통해 나간다.
 * 파일 공유는 Slack 신규 업로드 3단계 API 를 쓴다:
 *   files.getUploadURLExternal → (업로드 URL 로 파일 바이트 POST) → files.completeUploadExternal(channel_id)
 * 업로드 URL 은 https://files.slack.com 도메인이라 Remote Site Setting 이 필요하고,
 * 봇 토큰에는 files:write scope 가 필요하다.
 *
 * 실패 정책: 메시지 게시 실패 → isSuccess=false. 파일은 개별 실패해도 나머지는 계속 진행하고
 * skippedFiles 에 "파일명 (사유)" 로 돌려준다. 예외는 Flow 로 던지지 않고 Response 로 보고한다.
 *
 * 14번 클래스(SlackLeadChannelService)는 수정하지 않고 독립적으로 동작한다.
 */
public with sharing class SlackProposalShareService {

    // ─── Constants ───────────────────────────────────────────────────────

    private static final String NAMED_CREDENTIAL = 'callout:Slack';
    private static final Integer CALLOUT_TIMEOUT_MS = 60000;
    private static final String CONTENT_TYPE_JSON = 'application/json; charset=utf-8';
    private static final String CONTENT_TYPE_FORM = 'application/x-www-form-urlencoded';
    private static final String CONTENT_TYPE_BINARY = 'application/octet-stream';

    /** 동기 Apex 힙 한도(6MB)를 고려한 파일 1건 상한(바이트). 초과분은 건너뛰고 사유를 보고한다. (테스트에서만 조정 가능) */
    @TestVisible private static Integer maxFileBytes = 4 * 1024 * 1024;
    /** 콜아웃 한도(100회/트랜잭션) 안에서 파일당 3회 호출 + 메시지 1회를 감안한 상한. */
    @TestVisible private static final Integer MAX_FILES_PER_REQUEST = 20;

    private static final String ERR_MISSING_SCOPE = 'missing_scope';
    private static final String ERR_NOT_IN_CHANNEL = 'not_in_channel';
    private static final String ERR_CHANNEL_NOT_FOUND = 'channel_not_found';

    // ─── Invocable Method ────────────────────────────────────────────────

    @InvocableMethod(
        label='Slack: Lead 채널에 제안 메시지 + 첨부파일 공유'
        description='Lead.Slack_Channel_ID__c 채널에 제안 메시지를 게시하고, Lead에 첨부된 파일(Files)을 채널에 공유합니다. 채널이 없으면 실패를 돌려줍니다.'
        category='Slack'
        callout=true
    )
    public static List<Response> shareProposal(List<Request> requests) {
        List<Response> responses = new List<Response>();
        if (requests == null || requests.isEmpty()) {
            return responses;
        }

        Set<Id> leadIds = new Set<Id>();
        for (Request request : requests) {
            if (request.leadId != null) {
                leadIds.add(request.leadId);
            }
        }
        Map<Id, Lead> leadsById = leadIds.isEmpty()
            ? new Map<Id, Lead>()
            : new Map<Id, Lead>([
                SELECT Id, Name, Company, Slack_Channel_ID__c
                FROM Lead
                WHERE Id IN :leadIds
                WITH USER_MODE
            ]);

        for (Request request : requests) {
            responses.add(processRequest(request, leadsById.get(request.leadId)));
        }
        return responses;
    }

    // ─── Orchestration ───────────────────────────────────────────────────

    private static Response processRequest(Request request, Lead lead) {
        Response response = new Response();
        response.isSuccess = false;
        response.messagePosted = false;
        response.sharedFileCount = 0;
        response.allFilesShared = true;

        if (request.leadId == null) {
            return fail(response, 'VALIDATION', 'leadId 가 비어 있습니다.');
        }
        if (lead == null) {
            return fail(response, 'NOT_FOUND', 'Lead를 찾을 수 없거나 접근 권한이 없습니다: ' + request.leadId);
        }
        if (String.isBlank(lead.Slack_Channel_ID__c)) {
            return fail(response, 'NO_CHANNEL',
                '이 Lead에는 아직 Slack 채널이 없습니다. 먼저 "Slack 채널 + 이메일 발송" 버튼으로 채널을 만들어 주세요.');
        }
        if (String.isBlank(request.messageText)) {
            return fail(response, 'VALIDATION', '보낼 제안 메시지가 비어 있습니다.');
        }
        response.channelId = lead.Slack_Channel_ID__c;

        // 1) 제안 메시지 게시 — 실패하면 여기서 중단 (파일만 올라가는 어색한 상태 방지)
        try {
            postMessage(lead.Slack_Channel_ID__c, request.messageText);
            response.messagePosted = true;
        } catch (SlackProposalShareException e) {
            return fail(response, e.slackErrorCode ?? e.getTypeName(), '제안 메시지 게시 실패: ' + e.getMessage());
        } catch (CalloutException e) {
            return fail(response, e.getTypeName(), '제안 메시지 게시 실패(Slack 호출 오류): ' + e.getMessage());
        } catch (Exception e) {
            return fail(response, e.getTypeName(), '제안 메시지 게시 실패: ' + e.getMessage());
        }

        // 2) 첨부파일 공유 — 개별 실패는 건너뛰고 계속
        if (request.shareFiles ?? true) {
            shareLeadFiles(lead, response);
        }

        response.isSuccess = true;
        return response;
    }

    /** Lead 에 연결된 파일을 전부 채널에 공유한다. 결과는 response.sharedFiles / skippedFiles 에 누적. */
    private static void shareLeadFiles(Lead lead, Response response) {
        List<String> sharedNames = new List<String>();
        List<String> skippedNames = new List<String>();

        List<ContentVersion> versions = queryLeadFileVersions(lead.Id);
        if (versions.size() > MAX_FILES_PER_REQUEST) {
            for (Integer i = MAX_FILES_PER_REQUEST; i < versions.size(); i++) {
                skippedNames.add(displayName(versions[i]) + ' (한 번에 최대 ' + MAX_FILES_PER_REQUEST + '개까지 공유)');
            }
            List<ContentVersion> limited = new List<ContentVersion>();
            for (Integer i = 0; i < MAX_FILES_PER_REQUEST; i++) {
                limited.add(versions[i]);
            }
            versions = limited;
        }

        for (ContentVersion version : versions) {
            String fileName = displayName(version);
            if (version.ContentSize != null && version.ContentSize > maxFileBytes) {
                skippedNames.add(fileName + ' (파일 크기 ' + (maxFileBytes / 1024 / 1024) + 'MB 초과)');
                continue;
            }
            try {
                uploadAndShareFile(version, fileName, lead.Slack_Channel_ID__c);
                sharedNames.add(fileName);
            } catch (SlackProposalShareException e) {
                skippedNames.add(fileName + ' (' + e.getMessage() + ')');
            } catch (CalloutException e) {
                skippedNames.add(fileName + ' (Slack 호출 오류: ' + e.getMessage() + ')');
            } catch (Exception e) {
                skippedNames.add(fileName + ' (' + e.getMessage() + ')');
            }
        }

        response.sharedFileCount = sharedNames.size();
        response.sharedFiles = String.join(sharedNames, ', ');
        response.skippedFiles = String.join(skippedNames, ', ');
        response.allFilesShared = skippedNames.isEmpty();
        if (!skippedNames.isEmpty()) {
            response.errorType = 'FILE_PARTIAL';
            response.errorMessage = '일부 파일을 공유하지 못했습니다: ' + response.skippedFiles;
        }
    }

    /** Lead 에 붙은 파일(ContentDocumentLink)의 최신 버전 메타데이터만 조회 (VersionData 는 파일별로 따로 읽음). */
    private static List<ContentVersion> queryLeadFileVersions(Id leadId) {
        Set<Id> documentIds = new Set<Id>();
        for (ContentDocumentLink link : [
            SELECT ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :leadId
            WITH USER_MODE
        ]) {
            documentIds.add(link.ContentDocumentId);
        }
        if (documentIds.isEmpty()) {
            return new List<ContentVersion>();
        }
        return [
            SELECT Id, Title, PathOnClient, FileExtension, ContentSize
            FROM ContentVersion
            WHERE ContentDocumentId IN :documentIds AND IsLatest = true
            WITH USER_MODE
            ORDER BY CreatedDate
        ];
    }

    /** Slack 3단계 업로드: URL 발급 → 바이트 업로드 → 채널에 완료(공유). */
    private static void uploadAndShareFile(ContentVersion versionMeta, String fileName, String channelId) {
        Blob fileBody = [
            SELECT VersionData FROM ContentVersion WHERE Id = :versionMeta.Id WITH USER_MODE LIMIT 1
        ].VersionData;
        if (fileBody == null || fileBody.size() == 0) {
            throw new SlackProposalShareException('파일 내용이 비어 있음', 'EMPTY_FILE');
        }

        // ① 업로드 URL 발급
        Map<String, Object> urlResult = getForm('/files.getUploadURLExternal?filename='
            + EncodingUtil.urlEncode(fileName, 'UTF-8') + '&length=' + fileBody.size());
        if (urlResult.get('ok') != true) {
            throw new SlackProposalShareException('업로드 URL 발급 실패: ' + describeSlackError(urlResult),
                String.valueOf(urlResult.get('error')));
        }
        String uploadUrl = String.valueOf(urlResult.get('upload_url'));
        String fileId = String.valueOf(urlResult.get('file_id'));

        // ② 파일 바이트 업로드 (files.slack.com — Remote Site Setting 필요)
        HttpRequest uploadRequest = new HttpRequest();
        uploadRequest.setEndpoint(uploadUrl);
        uploadRequest.setMethod('POST');
        uploadRequest.setHeader('Content-Type', CONTENT_TYPE_BINARY);
        uploadRequest.setTimeout(CALLOUT_TIMEOUT_MS);
        uploadRequest.setBodyAsBlob(fileBody);
        HttpResponse uploadResponse = new Http().send(uploadRequest);
        if (uploadResponse.getStatusCode() < 200 || uploadResponse.getStatusCode() >= 300) {
            throw new SlackProposalShareException('파일 업로드 HTTP ' + uploadResponse.getStatusCode()
                + ' ' + uploadResponse.getStatus(), 'HTTP_' + uploadResponse.getStatusCode());
        }

        // ③ 업로드 완료 + 채널 공유
        Map<String, Object> completeBody = new Map<String, Object>{
            'files' => new List<Object>{ new Map<String, Object>{ 'id' => fileId, 'title' => fileName } },
            'channel_id' => channelId
        };
        Map<String, Object> completeResult = postJson('/files.completeUploadExternal', completeBody);
        if (completeResult.get('ok') != true) {
            throw new SlackProposalShareException('채널 공유 실패: ' + describeSlackError(completeResult),
                String.valueOf(completeResult.get('error')));
        }
    }

    private static void postMessage(String channelId, String text) {
        Map<String, Object> body = new Map<String, Object>{
            'channel' => channelId,
            'text' => text
        };
        Map<String, Object> result = postJson('/chat.postMessage', body);
        if (result.get('ok') != true) {
            throw new SlackProposalShareException(describeSlackError(result), String.valueOf(result.get('error')));
        }
    }

    private static Response fail(Response response, String errorType, String message) {
        response.isSuccess = false;
        response.errorType = errorType;
        response.errorMessage = message;
        return response;
    }

    // ─── HTTP plumbing ───────────────────────────────────────────────────

    private static Map<String, Object> postJson(String path, Map<String, Object> body) {
        HttpRequest httpRequest = new HttpRequest();
        httpRequest.setEndpoint(NAMED_CREDENTIAL + path);
        httpRequest.setMethod('POST');
        httpRequest.setHeader('Content-Type', CONTENT_TYPE_JSON);
        httpRequest.setTimeout(CALLOUT_TIMEOUT_MS);
        httpRequest.setBody(JSON.serialize(body));
        return send(httpRequest);
    }

    private static Map<String, Object> getForm(String pathWithQuery) {
        HttpRequest httpRequest = new HttpRequest();
        httpRequest.setEndpoint(NAMED_CREDENTIAL + pathWithQuery);
        httpRequest.setMethod('GET');
        httpRequest.setHeader('Content-Type', CONTENT_TYPE_FORM);
        httpRequest.setTimeout(CALLOUT_TIMEOUT_MS);
        return send(httpRequest);
    }

    private static Map<String, Object> send(HttpRequest httpRequest) {
        HttpResponse httpResponse = new Http().send(httpRequest);
        if (httpResponse.getStatusCode() < 200 || httpResponse.getStatusCode() >= 300) {
            throw new SlackProposalShareException(
                'Slack HTTP ' + httpResponse.getStatusCode() + ' ' + httpResponse.getStatus(),
                'HTTP_' + httpResponse.getStatusCode()
            );
        }
        Object parsed = JSON.deserializeUntyped(httpResponse.getBody());
        if (!(parsed instanceof Map<String, Object>)) {
            throw new SlackProposalShareException('Slack 응답을 해석할 수 없습니다.', 'INVALID_RESPONSE');
        }
        return (Map<String, Object>) parsed;
    }

    private static String describeSlackError(Map<String, Object> result) {
        String errorCode = String.valueOf(result.get('error'));
        if (errorCode == ERR_MISSING_SCOPE) {
            return 'Slack 앱 권한(scope) 부족: ' + String.valueOf(result.get('needed'))
                + ' 가 필요합니다. api.slack.com 에서 scope 추가 후 Reinstall 하세요.';
        }
        if (errorCode == ERR_NOT_IN_CHANNEL || errorCode == ERR_CHANNEL_NOT_FOUND) {
            return errorCode + ' — 봇이 채널 멤버가 아니거나 채널이 삭제/아카이브되었습니다.';
        }
        return errorCode;
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    /** Slack 에 표시할 파일명: 원래 업로드 파일명(PathOnClient) 우선, 없으면 제목+확장자. */
    private static String displayName(ContentVersion version) {
        if (String.isNotBlank(version.PathOnClient)) {
            // substringAfterLast 는 구분자가 없으면 빈 문자열을 돌려주므로, 구분자가 있을 때만 잘라낸다
            String path = version.PathOnClient.trim();
            if (path.contains('/')) {
                path = path.substringAfterLast('/');
            }
            if (path.contains('\\')) {
                path = path.substringAfterLast('\\');
            }
            if (String.isNotBlank(path)) {
                return path;
            }
        }
        String title = String.isNotBlank(version.Title) ? version.Title : 'file';
        return String.isNotBlank(version.FileExtension) && !title.toLowerCase().endsWith('.' + version.FileExtension.toLowerCase())
            ? title + '.' + version.FileExtension
            : title;
    }

    /**
     * docs/58 Scene 3: Lead 와 무관하게 ContentDocument 1건을 지정 채널에 공유한다.
     * 기존 Lead 흐름(shareProposal)은 그대로 두고 내부 uploadAndShareFile 을 재사용한다.
     * @return 공유된 파일명. 실패 시 SlackProposalShareException / CalloutException.
     */
    public static String shareContentDocumentToChannel(Id contentDocumentId, String channelId) {
        ContentVersion version = [
            SELECT Id, Title, PathOnClient, FileExtension, ContentSize
            FROM ContentVersion
            WHERE ContentDocumentId = :contentDocumentId AND IsLatest = true
            WITH USER_MODE
            LIMIT 1
        ];
        String fileName = displayName(version);
        uploadAndShareFile(version, fileName, channelId);
        return fileName;
    }

    // ─── Request / Response DTOs ─────────────────────────────────────────

    /** Flow 입력 */
    public class Request {
        @InvocableVariable(label='Lead Id' description='Slack 채널이 연결된 Lead 의 레코드 Id' required=true)
        public Id leadId;

        @InvocableVariable(label='제안 메시지 본문' description='채널에 게시할 텍스트(프롬프트 템플릿 출력 또는 RM이 수정한 본문)' required=true)
        public String messageText;

        @InvocableVariable(label='첨부파일도 공유' description='기본값 true. Lead 에 첨부된 파일(Files)을 채널에 함께 공유')
        public Boolean shareFiles;
    }

    /** Flow 출력 */
    public class Response {
        @InvocableVariable(label='성공 여부' description='제안 메시지가 게시되었으면 true (파일 일부 실패는 allFilesShared 로 구분)')
        public Boolean isSuccess;

        @InvocableVariable(label='메시지 게시됨')
        public Boolean messagePosted;

        @InvocableVariable(label='채널 ID')
        public String channelId;

        @InvocableVariable(label='공유한 파일 수')
        public Integer sharedFileCount;

        @InvocableVariable(label='공유한 파일명' description='쉼표 구분')
        public String sharedFiles;

        @InvocableVariable(label='건너뛴 파일' description='"파일명 (사유)" 쉼표 구분')
        public String skippedFiles;

        @InvocableVariable(label='모든 파일 공유 성공' description='건너뛴 파일이 없으면 true (파일이 0개여도 true)')
        public Boolean allFilesShared;

        @InvocableVariable(label='오류 메시지')
        public String errorMessage;

        @InvocableVariable(label='오류 유형' description='Slack error 코드 또는 예외 타입. 파일 일부 실패는 FILE_PARTIAL')
        public String errorType;
    }

    /** Slack 호출 단계에서 발생한 업무 오류. slackErrorCode 에 Slack 의 error 값을 보존한다. */
    public class SlackProposalShareException extends Exception {
        public String slackErrorCode;
        public SlackProposalShareException(String message, String slackErrorCode) {
            this.setMessage(message);
            this.slackErrorCode = slackErrorCode;
        }
    }
}