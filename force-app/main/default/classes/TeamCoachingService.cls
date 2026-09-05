/**
 * 팀장 코칭 발송 — RM 과의 1:1 비공개 Slack 채널에 메시지를 보내고, 같은 내용으로 Task 를 남긴다.
 * 설계: docs/superpowers/specs/2026-09-02-tableau-lwc-coaching-design.md 5.1
 *
 * 둘을 함께 하는 이유는 역할이 다르기 때문이다.
 *   Slack — 도달·대화. 즉시 알림이 가고 RM 이 그 자리에서 답할 수 있다.
 *   Task  — 기록·추적. 평가·내부통제의 근거가 된다. Slack 만으로는 증거가 되지 않는다.
 *
 * 채널은 RM 1명당 하나를 계속 재사용한다(코칭 이력이 한곳에 쌓인다).
 * 비공개라 팀장과 해당 RM 만 본다 — 전체 채널에서 공개적으로 조언하는 상황을 피한다.
 *
 * Opportunity 는 조회하지 않는다. 팀장에게 개별 딜 접근권이 없고(스펙 2.1),
 * 코칭 메시지는 화면에 이미 보이던 집계값만으로 만들어진다.
 *
 * Slack 은 기존 Named Credential "Slack" 을 그대로 쓴다. 신규 앱·스코프 없음.
 */
