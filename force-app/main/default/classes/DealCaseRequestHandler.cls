/**
 * Slack 딜 카드 [판매 승인 요청(Case 생성)] 처리 — 상품팀 전달 후 심사(Screening) Case 를 만든다.
 * BoniSlackEventsRest(게스트) → BoniSlackEventHandler.block_actions 에서 handle() 호출.
 *
 * 만드는 Case (docs/case 다이어그램 · B안): RecordType=Screening
 *  - OwnerId           = 영업기회 Owner(요청 RM)
 *  - Opportunity__c    = 딜 카드의 Opportunity
 *  - AccountId         = 영업기회 법인고객
 *  - Agreed_Yield_Rate__c = 확정 약정수익률(Pending_Yield__c ?? RP_Yield__c, 이력추적 ON → 중간 변경값도 남음)
 *  - Contract_Term_Months__c = 입력한 계약 기간(개월)
 *  - Description       = 입력한 Case 사유
 * 같은 기회에 심사 Case 가 이미 있으면 새로 만들지 않고 그 Case 를 갱신한다(중복 방지 · B안: 전달 때 생성/갱신).
 *
 * DML 컨텍스트 (DealTermReplyHandler / DealApprovalHandler 와 동일한 우회 패턴):
 *  - Site Guest User 는 표준 오브젝트(Case/Opportunity) 조회·DML 이 막힌다(2026-08-31 실측) → 게스트면
 *    Boni_Slack_Event__e(EVENT_CREATE) 를 발행하고, BoniSlackEventTrigger(Automated Process)가 createFromEvent 로 Case 를 만든다.
 *  - Salesforce/시스템 컨텍스트는 직접 DML.
 * 형제 핸들러와 같은 이유로 without sharing (게스트 대신 시스템 컨텍스트가 표준오브젝트 DML 을 수행).
 * 어떤 예외도 REST 로 새지 않게 handle() 전체를 try 로 감싼다(Slack 은 200 을 기대).
 */
