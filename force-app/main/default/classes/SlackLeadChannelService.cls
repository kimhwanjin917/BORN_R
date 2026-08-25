/**
 * Lead 전용 Slack 비공개 채널을 생성하고, 담당자/고객을 초대하고, 환영 메시지를 게시한 뒤
 * 채널 딥링크를 돌려주는 Flow 호출용(Invocable) 서비스.
 *
 * Slack 호출은 전부 Named Credential "Slack" (callout:Slack → https://slack.com/api) 을 통해 나가므로
 * 코드에 토큰이 없다. 딥링크 base URL은 Slack__mdt.Slack_Org.Org_Url__c 에서 읽는다.
 *
 * 호출 순서: conversations.create → users.lookupByEmail(초대 대상) → conversations.invite
 *            → chat.postMessage. 각 단계의 실패는 Response.errorMessage 로 돌려주고 예외를 던지지 않는다.
 *
 * 나중에 Slack admin 승인이 나서 "진짜 초대 링크"로 바꿀 때는 buildDeepLink() 한 곳만 교체하면 된다.
 */
public with sharing class SlackLeadChannelService {

    // ─── Constants ───────────────────────────────────────────────────────

    private static final String NAMED_CREDENTIAL = 'callout:Slack';
    private static final String SLACK_MDT_DEVELOPER_NAME = 'Slack_Org';
    private static final String DEFAULT_WORKSPACE_URL = 'https://slack-demo-39110.enterprise.slack.com';
    private static final Integer MAX_NAME_RETRIES = 9;
    private static final Integer SLACK_CHANNEL_NAME_MAX_LENGTH = 80;
    private static final Integer CALLOUT_TIMEOUT_MS = 20000;
    private static final String CONTENT_TYPE_JSON = 'application/json; charset=utf-8';
    private static final String CONTENT_TYPE_FORM = 'application/x-www-form-urlencoded';

    private static final String ERR_NAME_TAKEN = 'name_taken';
    private static final String ERR_MISSING_SCOPE = 'missing_scope';
    private static final String ERR_USERS_NOT_FOUND = 'users_not_found';
    private static final String ERR_ALREADY_IN_CHANNEL = 'already_in_channel';
    private static final String ERR_CANT_INVITE_SELF = 'cant_invite_self';

    // ─── Invocable Method ────────────────────────────────────────────────

    /**
     * Lead 1건당 Slack 비공개 채널을 만들고 담당자/고객을 초대한 뒤 환영 메시지를 올린다.
     * Lead.Slack_Channel_ID__c 에 이미 값이 있으면 새로 만들지 않고 기존 채널 정보를 돌려준다.
     *
     * @param requests Flow에서 넘어온 요청 목록 (보통 버튼 클릭이므로 1건)
     * @return 요청 순서와 동일한 응답 목록 (channelId, deepLink, isSuccess 등)
     */
    @InvocableMethod(
        label='Slack: Lead 채널 생성 + 초대 + 환영 메시지'
        description='Lead 전용 Slack 비공개 채널을 만들고, 실행 사용자·Lead 담당자·Lead 이메일(워크스페이스 멤버인 경우)을 초대한 뒤 환영 메시지를 게시하고 채널 딥링크를 돌려줍니다.'
        category='Slack'
        callout=true
    )
    public static List<Response> createChannelForLeads(List<Request> requests) {
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
                SELECT Id, Name, FirstName, LastName, Company, Email,
                       Owner.Email, Owner.Name,
                       Slack_Channel_ID__c, Slack_Channel_Link__c
                FROM Lead
                WHERE Id IN :leadIds
                WITH USER_MODE
            ]);

        String runningUserEmail = UserInfo.getUserEmail();

        for (Request request : requests) {
            responses.add(processRequest(request, leadsById.get(request.leadId), runningUserEmail));
        }
        return responses;
    }

    // ─── Orchestration ───────────────────────────────────────────────────

    private static Response processRequest(Request request, Lead lead, String runningUserEmail) {
        Response response = new Response();
        response.isSuccess = false;
        response.alreadyExisted = false;

        if (request.leadId == null) {
            return fail(response, 'VALIDATION', 'leadId 가 비어 있습니다.');
        }
        if (lead == null) {
            return fail(response, 'NOT_FOUND', 'Lead를 찾을 수 없거나 접근 권한이 없습니다: ' + request.leadId);
        }

        try {
            if (String.isNotBlank(lead.Slack_Channel_ID__c)) {
                return markExistingChannel(response, lead);
            }
            createChannelAndOnboard(request, lead, runningUserEmail, response);
            response.isSuccess = true;
        } catch (SlackLeadChannelException e) {
            fail(response, e.slackErrorCode ?? e.getTypeName(), e.getMessage());
        } catch (CalloutException e) {
            fail(response, e.getTypeName(), 'Slack 호출 실패: ' + e.getMessage());
        } catch (Exception e) {
            fail(response, e.getTypeName(), e.getMessage());
        }
        return response;
    }

    /** 0) 이미 채널이 있으면 새로 만들지 않고 기존 정보를 돌려준다 (중복 생성 방지). */
    private static Response markExistingChannel(Response response, Lead lead) {
        response.channelId = lead.Slack_Channel_ID__c;
        response.deepLink = String.isNotBlank(lead.Slack_Channel_Link__c)
            ? lead.Slack_Channel_Link__c
            : buildDeepLink(lead.Slack_Channel_ID__c);
        response.alreadyExisted = true;
        response.isSuccess = true;
        return response;
    }

    /** 1) 채널 생성 → 2) 초대 → 3) 환영 메시지. 실패 시 SlackLeadChannelException. */
    private static void createChannelAndOnboard(Request request, Lead lead, String runningUserEmail, Response response) {
        String channelName = String.isNotBlank(request.channelName)
            ? normalizeChannelName(request.channelName)
            : deriveChannelName(lead);
        SlackChannel channel = createChannel(channelName, request.isPrivate ?? true);
        response.channelId = channel.id;
        response.channelName = channel.name;
        response.deepLink = buildDeepLink(channel.id);

        InviteOutcome outcome = inviteByEmails(channel.id, resolveInviteEmails(request, lead, runningUserEmail));
        response.invitedEmails = String.join(outcome.invited, ', ');
        response.skippedEmails = String.join(outcome.skipped, ', ');

        String welcomeText = String.isNotBlank(request.welcomeMessage)
            ? request.welcomeMessage
            : buildDefaultWelcomeMessage(lead);
        postMessage(channel.id, welcomeText);
    }

    /** 초대 대상 순서: 실행 사용자(버튼 누른 사람) → Lead 담당자 → 고객(Lead.Email, 옵션). 중복 제거. */
    private static List<String> resolveInviteEmails(Request request, Lead lead, String runningUserEmail) {
        List<String> candidateEmails = new List<String>();
        addEmailIfNew(candidateEmails, runningUserEmail);
        addEmailIfNew(candidateEmails, lead.Owner?.Email);
        if (request.inviteLeadEmail ?? true) {
            addEmailIfNew(candidateEmails, lead.Email);
        }
        return candidateEmails;
    }

    private static Response fail(Response response, String errorType, String message) {
        response.isSuccess = false;
        response.errorType = errorType;
        response.errorMessage = message;
        return response;
    }

    // ─── Slack API: channel ──────────────────────────────────────────────

    private static SlackChannel createChannel(String channelName, Boolean isPrivate) {
        Map<String, Object> body = new Map<String, Object>{
            'name' => channelName,
            'is_private' => isPrivate
        };
        Map<String, Object> result = postJson('/conversations.create', body);

        // 같은 이름이 이미 있으면(아카이브 포함) -2, -3 … 순서로 재시도
        Integer attempt = 2;
        while (result.get('ok') != true
            && String.valueOf(result.get('error')) == ERR_NAME_TAKEN
            && attempt <= MAX_NAME_RETRIES + 1) {
            body.put('name', truncateChannelName(channelName + '-' + attempt));
            result = postJson('/conversations.create', body);
            attempt++;
        }
        if (result.get('ok') != true) {
            throw new SlackLeadChannelException(describeSlackError(result), String.valueOf(result.get('error')));
        }

        Map<String, Object> channelNode = (Map<String, Object>) result.get('channel');
        SlackChannel channel = new SlackChannel();
        channel.id = String.valueOf(channelNode.get('id'));
        channel.name = String.valueOf(channelNode.get('name'));
        return channel;
    }

    private static void postMessage(String channelId, String text) {
        Map<String, Object> body = new Map<String, Object>{
            'channel' => channelId,
            'text' => text
        };
        Map<String, Object> result = postJson('/chat.postMessage', body);
        if (result.get('ok') != true) {
            throw new SlackLeadChannelException('환영 메시지 게시 실패: ' + describeSlackError(result), String.valueOf(result.get('error')));
        }
    }

    // ─── Slack API: users / invite ───────────────────────────────────────

    private static InviteOutcome inviteByEmails(String channelId, List<String> emails) {
        InviteOutcome outcome = new InviteOutcome();
        List<String> userIds = new List<String>();

        for (String email : emails) {
            String userId = lookupUserIdByEmail(email);
            if (String.isBlank(userId)) {
                outcome.skipped.add(email);
            } else {
                userIds.add(userId);
                outcome.invited.add(email);
            }
        }
        if (userIds.isEmpty()) {
            return outcome;
        }

        Map<String, Object> body = new Map<String, Object>{
            'channel' => channelId,
            'users' => String.join(userIds, ',')
        };
        Map<String, Object> result = postJson('/conversations.invite', body);
        if (result.get('ok') != true) {
            String errorCode = String.valueOf(result.get('error'));
            // 이미 들어가 있거나 봇 자신인 경우는 치명적이지 않으므로 넘어간다
            if (errorCode != ERR_ALREADY_IN_CHANNEL && errorCode != ERR_CANT_INVITE_SELF) {
                throw new SlackLeadChannelException('채널 초대 실패: ' + describeSlackError(result), errorCode);
            }
        }
        return outcome;
    }

    private static String lookupUserIdByEmail(String email) {
        Map<String, Object> result = getForm('/users.lookupByEmail?email=' + EncodingUtil.urlEncode(email, 'UTF-8'));
        if (result.get('ok') == true) {
            Map<String, Object> userNode = (Map<String, Object>) result.get('user');
            return userNode == null ? null : String.valueOf(userNode.get('id'));
        }
        String errorCode = String.valueOf(result.get('error'));
        if (errorCode == ERR_USERS_NOT_FOUND) {
            return null; // 워크스페이스 멤버가 아님 → 초대 건너뜀
        }
        throw new SlackLeadChannelException('Slack 사용자 조회 실패(' + email + '): ' + describeSlackError(result), errorCode);
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
            throw new SlackLeadChannelException(
                'Slack HTTP ' + httpResponse.getStatusCode() + ' ' + httpResponse.getStatus(),
                'HTTP_' + httpResponse.getStatusCode()
            );
        }
        Object parsed = JSON.deserializeUntyped(httpResponse.getBody());
        if (!(parsed instanceof Map<String, Object>)) {
            throw new SlackLeadChannelException('Slack 응답을 해석할 수 없습니다.', 'INVALID_RESPONSE');
        }
        return (Map<String, Object>) parsed;
    }

    private static String describeSlackError(Map<String, Object> result) {
        String errorCode = String.valueOf(result.get('error'));
        if (errorCode == ERR_MISSING_SCOPE) {
            return 'Slack 앱 권한(scope) 부족: ' + String.valueOf(result.get('needed'))
                + ' 가 필요합니다. api.slack.com 에서 scope 추가 후 Reinstall 하세요.';
        }
        return errorCode;
    }

    // ─── Naming / link helpers ───────────────────────────────────────────

    /**
     * 채널 딥링크를 만든다. Slack__mdt.Slack_Org.Org_Url__c + /archives/{channelId}.
     * admin 승인 후 "진짜 초대 링크" 방식으로 바꿀 때 이 메서드만 교체한다.
     */
    private static String buildDeepLink(String channelId) {
        String baseUrl = DEFAULT_WORKSPACE_URL;
        Slack__mdt slackOrg = Slack__mdt.getInstance(SLACK_MDT_DEVELOPER_NAME);
        if (slackOrg != null && String.isNotBlank(slackOrg.Org_Url__c)) {
            baseUrl = slackOrg.Org_Url__c;
        }
        return baseUrl.removeEnd('/') + '/archives/' + channelId;
    }

    /** 채널 이름 = {회사명}-{성이름}. 예: 삼성전자-김철수. 회사명이 없으면 이름만. 중복은 createChannel 에서 -2, -3 … 으로 해결. */
    private static String deriveChannelName(Lead lead) {
        String personName = ((lead.LastName ?? '') + (lead.FirstName ?? '')).trim();
        if (String.isBlank(personName)) {
            personName = lead.Name ?? '';
        }
        List<String> parts = new List<String>();
        if (String.isNotBlank(lead.Company)) {
            parts.add(normalizeChannelName(lead.Company));
        }
        if (String.isNotBlank(personName)) {
            parts.add(normalizeChannelName(personName));
        }
        return truncateChannelName(parts.isEmpty() ? 'lead' : String.join(parts, '-'));
    }

    /** Slack 채널 이름 규칙: 소문자, 공백/마침표/대부분의 구두점 불가, 80자 이하. */
    private static String normalizeChannelName(String raw) {
        String normalized = raw.trim().toLowerCase();
        normalized = normalized.replaceAll('[\\s.]+', '-');
        normalized = normalized.replaceAll('[^\\p{L}\\p{N}_-]', '');
        normalized = normalized.replaceAll('-{2,}', '-').removeStart('-').removeEnd('-');
        return truncateChannelName(String.isBlank(normalized) ? 'lead' : normalized);
    }

    private static String truncateChannelName(String name) {
        return name.length() > SLACK_CHANNEL_NAME_MAX_LENGTH
            ? name.substring(0, SLACK_CHANNEL_NAME_MAX_LENGTH).removeEnd('-')
            : name;
    }

    private static String buildDefaultWelcomeMessage(Lead lead) {
        String customerName = String.isNotBlank(lead.Name) ? lead.Name : '고객';
        String company = String.isNotBlank(lead.Company) ? ' (' + lead.Company + ')' : '';
        String ownerName = lead.Owner?.Name ?? '담당자';
        return ':wave: ' + customerName + '님' + company + ', 환영합니다!\n'
            + '이 채널은 ' + customerName + '님 전담 상담 채널입니다. 담당자 ' + ownerName
            + ' 이(가) 궁금하신 점을 바로 도와드리겠습니다. 편하게 남겨주세요.';
    }

    private static void addEmailIfNew(List<String> emails, String email) {
        if (String.isBlank(email)) {
            return;
        }
        String lowered = email.trim().toLowerCase();
        for (String existing : emails) {
            if (existing == lowered) {
                return;
            }
        }
        emails.add(lowered);
    }

    // ─── Request / Response DTOs ─────────────────────────────────────────

    /** Flow 입력 */
    public class Request {
        @InvocableVariable(label='Lead Id' description='채널을 만들 Lead의 레코드 Id' required=true)
        public Id leadId;

        @InvocableVariable(label='채널 이름(선택)' description='비우면 lead-{회사명}-{id끝5자리} 로 자동 생성')
        public String channelName;

        @InvocableVariable(label='환영 메시지(선택)' description='비우면 기본 환영 문구를 게시')
        public String welcomeMessage;

        @InvocableVariable(label='비공개 채널 여부' description='기본값 true (비공개)')
        public Boolean isPrivate;

        @InvocableVariable(label='Lead 이메일도 초대' description='기본값 true. Lead.Email 이 워크스페이스 멤버이면 채널에 초대')
        public Boolean inviteLeadEmail;
    }

    /** Flow 출력 */
    public class Response {
        @InvocableVariable(label='성공 여부')
        public Boolean isSuccess;

        @InvocableVariable(label='이미 채널이 있었는지' description='true면 새로 만들지 않고 기존 채널 정보를 반환')
        public Boolean alreadyExisted;

        @InvocableVariable(label='채널 ID' description='Slack 채널 ID (C로 시작)')
        public String channelId;

        @InvocableVariable(label='채널 이름')
        public String channelName;

        @InvocableVariable(label='채널 딥링크' description='이메일에 넣을 링크. {workspace}/archives/{channelId}')
        public String deepLink;

        @InvocableVariable(label='초대된 이메일' description='실제로 채널에 초대된 이메일(쉼표 구분)')
        public String invitedEmails;

        @InvocableVariable(label='초대 건너뛴 이메일' description='워크스페이스 멤버가 아니라 초대하지 못한 이메일(쉼표 구분)')
        public String skippedEmails;

        @InvocableVariable(label='오류 메시지')
        public String errorMessage;

        @InvocableVariable(label='오류 유형' description='Slack error 코드 또는 예외 타입')
        public String errorType;
    }

    // ─── Internal types ──────────────────────────────────────────────────

    private class SlackChannel {
        public String id;
        public String name;
    }

    private class InviteOutcome {
        public List<String> invited = new List<String>();
        public List<String> skipped = new List<String>();
    }

    /** Slack 호출 단계에서 발생한 업무 오류. slackErrorCode 에 Slack의 error 값을 보존한다. */
    public class SlackLeadChannelException extends Exception {
        public String slackErrorCode;
        public SlackLeadChannelException(String message, String slackErrorCode) {
            this.setMessage(message);
            this.slackErrorCode = slackErrorCode;
        }
    }
}