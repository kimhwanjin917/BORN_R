/**
 * docs/51 · ADR-0002 — 미팅 중 추천.
 * Meeting_Note__c 가 저장되어 정제본(Sanitized_Content__c)이 생기면, 트리거 트랜잭션 밖(Queueable)에서
 * RM_Assistant 에이전트를 Flow 에이전트 액션(AgentFlowClient, docs/60)으로 호출해 상품 추천 답을 받아
 *   - Meeting_Note__c.Product_Recommendation__c (메모별 원문)
 *   - Opportunity.Last_Recommendation__c        (최신값)
 * 에 기록한다. 원문(Raw_Content__c)은 절대 에이전트에 보내지 않는다 — 발화에는 기회 Id 와 메모 Id 만 넣고,
 * 메모 본문은 에이전트가 자신의 액션(GetSanitizedMeetingNote)으로 정제본만 읽는다.
 *
 * 실패해도 메모 저장은 성공한 상태다. 실패 사유는 메모의 추천 필드에 "[추천 실패] …" 로 남겨 화면에서 보이게 한다.
 */
public with sharing class MeetingNoteAgentRecommender implements Queueable, Database.AllowsCallouts {

    public static final String FAILURE_PREFIX = '[추천 실패] ';
    public static Boolean bypass = false; // 자기 자신(또는 추가 질문 컨트롤러)의 필드 갱신으로 트리거가 재진입하는 것을 막는 보조 플래그

    private final List<Id> noteIds;

    public MeetingNoteAgentRecommender(List<Id> noteIds) {
        this.noteIds = noteIds;
    }

    /** 트리거 진입점: 정제본이 새로 생기거나 바뀐 메모만 큐에 넣는다. */
    public static void enqueueForNotes(List<Meeting_Note__c> newNotes, Map<Id, Meeting_Note__c> oldMap) {
        if (bypass) {
            return;
        }
        List<Id> targets = new List<Id>();
        for (Meeting_Note__c note : newNotes) {
            if (String.isBlank(note.Sanitized_Content__c) || note.Opportunity__c == null) {
                continue;
            }
            Meeting_Note__c old = oldMap == null ? null : oldMap.get(note.Id);
            Boolean sanitizedChanged = old == null || old.Sanitized_Content__c != note.Sanitized_Content__c;
            if (sanitizedChanged) {
                targets.add(note.Id);
            }
        }
        if (targets.isEmpty()) {
            return;
        }
        if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
            System.enqueueJob(new MeetingNoteAgentRecommender(targets));
        } else {
            System.debug(LoggingLevel.WARN, 'Queueable 한도 초과로 미팅 중 추천을 건너뜀: ' + targets);
        }
    }

    public void execute(QueueableContext ctx) {
        List<Meeting_Note__c> notes = [
            SELECT Id, Name, Opportunity__c, Opportunity__r.Name, Opportunity__r.Account.Name
            FROM Meeting_Note__c
            WHERE Id IN :noteIds
        ];
        List<Meeting_Note__c> noteUpdates = new List<Meeting_Note__c>();
        List<Opportunity> oppUpdates = new List<Opportunity>();
        // 콜아웃은 트랜잭션당 100건 한도 × 3콜/메모 — 메모 30건 초과는 다음 잡으로 넘긴다.
        Integer processed = 0;
        List<Id> remaining = new List<Id>();
        for (Meeting_Note__c note : notes) {
            if (processed >= 30) {
                remaining.add(note.Id);
                continue;
            }
            processed++;
            String result;
            String sessionId;
            try {
                AgentFlowClient.Reply reply = AgentFlowClient.ask(buildUtterance(note));
                result = reply.text;
                sessionId = reply.sessionId;
            } catch (Exception e) {
                result = FAILURE_PREFIX + e.getMessage().abbreviate(1000);
                System.debug(LoggingLevel.ERROR, '미팅 중 추천 실패 note=' + note.Id + ' : ' + e.getMessage());
            }
            noteUpdates.add(new Meeting_Note__c(Id = note.Id, Product_Recommendation__c = result, Agent_Session_Id__c = sessionId));
            if (!result.startsWith(FAILURE_PREFIX)) {
                oppUpdates.add(new Opportunity(Id = note.Opportunity__c, Last_Recommendation__c = result));
            }
        }
        bypass = true;
        try {
            if (!noteUpdates.isEmpty()) {
                update as user noteUpdates;
            }
            if (!oppUpdates.isEmpty()) {
                update as user oppUpdates;
            }
        } finally {
            bypass = false;
        }
        if (!remaining.isEmpty() && !Test.isRunningTest()) {
            System.enqueueJob(new MeetingNoteAgentRecommender(remaining));
        }
    }

    /** 에이전트 발화. 본문은 넣지 않는다(정제본은 에이전트 액션이 읽음). */
    @TestVisible
    private static String buildUtterance(Meeting_Note__c note) {
        String oppLabel = note.Opportunity__r == null ? '' : note.Opportunity__r.Name;
        String accLabel = (note.Opportunity__r == null || note.Opportunity__r.Account == null)
            ? '' : note.Opportunity__r.Account.Name;
        return '기회 Id ' + note.Opportunity__c + ' (기회명: ' + oppLabel + ', 고객사: ' + accLabel + ') 의 '
            + '방금 저장된 미팅 메모(메모 Id ' + note.Id + ') 기준으로 상품을 추천해줘. '
            + '기회 검색 없이 이 기회 Id 를 그대로 사용하고, 미팅 메모 마스킹본 조회와 상품 추천 후보 조회를 실행한 뒤 '
            + '① 기준 상품 유지 여부 ② 추천 상품 1~3개와 근거 ③ 보유상품 만기 안내 순서로 답해줘. '
            + '③으로 답을 끝내고, 마무리 인사나 추가 질문을 유도하는 문장은 붙이지 마.';
    }
}