public without sharing class DealCaseRequestHandler {

    /** Boni_Slack_Event__e.Event_Type__c — 게스트가 발행, 트리거가 심사 Case 를 만든다. */
    public static final String EVENT_CREATE = 'deal_case_create';

    /** 심사 Case RecordType 개발자명. */
    private static final String RT_SCREENING = 'Screening';

    /** 테스트용: true 면 게스트가 아니어도 이벤트 경로를 탄다. */
    @TestVisible private static Boolean forceEventPath = false;

    public static void handle(Map<String, Object> p) {
        try {
            handleInternal(p);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DealCaseRequestHandler 실패: ' + e.getMessage() + '\n' + e.getStackTraceString());
        }
    }

    private static void handleInternal(Map<String, Object> p) {
        Id oppId;
        for (Object a : (List<Object>) p.get('actions')) {
            Map<String, Object> am = (Map<String, Object>) a;
            if (String.valueOf(am.get('action_id')) == OpportunityDealChannelService.ACTION_CASE_CREATE) {
                oppId = parseId(String.valueOf(am.get('value')));
            }
        }
        if (oppId == null) {
            System.debug(LoggingLevel.WARN, 'deal_case_create: value 가 Opportunity Id 가 아님 — 무시');
            return;
        }
        Decimal termMonths = parseDecimal(stateValue(p, OpportunityDealChannelService.BLOCK_TERM_MONTHS, OpportunityDealChannelService.ACTION_TERM_MONTHS));
        String reason = stateValue(p, OpportunityDealChannelService.BLOCK_CASE_REASON, OpportunityDealChannelService.ACTION_CASE_REASON);
        create(oppId, termMonths, reason);
    }

    /**
     * Case 생성 공용 진입점 — Slack 카드와 (필요 시)Salesforce 화면이 함께 쓴다.
     * 게스트면 이벤트를 발행해 트리거가 만들고, 아니면 직접 만든다.
     */
    public static void create(Id oppId, Decimal termMonths, String reason) {
        Map<String, Object> payload = new Map<String, Object>{
            'oppId' => String.valueOf(oppId),
            'termMonths' => termMonths,
            'reason' => reason
        };
        if (forceEventPath || UserInfo.getUserType() == 'Guest') {
            Database.SaveResult sr = EventBus.publish(new Boni_Slack_Event__e(Event_Type__c = EVENT_CREATE, Payload__c = JSON.serialize(payload)));
            if (!sr.isSuccess()) {
                throw new DealCaseRequestException('Case 생성 이벤트 발행 실패: ' + sr.getErrors()[0].getMessage());
            }
        } else {
            createFromPayload(payload);
        }
    }

    /** BoniSlackEventTrigger(Automated Process) 에서 호출 — EVENT_CREATE 페이로드로 심사 Case 를 만든다. */
    public static void createFromEvent(Map<String, Object> p) {
        // TEMP DIAG: 진입 자체를 조회 가능한 곳에 남긴다.
        try {
            update new Opportunity(Id = (Id) String.valueOf(p.get('oppId')),
                Description = 'DIAG ENTER createFromEvent');
        } catch (Exception ignore) {}
        try {
            createFromPayload(p);
        } catch (Exception e) {
            try {
                update new Opportunity(Id = (Id) String.valueOf(p.get('oppId')),
                    Description = 'DIAG EX ' + e.getTypeName() + ': ' + e.getMessage());
            } catch (Exception ignore) {}
            throw e;
        }
    }

    private static void createFromPayload(Map<String, Object> p) {
        Id oppId = (Id) String.valueOf(p.get('oppId'));
        Decimal termMonths = p.get('termMonths') == null ? null : Decimal.valueOf(String.valueOf(p.get('termMonths')));
        String reason = p.get('reason') == null ? null : String.valueOf(p.get('reason'));

        // 시스템 컨텍스트: 기회에서 법인·Owner·확정 약정수익률·계약기간(개월)을 읽어 Case 필드를 채운다.
        Opportunity opp = [
            SELECT Id, Name, AccountId, OwnerId, RP_Yield__c, Pending_Yield__c, Account.Name,
                   Contract_Start_Date__c, RP_Maturity_Date__c
            FROM Opportunity WHERE Id = :oppId
        ];

        // 계약 기간(개월)이 넘어오지 않았으면 최초 매매일~환매일 사이 개월수로 계산한다.
        if (termMonths == null && opp.Contract_Start_Date__c != null && opp.RP_Maturity_Date__c != null
                && opp.RP_Maturity_Date__c >= opp.Contract_Start_Date__c) {
            termMonths = opp.Contract_Start_Date__c.monthsBetween(opp.RP_Maturity_Date__c);
        }

        // 심사(Screening) RT 는 실행 사용자(게스트→Automated Process 포함) 프로필에 할당돼 있을 때만 설정한다.
        // 미할당이면 RT 지정이 INVALID_CROSS_REFERENCE_KEY 로 터지므로, 기본 RT 로 만들어 크래시를 피한다.
        // (심사 RT 로 확실히 만들려면 해당 RT 를 관련 프로필에 할당해야 한다 — org UI 설정.)
        Schema.RecordTypeInfo rtInfo = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get(RT_SCREENING);
        Id rtId = (rtInfo != null && rtInfo.isAvailable()) ? rtInfo.getRecordTypeId() : null;

        // 같은 기회의 Case 가 이미 있으면 갱신, 없으면 새로 만든다(중복 방지 — DealApprovalHandler 와 같은 기준: Opportunity__c).
        List<Case> existing = [SELECT Id, Subject FROM Case WHERE Opportunity__c = :oppId ORDER BY CreatedDate DESC LIMIT 1];
        Case c = existing.isEmpty() ? new Case() : existing[0];
        if (rtId != null) {
            c.RecordTypeId = rtId;
        }
        c.Opportunity__c = oppId;
        c.AccountId = opp.AccountId;
        c.OwnerId = opp.OwnerId;
        Decimal effectiveYield = opp.Pending_Yield__c != null ? opp.Pending_Yield__c : opp.RP_Yield__c;
        if (effectiveYield != null) {
            c.Agreed_Yield_Rate__c = effectiveYield;
        }
        if (termMonths != null) {
            c.Contract_Term_Months__c = termMonths;
        }
        if (String.isNotBlank(reason)) {
            c.Description = reason;
        }
        if (String.isBlank(c.Subject)) {
            String company = String.isNotBlank(opp.Account?.Name) ? opp.Account.Name : opp.Name;
            c.Subject = '[' + company + '] ' + opp.Name + ' 판매 승인 요청';
        }
        upsert c;
    }

    public class DealCaseRequestException extends Exception {}

    private static Id parseId(String raw) {
        try {
            Id candidate = (Id) raw;
            return candidate.getSobjectType() == Opportunity.SObjectType ? candidate : null;
        } catch (Exception e) {
            return null;
        }
    }

    private static String stateValue(Map<String, Object> p, String blockId, String actionId) {
        try {
            Map<String, Object> values = (Map<String, Object>) ((Map<String, Object>) p.get('state')).get('values');
            Map<String, Object> block = (Map<String, Object>) values.get(blockId);
            Map<String, Object> el = (Map<String, Object>) block.get(actionId);
            Object v = el.get('value');
            return v == null ? null : String.valueOf(v);
        } catch (Exception e) {
            return null;
        }
    }

    private static Decimal parseDecimal(String raw) {
        if (String.isBlank(raw)) {
            return null;
        }
        try {
            return Decimal.valueOf(raw.trim().replace(',', ''));
        } catch (Exception e) {
            return null;
        }
    }
}