/**
 * Meeting Session 진입 레코드에서 Meeting_Note__c 가 저장해야 할 관계를 해석한다.
 *
 * 진입점마다 알 수 있는 값이 다르므로, "알 수 있는 것만 채우고 모르는 것은 null 로 둔다"가
 * 이 클래스의 유일한 규칙이다. 특히 Opportunity 는 절대 추측하지 않는다 — 고객사에 진행 중인
 * 기회가 정확히 1건일 때만 자동 연결하고, 0건이거나 2건 이상이면 비워 두고 안내 문구만 남긴다.
 *
 * 해석 규칙:
 *   Opportunity → opportunityId = 그 기회, accountId = Opportunity.AccountId
 *                 contactId 는 Primary OpportunityContactRole 이 있을 때만 채운다.
 *                 Primary 가 없고 Contact Role 이 정확히 1명이면 그 1명을 쓴다.
 *                 0명이거나 여러 명인데 Primary 가 없으면 비워 둔다 — 고객사의
 *                 아무 Contact 나 고르지 않는다.
 *   Event       → eventId = 그 일정, meetingDate = ActivityDate
 *                 WhatId 가 Opportunity 면 그 기회(+ 그 기회의 고객사)
 *                 WhatId 가 Account   면 그 고객사(+ 진행 중 기회가 1건일 때만 그 기회)
 *                 WhoId  가 Contact   면 contactId(+ 고객사가 아직 없으면 Contact.AccountId)
 *                 WhoId 는 Contact/Lead 를 가리키므로 기회 해석에 절대 사용하지 않는다.
 *   Contact     → contactId = 그 담당자, accountId = Contact.AccountId
 *   Account     → accountId = 그 고객사
 *   Lead        → 전환된 리드만 ConvertedOpportunityId / ConvertedAccountId / ConvertedContactId 사용
 *
 * 어떤 경로에서도 Opportunity 나 Account 를 새로 생성하지 않는다.
 *
 * Event 는 커스텀 Lookup 대상이 될 수 없어(Salesforce: referenceTo value of Event does not
 * resolve to a valid sObject type) Meeting_Note__c.Event_Id__c 텍스트로 보관한다.
 */