public with sharing class TeamCoachingService {

    private static final String NC = 'callout:Slack';
    private static final Integer TIMEOUT_MS = 60000;
    private static final Integer SLACK_CHANNEL_NAME_MAX_LENGTH = 80;
    private static final Integer TASK_DUE_IN_DAYS = 3;

    /** 이미 들어가 있거나 봇 자신을 초대한 경우는 실패로 보지 않는다. */
    private static final Set<String> BENIGN_INVITE_ERRORS = new Set<String>{
        'already_in_channel', 'cant_invite_self', 'is_archived'
    };

    public class CoachingRequest {
        @AuraEnabled public String rmUserId { get; set; }
        @AuraEnabled public String rmName { get; set; }
        /** 히트맵에서 왔으면 단계명, 팀원 KPI 에서 왔으면 비어 있다. */
        @AuraEnabled public String stageLabel { get; set; }
        @AuraEnabled public String message { get; set; }
    }

    public class CoachingResult {
        @AuraEnabled public Boolean slackSent { get; set; }
        /** Slack 이 실패한 이유. 성공이면 null. 부분 성공을 사실대로 표시하기 위한 값이다. */
        @AuraEnabled public String slackError { get; set; }
        @AuraEnabled public String channelName { get; set; }
        @AuraEnabled public Id taskId { get; set; }
        @AuraEnabled public String summary { get; set; }
    }

    /**
     * 코칭 발송. Slack 이 실패해도 Task 는 반드시 남긴다(스펙 9장 부분 성공).
     * 콜아웃을 먼저 하고 DML 을 나중에 하는 순서는 바꿀 수 없다 —
     * Apex 는 DML 뒤에 콜아웃을 허용하지 않는다.
     */
    public static CoachingResult sendCoaching(CoachingRequest request) {
        validate(request);

        User rm = loadRm(request.rmUserId);
        CoachingResult result = new CoachingResult();

        try {
            String channelId = ensureCoachingChannel(rm.Name, result);
            inviteParticipants(channelId, new List<String>{ rm.Email, UserInfo.getUserEmail() });
            postMessage(channelId, request.message);
            result.slackSent = true;
        } catch (Exception e) {
            // Slack 이 막혀도 코칭 기록은 남아야 한다. 여기서 멈추지 않는다.
            result.slackSent = false;
            result.slackError = e.getMessage();
        }

        result.taskId = createTask(rm.Id, request);
        result.summary = result.slackSent
            ? 'Slack 발송 완료 · Task 생성됨'
            : 'Task 는 생성했습니다. Slack 전달만 실패했습니다: ' + result.slackError;
        return result;
    }

    private static void validate(CoachingRequest request) {
        if (request == null || String.isBlank(request.rmUserId)) {
            // 이름 문자열로 RM 을 추측 매칭하지 않는다(동명이인·표기 차이로 깨진다 — 스펙 4장).
            throw new TeamCoachingException('RM 을 특정할 수 없습니다. 대시보드에서 RM 을 선택해 주세요.');
        }
        if (String.isBlank(request.message)) {
            throw new TeamCoachingException('보낼 메시지가 비어 있습니다.');
        }
    }

    private static User loadRm(String rmUserId) {
        List<User> users = [SELECT Id, Name, Email FROM User WHERE Id = :rmUserId LIMIT 1];
        if (users.isEmpty()) {
            throw new TeamCoachingException('해당 RM 사용자를 찾을 수 없습니다.');
        }
        return users[0];
    }

    // ─── Task ────────────────────────────────────────────────────────────

    private static Id createTask(Id rmUserId, CoachingRequest request) {
        Task t = new Task();
        t.OwnerId = rmUserId;
        t.Subject = String.isBlank(request.stageLabel)
            ? '팀장 코칭 확인'
            : request.stageLabel + ' 단계 체류 점검';
        t.ActivityDate = Date.today().addDays(TASK_DUE_IN_DAYS);
        t.Description = request.message; // 발송한 메시지 전문을 그대로 남긴다
        t.Status = 'Not Started';
        t.Priority = 'Normal';
        insert t;
        return t.Id;
    }

    // ─── Slack: 채널 확보 ────────────────────────────────────────────────

    /**
     * RM 전용 1:1 비공개 채널을 찾고, 없으면 만든다.
     * 이름이 규칙으로 정해져 있어 매번 같은 채널로 돌아간다 —
     * 별도 매핑 필드 없이 재사용이 되고, 코칭 이력이 한곳에 쌓인다.
     */
    private static String ensureCoachingChannel(String rmName, CoachingResult result) {
        String channelName = buildChannelName(rmName);
        result.channelName = channelName;

        String existingId = findPrivateChannelIdByName(channelName);
        if (String.isNotBlank(existingId)) {
            return existingId;
        }

        Map<String, Object> created = postJson('/conversations.create', new Map<String, Object>{
            'name' => channelName,
            'is_private' => true
        });
        if (created.get('ok') != true) {
            throw new TeamCoachingException('코칭 채널 생성 실패: ' + describeError(created));
        }
        return String.valueOf(((Map<String, Object>) created.get('channel')).get('id'));
    }

    /** 예: "강 하은" → rm-강하은과의-채널 (Slack 은 대문자·공백을 허용하지 않는다) */
    @TestVisible
    private static String buildChannelName(String rmName) {
        String bare = String.isBlank(rmName) ? 'rm' : rmName.replaceAll('\\s+', '');
        return normalizeChannelName('RM ' + bare + '과의 채널');
    }

    @TestVisible
    private static String normalizeChannelName(String raw) {
        String normalized = raw.trim().toLowerCase();
        normalized = normalized.replaceAll('[\\s.]+', '-');
        normalized = normalized.replaceAll('[^\\p{L}\\p{N}_-]', '');
        normalized = normalized.replaceAll('-{2,}', '-').removeStart('-').removeEnd('-');
        return normalized.length() > SLACK_CHANNEL_NAME_MAX_LENGTH
            ? normalized.substring(0, SLACK_CHANNEL_NAME_MAX_LENGTH).removeEnd('-')
            : normalized;
    }

    /** 비공개 채널 목록을 훑어 같은 이름을 찾는다. 못 찾으면 null(=새로 만든다). */
    private static String findPrivateChannelIdByName(String channelName) {
        String cursor = '';
        // 워크스페이스가 커져도 무한히 돌지 않도록 페이지 수를 묶어 둔다.
        for (Integer page = 0; page < 5; page++) {
            String path = '/conversations.list?types=private_channel&exclude_archived=true&limit=200'
                + (String.isBlank(cursor) ? '' : '&cursor=' + EncodingUtil.urlEncode(cursor, 'UTF-8'));
            Map<String, Object> result = getForm(path);
            if (result.get('ok') != true) {
                // 목록 조회가 막혀 있어도 생성 경로로 넘어가면 되므로 여기서 실패시키지 않는다.
                return null;
            }
            for (Object item : (List<Object>) result.get('channels')) {
                Map<String, Object> channel = (Map<String, Object>) item;
                if (channelName.equals(String.valueOf(channel.get('name')))) {
                    return String.valueOf(channel.get('id'));
                }
            }
            cursor = nextCursor(result);
            if (String.isBlank(cursor)) {
                return null;
            }
        }
        return null;
    }

    private static String nextCursor(Map<String, Object> result) {
        Map<String, Object> meta = (Map<String, Object>) result.get('response_metadata');
        return meta == null ? null : String.valueOf(meta.get('next_cursor'));
    }

    // ─── Slack: 초대·발송 ────────────────────────────────────────────────

    /** 팀장(실행한 사용자)과 RM 을 채널에 넣는다. 이메일로 Slack 사용자를 찾는다. */
    private static void inviteParticipants(String channelId, List<String> emails) {
        List<String> slackUserIds = new List<String>();
        for (String email : emails) {
            if (String.isBlank(email)) {
                continue;
            }
            String slackUserId = lookupUserIdByEmail(email);
            if (String.isNotBlank(slackUserId)) {
                slackUserIds.add(slackUserId);
            }
        }
        if (slackUserIds.isEmpty()) {
            // Salesforce 이메일과 Slack 이메일이 다르면 여기로 온다. 채널은 살아 있으므로 발송은 계속한다.
            return;
        }

        Map<String, Object> result = postJson('/conversations.invite', new Map<String, Object>{
            'channel' => channelId,
            'users' => String.join(slackUserIds, ',')
        });
        if (result.get('ok') != true && !BENIGN_INVITE_ERRORS.contains(String.valueOf(result.get('error')))) {
            throw new TeamCoachingException('채널 초대 실패: ' + describeError(result));
        }
    }

    private static String lookupUserIdByEmail(String email) {
        Map<String, Object> result = getForm('/users.lookupByEmail?email=' + EncodingUtil.urlEncode(email, 'UTF-8'));
        if (result.get('ok') != true) {
            return null; // users_not_found 등 — 초대만 건너뛴다
        }
        return String.valueOf(((Map<String, Object>) result.get('user')).get('id'));
    }

    private static void postMessage(String channelId, String text) {
        Map<String, Object> result = postJson('/chat.postMessage', new Map<String, Object>{
            'channel' => channelId,
            'text' => text
        });
        if (result.get('ok') != true) {
            throw new TeamCoachingException('메시지 발송 실패: ' + describeError(result));
        }
    }

    // ─── Slack HTTP ──────────────────────────────────────────────────────

    private static Map<String, Object> postJson(String path, Map<String, Object> body) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(NC + path);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json; charset=utf-8');
        req.setTimeout(TIMEOUT_MS);
        req.setBody(JSON.serialize(body));
        return parse(new Http().send(req));
    }

    private static Map<String, Object> getForm(String path) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(NC + path);
        req.setMethod('GET');
        req.setTimeout(TIMEOUT_MS);
        return parse(new Http().send(req));
    }

    private static Map<String, Object> parse(HttpResponse res) {
        if (res.getStatusCode() != 200) {
            throw new TeamCoachingException('Slack 응답 오류(HTTP ' + res.getStatusCode() + ')');
        }
        return (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
    }

    private static String describeError(Map<String, Object> result) {
        String code = String.valueOf(result.get('error'));
        if (code == 'name_taken') {
            return '같은 이름의 채널이 이미 있으나 조회되지 않습니다(아카이브 상태일 수 있음).';
        }
        if (code == 'missing_scope') {
            return 'Slack 앱 권한이 부족합니다(비공개 채널 생성/조회 스코프 확인).';
        }
        return code;
    }

    public class TeamCoachingException extends Exception {}
}