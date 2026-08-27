/**
 * CRM 자동화 실패를 담당자가 보는 Slack 채널(#crm-처리요청)로 알리는 서비스.
 *
 * 설계 원칙:
 *  - 알림은 "부가 기능"이다. 이 클래스 안에서 무슨 일이 나도 호출한 쪽(원래 업무)을
 *    절대 깨뜨리지 않는다 → 모든 public 진입점은 예외를 삼키고 System.debug 로만 남긴다.
 *  - 채널 ID 는 코드에 박지 않고 CRM_Alert_Setting__mdt(DeveloperName = 알림 종류)에서 읽는다.
 *    레코드가 없거나 Is_Active__c=false 면 조용히 보내지 않는다.
 *  - 실제 Slack 호출은 SlackChannelMessageService(28번, 무수정)에 위임한다.
 *  - 호출자가 이미 DML 을 한 트랜잭션(예: Lead 전환 Queueable)에서 콜아웃은 불가하므로
 *    발송은 별도 Queueable(AllowsCallouts) 로 체인한다. 테스트에서는 Queueable 체인이
 *    금지되어 있어 동기 호출(HttpCalloutMock 필요)로 대체한다.
 */
public with sharing class SlackAlertService {

    /** CRM_Alert_Setting__mdt.DeveloperName */
    @TestVisible private static final String ALERT_LEAD_CONVERT_FAILURE = 'Lead_Convert_Failure';

    /** 테스트에서 설정 레코드를 흉내 내기 위한 주입 지점 */
    @TestVisible private static Map<String, CRM_Alert_Setting__mdt> settingOverrides;

    /** 테스트에서 마지막으로 만들어진 메시지를 검증하기 위한 창 */
    @TestVisible private static List<String> lastBuiltMessages = new List<String>();

    /** 테스트/디버깅용: 마지막으로 삼킨 예외 */
    @TestVisible private static String lastSwallowedError;

    // ─── 공개 진입점 ─────────────────────────────────────────────────────

    /** Lead 자동 전환 1건의 실패 정보 (LeadEventConvertHandler 가 채운다) */
    public class LeadConvertFailure {
        public Id leadId;
        public Id sourceEventId;
        public String errorType;
        public String errorMessage;

        public LeadConvertFailure(Id leadId, Id sourceEventId, String errorType, String errorMessage) {
            this.leadId = leadId;
            this.sourceEventId = sourceEventId;
            this.errorType = errorType;
            this.errorMessage = errorMessage;
        }
    }

    /**
     * Lead 자동 전환 실패를 알림 채널로 보낸다. 절대 예외를 던지지 않는다.
     * @param failures 실패 목록 (null/빈 목록이면 아무것도 하지 않음)
     */
    public static void notifyLeadConvertFailures(List<LeadConvertFailure> failures) {
        try {
            if (failures == null || failures.isEmpty()) {
                return;
            }
            String channelId = resolveChannelId(ALERT_LEAD_CONVERT_FAILURE);
            if (String.isBlank(channelId)) {
                System.debug(LoggingLevel.INFO,
                    'SlackAlertService: ' + ALERT_LEAD_CONVERT_FAILURE + ' 알림 설정이 없거나 비활성 — 건너뜀');
                return;
            }
            List<String> messages = buildLeadConvertFailureMessages(failures);
            lastBuiltMessages = messages;
            dispatch(channelId, messages);
        } catch (Exception e) {
            // 알림 실패가 원래 업무(전환)를 방해하면 안 된다
            lastSwallowedError = e.getTypeName() + ': ' + e.getMessage() + '\n' + e.getStackTraceString();
            System.debug(LoggingLevel.ERROR, 'SlackAlertService.notifyLeadConvertFailures 실패: ' + lastSwallowedError);
        }
    }

    // ─── 설정 ───────────────────────────────────────────────────────────

    @TestVisible
    private static String resolveChannelId(String developerName) {
        CRM_Alert_Setting__mdt setting;
        if (settingOverrides != null) {
            setting = settingOverrides.get(developerName);
        } else {
            setting = CRM_Alert_Setting__mdt.getInstance(developerName);
        }
        if (setting == null || setting.Is_Active__c != true || String.isBlank(setting.Slack_Channel_Id__c)) {
            return null;
        }
        return setting.Slack_Channel_Id__c.trim();
    }

    // ─── 발송 ───────────────────────────────────────────────────────────

    private static void dispatch(String channelId, List<String> messages) {
        if (messages.isEmpty()) {
            return;
        }
        if (Test.isRunningTest()) {
            // 테스트에서는 Queueable 체인이 금지되어 있다 → 동기 호출(HttpCalloutMock 필요)
            postAll(channelId, messages);
            return;
        }
        System.enqueueJob(new PostQueueable(channelId, messages));
    }

    @TestVisible
    private static void postAll(String channelId, List<String> messages) {
        List<SlackChannelMessageService.Request> requests = new List<SlackChannelMessageService.Request>();
        for (String text : messages) {
            SlackChannelMessageService.Request req = new SlackChannelMessageService.Request();
            req.channelId = channelId;
            req.text = text;
            requests.add(req);
        }
        List<SlackChannelMessageService.Response> responses = SlackChannelMessageService.postMessages(requests);
        for (SlackChannelMessageService.Response res : responses) {
            if (res.isSuccess != true) {
                System.debug(LoggingLevel.ERROR, 'SlackAlertService: Slack 게시 실패 channel=' + channelId
                    + ' type=' + res.errorType + ' msg=' + res.errorMessage);
            }
        }
    }

    /** DML 이후 트랜잭션에서 콜아웃을 분리하기 위한 체인 잡 */
    public class PostQueueable implements Queueable, Database.AllowsCallouts {
        private String channelId;
        private List<String> messages;

        public PostQueueable(String channelId, List<String> messages) {
            this.channelId = channelId;
            this.messages = messages;
        }

        public void execute(QueueableContext context) {
            try {
                postAll(channelId, messages);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'SlackAlertService.PostQueueable 실패: '
                    + e.getTypeName() + ': ' + e.getMessage());
            }
        }
    }

    // ─── 메시지 조립 (Lead 전환 실패) ────────────────────────────────────

    @TestVisible
    private static List<String> buildLeadConvertFailureMessages(List<LeadConvertFailure> failures) {
        Set<Id> leadIds = new Set<Id>();
        Set<Id> eventIds = new Set<Id>();
        for (LeadConvertFailure f : failures) {
            if (f.leadId != null) { leadIds.add(f.leadId); }
            if (f.sourceEventId != null) { eventIds.add(f.sourceEventId); }
        }

        Map<Id, Lead> leadsById = new Map<Id, Lead>([
            SELECT Id, Company, Name, Email, Business_Registration_Number__c, Owner.Name
            FROM Lead WHERE Id IN :leadIds
            WITH USER_MODE
        ]);
        Map<Id, Event> eventsById = new Map<Id, Event>([
            SELECT Id, Subject, StartDateTime, CreatedBy.Name
            FROM Event WHERE Id IN :eventIds
            WITH USER_MODE
        ]);

        String baseUrl = URL.getOrgDomainUrl().toExternalForm();
        List<String> messages = new List<String>();
        for (LeadConvertFailure f : failures) {
            Lead ld = leadsById.get(f.leadId);
            Event ev = eventsById.get(f.sourceEventId);
            messages.add(formatLeadConvertFailure(f, ld, ev, baseUrl));
        }
        return messages;
    }

    private static String formatLeadConvertFailure(LeadConvertFailure f, Lead ld, Event ev, String baseUrl) {
        String company = ld != null && String.isNotBlank(ld.Company) ? ld.Company : String.valueOf(f.leadId);
        Diagnosis d = diagnose(f, ld);

        List<String> lines = new List<String>();
        lines.add(':warning: *Lead 자동 전환 실패 — ' + company + '*');
        if (ev != null) {
            String meetingTime = ev.StartDateTime != null
                ? ev.StartDateTime.format('yyyy-MM-dd HH:mm', UserInfo.getTimeZone().getID())
                : '일시 미정';
            lines.add('• 등록한 미팅: ' + ev.Subject + ' (' + meetingTime + ', 등록자 ' + ev.CreatedBy.Name + ')');
        }
        if (ld != null) {
            lines.add('• Lead 담당자: ' + ld.Owner.Name);
        }
        lines.add('• 원인: ' + d.cause);
        lines.add('• 조치: ' + d.action);
        if (f.leadId != null) {
            lines.add('• Lead 열기: ' + baseUrl + '/' + f.leadId);
        }
        return String.join(lines, '\n');
    }

    @TestVisible
    private class Diagnosis {
        public String cause;
        public String action;
    }

    /** 서비스가 돌려준 오류 문자열을 담당자가 이해할 수 있는 한국어 원인·조치로 바꾼다 */
    @TestVisible
    private static Diagnosis diagnose(LeadConvertFailure f, Lead ld) {
        Diagnosis d = new Diagnosis();
        String msg = f.errorMessage == null ? '' : f.errorMessage;
        String lower = msg.toLowerCase();

        if (lower.contains('use one of these records') || lower.contains('duplicates_detected')
                || lower.contains('중복')) {
            List<String> existing = findExistingRecords(ld);
            d.cause = existing.isEmpty()
                ? '같은 회사/담당자로 보이는 Account 또는 Contact가 이미 있어 중복 규칙에 막혔습니다.'
                : '이미 등록된 레코드가 있습니다: ' + String.join(existing, ', ');
            d.action = 'Lead 화면에서 [전환] → 기존 Account/Contact를 선택해서 수동으로 전환해 주세요.';
        } else if (lower.contains('validation')) {
            d.cause = '유효성 규칙에 걸렸습니다 — ' + msg;
            d.action = '메시지의 조건을 맞춘 뒤 [전환]으로 수동 전환해 주세요.';
        } else if (lower.contains('required') || lower.contains('필수')) {
            d.cause = '필수 값이 비어 있습니다 — ' + msg;
            d.action = 'Lead의 빈 필드(업종, 이메일, 사업자번호 등)를 채운 뒤 [전환]으로 수동 전환해 주세요.';
        } else if (lower.contains('insufficient') || lower.contains('access') || f.errorType == 'NOT_FOUND') {
            d.cause = 'Lead에 접근/전환 권한이 없습니다 — ' + msg;
            d.action = '관리자에게 권한을 확인 요청해 주세요.';
        } else {
            d.cause = '알 수 없는 오류 (' + f.errorType + '): ' + msg;
            d.action = 'Lead 화면에서 [전환]을 직접 눌러보고, 같은 오류가 나면 관리자에게 전달해 주세요.';
        }
        return d;
    }

    /** 중복으로 막혔을 때 어떤 기존 레코드인지 찾아 "이름(소유자)" 목록으로 돌려준다 */
    private static List<String> findExistingRecords(Lead ld) {
        List<String> found = new List<String>();
        if (ld == null) {
            return found;
        }
        String company = String.isBlank(ld.Company) ? null : ld.Company.trim();
        String brn = String.isBlank(ld.Business_Registration_Number__c) ? null : ld.Business_Registration_Number__c.trim();
        String companyLike = company == null ? null : company + '%';

        if (company != null || brn != null) {
            for (Account acc : [
                SELECT Name, Owner.Name FROM Account
                WHERE (Name LIKE :companyLike) OR (Business_Registration_Number__c = :brn)
                WITH USER_MODE
                ORDER BY CreatedDate DESC
                LIMIT 3
            ]) {
                found.add('Account「' + acc.Name.trim() + '」(소유자 ' + acc.Owner.Name + ')');
            }
        }
        if (String.isNotBlank(ld.Email)) {
            for (Contact c : [
                SELECT Name, Account.Name FROM Contact
                WHERE Email = :ld.Email
                WITH USER_MODE
                ORDER BY CreatedDate DESC
                LIMIT 3
            ]) {
                found.add('Contact「' + c.Name + '」(' + (c.Account != null ? c.Account.Name : '소속 없음') + ')');
            }
        }
        return found;
    }
}