public with sharing class MeetingNoteContextService {

    // ─── Flow 용 DTO ──────────────────────────────────────────────────────

    public class Request {
        @InvocableVariable(
            label='진입 레코드 Id'
            description='미팅 세션을 시작한 레코드(Opportunity / Event / Contact / Account / Lead)의 Id'
            required=true)
        public String recordId;

        @InvocableVariable(
            label='선택된 기회 Id'
            description='화면에서 사용자가 기회를 직접 고른 경우에만 채운다. 비어 있으면 진입 레코드에서 해석한다.')
        public String selectedOpportunityId;
    }

    public class Result {
        @InvocableVariable(label='고객사 Id') public String accountId;
        @InvocableVariable(label='담당자 Id') public String contactId;
        @InvocableVariable(label='기회 Id') public String opportunityId;
        @InvocableVariable(label='일정 Id') public String eventId;
        @InvocableVariable(label='미팅일') public Date meetingDate;
        @InvocableVariable(label='진입 객체 API명') public String sourceObject;
        @InvocableVariable(label='안내 문구') public String message;
    }

    /** LWC 용 DTO. Task 2 의 Timeline / Launcher 가 같은 해석 결과를 쓰도록 별도로 노출한다. */
    public class ContextView {
        @AuraEnabled public String accountId;
        @AuraEnabled public String contactId;
        @AuraEnabled public String opportunityId;
        @AuraEnabled public String eventId;
        @AuraEnabled public Date meetingDate;
        @AuraEnabled public String sourceObject;
        @AuraEnabled public String message;
    }

    // ─── 진입점 ───────────────────────────────────────────────────────────

    @InvocableMethod(
        label='Resolve Meeting Note Context'
        description='진입 레코드에서 Meeting Note 가 저장할 Account / Contact / Opportunity / Event 관계와 미팅일을 해석한다.'
        category='Sales')
    public static List<Result> resolveContext(List<Request> requests) {
        List<Result> results = new List<Result>();
        if (requests == null || requests.isEmpty()) {
            return results;
        }
        for (Request req : requests) {
            results.add(resolveOne(req));
        }
        return results;
    }

    /** Task 2 인터페이스: 레코드 페이지에서 같은 해석 결과를 읽는다. */
    @AuraEnabled(cacheable=true)
    public static ContextView getContext(Id recordId, Id selectedOpportunityId) {
        Request req = new Request();
        req.recordId = recordId == null ? null : String.valueOf(recordId);
        req.selectedOpportunityId = selectedOpportunityId == null ? null : String.valueOf(selectedOpportunityId);

        Result resolved = resolveOne(req);
        ContextView view = new ContextView();
        view.accountId = resolved.accountId;
        view.contactId = resolved.contactId;
        view.opportunityId = resolved.opportunityId;
        view.eventId = resolved.eventId;
        view.meetingDate = resolved.meetingDate;
        view.sourceObject = resolved.sourceObject;
        view.message = resolved.message;
        return view;
    }

    // ─── 해석 ─────────────────────────────────────────────────────────────

    private static Result resolveOne(Request req) {
        Result result = new Result();
        result.meetingDate = Date.today();

        Id recordId = toId(req == null ? null : req.recordId);
        if (recordId == null) {
            result.message = '진입 레코드 Id가 전달되지 않았거나 형식이 올바르지 않습니다.';
            return result;
        }

        String apiName = recordId.getSObjectType().getDescribe().getName();
        result.sourceObject = apiName;

        if (apiName == 'Opportunity') {
            result.opportunityId = String.valueOf(recordId);
            applyOpportunityContact(recordId, result);
        } else if (apiName == 'Event') {
            applyEvent(recordId, result);
        } else if (apiName == 'Contact') {
            applyContact(recordId, result);
        } else if (apiName == 'Account') {
            result.accountId = String.valueOf(recordId);
        } else if (apiName == 'Lead') {
            applyLead(recordId, result);
        } else {
            result.message = apiName + ' 에서는 미팅 기록 관계를 자동으로 해석할 수 없습니다.';
        }

        // 사용자가 화면에서 고른 기회가 있으면 해석 결과보다 우선한다.
        Id selected = toId(req.selectedOpportunityId);
        if (selected != null && selected.getSObjectType() == Opportunity.SObjectType) {
            result.opportunityId = String.valueOf(selected);
        }

        // 고객사가 아직 비어 있고 기회가 정해졌으면 기회의 고객사로 채운다.
        if (String.isBlank(result.accountId) && String.isNotBlank(result.opportunityId)) {
            result.accountId = accountIdOfOpportunity(toId(result.opportunityId));
        }

        // 고객사만 있고 기회가 없으면, 진행 중 기회가 정확히 1건일 때만 연결한다.
        if (String.isBlank(result.opportunityId) && String.isNotBlank(result.accountId)) {
            applySoleOpenOpportunity(toId(result.accountId), result);
        }

        if (String.isBlank(result.accountId) && String.isBlank(result.message)) {
            result.message = '고객사를 해석하지 못했습니다. 미팅 기록은 저장되지만 고객사 이력에는 연결되지 않습니다.';
        }
        return result;
    }

    private static void applyEvent(Id eventId, Result result) {
        List<Event> events = [
            SELECT Id, ActivityDate, ActivityDateTime, WhatId, WhoId
            FROM Event
            WHERE Id = :eventId
            WITH USER_MODE
            LIMIT 1
        ];
        if (events.isEmpty()) {
            result.message = '일정을 읽을 권한이 없거나 일정이 삭제되었습니다.';
            return;
        }
        Event evt = events[0];
        result.eventId = String.valueOf(evt.Id);
        if (evt.ActivityDate != null) {
            result.meetingDate = evt.ActivityDate;
        } else if (evt.ActivityDateTime != null) {
            result.meetingDate = evt.ActivityDateTime.date();
        }

        // WhatId: 기회 또는 고객사만 사용한다.
        if (evt.WhatId != null) {
            String whatType = evt.WhatId.getSObjectType().getDescribe().getName();
            if (whatType == 'Opportunity') {
                result.opportunityId = String.valueOf(evt.WhatId);
            } else if (whatType == 'Account') {
                result.accountId = String.valueOf(evt.WhatId);
            } else {
                result.message = '이 일정의 관련 레코드가 ' + whatType + ' 라서 기회·고객사를 자동으로 연결할 수 없습니다.';
            }
        }

        // WhoId: Contact 일 때만 담당자 관계로 쓴다. 기회 해석에는 절대 쓰지 않는다.
        if (evt.WhoId != null && evt.WhoId.getSObjectType() == Contact.SObjectType) {
            result.contactId = String.valueOf(evt.WhoId);
            if (String.isBlank(result.accountId)) {
                result.accountId = accountIdOfContact(evt.WhoId);
            }
        }
    }

    private static void applyContact(Id contactId, Result result) {
        result.contactId = String.valueOf(contactId);
        String accountId = accountIdOfContact(contactId);
        if (String.isBlank(accountId)) {
            result.message = '이 담당자에 연결된 고객사가 없습니다.';
            return;
        }
        result.accountId = accountId;
    }

    private static void applyLead(Id leadId, Result result) {
        List<Lead> leads = [
            SELECT Id, IsConverted, ConvertedAccountId, ConvertedContactId, ConvertedOpportunityId
            FROM Lead
            WHERE Id = :leadId
            WITH USER_MODE
            LIMIT 1
        ];
        if (leads.isEmpty()) {
            result.message = '리드를 읽을 권한이 없거나 리드가 삭제되었습니다.';
            return;
        }
        Lead theLead = leads[0];
        if (theLead.IsConverted != true) {
            result.message = '미변환 리드입니다. 전환 후 미팅 세션을 다시 열어 주세요.';
            return;
        }
        if (theLead.ConvertedOpportunityId != null) {
            result.opportunityId = String.valueOf(theLead.ConvertedOpportunityId);
        }
        if (theLead.ConvertedAccountId != null) {
            result.accountId = String.valueOf(theLead.ConvertedAccountId);
        }
        if (theLead.ConvertedContactId != null) {
            result.contactId = String.valueOf(theLead.ConvertedContactId);
        }
    }

    /**
     * 기회에서 시작한 경우의 담당자 해석.
     * Primary Contact Role 을 최우선으로 쓰고, Primary 가 없으면 Contact Role 이
     * 정확히 1명일 때만 그 1명을 쓴다. 그 외에는 비워 둔다 — 고객사에 딸린
     * 아무 Contact 나 고르지 않는다.
     */
    private static void applyOpportunityContact(Id opportunityId, Result result) {
        if (opportunityId == null || String.isNotBlank(result.contactId)) {
            return;
        }
        List<OpportunityContactRole> roles = [
            SELECT ContactId, IsPrimary
            FROM OpportunityContactRole
            WHERE OpportunityId = :opportunityId AND ContactId != null
            WITH USER_MODE
            ORDER BY IsPrimary DESC
        ];
        if (roles.isEmpty()) {
            return;
        }
        if (roles[0].IsPrimary == true) {
            result.contactId = String.valueOf(roles[0].ContactId);
            return;
        }
        if (roles.size() == 1) {
            result.contactId = String.valueOf(roles[0].ContactId);
            return;
        }
        if (String.isBlank(result.message)) {
            result.message = '이 기회에 대표 담당자(Primary Contact Role)가 없어 담당자를 연결하지 않았습니다.';
        }
    }

    /** 진행 중 기회가 정확히 1건일 때만 연결한다. 여러 건이면 임의로 고르지 않는다. */
    private static void applySoleOpenOpportunity(Id accountId, Result result) {
        if (accountId == null) {
            return;
        }
        List<Opportunity> open = [
            SELECT Id
            FROM Opportunity
            WHERE AccountId = :accountId AND IsClosed = false
            WITH USER_MODE
            ORDER BY CloseDate ASC NULLS LAST
            LIMIT 2
        ];
        if (open.size() == 1) {
            result.opportunityId = String.valueOf(open[0].Id);
            return;
        }
        if (String.isBlank(result.message)) {
            result.message = open.isEmpty()
                ? '이 고객사에 진행 중인 기회가 없어 기회 없이 저장됩니다.'
                : '진행 중인 기회가 여러 건이라 자동 연결하지 않았습니다. 기회를 직접 선택해 주세요.';
        }
    }

    // ─── 조회 헬퍼 ────────────────────────────────────────────────────────

    private static String accountIdOfOpportunity(Id opportunityId) {
        if (opportunityId == null) {
            return null;
        }
        List<Opportunity> opps = [
            SELECT AccountId FROM Opportunity WHERE Id = :opportunityId WITH USER_MODE LIMIT 1
        ];
        return opps.isEmpty() || opps[0].AccountId == null ? null : String.valueOf(opps[0].AccountId);
    }

    private static String accountIdOfContact(Id contactId) {
        if (contactId == null) {
            return null;
        }
        List<Contact> contacts = [
            SELECT AccountId FROM Contact WHERE Id = :contactId WITH USER_MODE LIMIT 1
        ];
        return contacts.isEmpty() || contacts[0].AccountId == null ? null : String.valueOf(contacts[0].AccountId);
    }

    /** 잘못된 Id 문자열이 들어와도 예외 대신 null 로 처리한다. */
    private static Id toId(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        try {
            return Id.valueOf(value.trim());
        } catch (Exception ignored) {
            return null;
        }
    }
}