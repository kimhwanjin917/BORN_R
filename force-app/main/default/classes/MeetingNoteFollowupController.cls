/**
 * docs/60 — 미팅 메모 화면의 "Agentforce에 추가 질문".
 * 메모 등록 때 저장된 Agent_Session_Id__c 로 같은 대화를 이어가 답을 받고,
 * 질문·답변을 Product_Recommendation__c 뒤에 덧붙여 [미팅 저장] 시 함께 남게 한다.
 */
public with sharing class MeetingNoteFollowupController {

    public class FollowupResult {
        @AuraEnabled public String answer;
        @AuraEnabled public String recommendation; // 질문·답변이 덧붙은 전체 추천 본문
    }

    @AuraEnabled
    public static FollowupResult askFollowup(Id meetingNoteId, String question) {
        if (meetingNoteId == null || String.isBlank(question)) {
            throw new AuraHandledException('메모 Id 와 질문이 모두 필요합니다.');
        }
        List<Meeting_Note__c> notes = [
            SELECT Id, Product_Recommendation__c, Agent_Session_Id__c,
                   Opportunity__c, Opportunity__r.Name, Opportunity__r.Account.Name,
                   Contact__r.Name
            FROM Meeting_Note__c
            WHERE Id = :meetingNoteId
            WITH USER_MODE
            LIMIT 1
        ];
        if (notes.isEmpty()) {
            throw new AuraHandledException('메모를 찾을 수 없습니다.');
        }
        Meeting_Note__c note = notes[0];
        if (String.isBlank(note.Product_Recommendation__c)
            || note.Product_Recommendation__c.startsWith(MeetingNoteAgentRecommender.FAILURE_PREFIX)) {
            throw new AuraHandledException('먼저 추천이 생성된 뒤에 추가 질문을 할 수 있습니다.');
        }
        // 개인정보만 막는다: 질문도 메모와 같은 MaskingService(진승혜) 로 가린 뒤 보낸다. 기업명·기회 정보는 허용.
        String accountName = note.Opportunity__r == null || note.Opportunity__r.Account == null
            ? null : note.Opportunity__r.Account.Name;
        String maskedQuestion = MaskingService.mask(
            question.trim(),
            note.Contact__r == null ? null : note.Contact__r.Name,
            accountName
        ).sanitizedText;
        AgentFlowClient.Reply reply;
        try {
            reply = AgentFlowClient.ask(buildFollowupUtterance(note, maskedQuestion), note.Agent_Session_Id__c);
        } catch (Exception e) {
            throw new AuraHandledException('추가 질문에 답하지 못했습니다: ' + e.getMessage());
        }
        FollowupResult result = new FollowupResult();
        result.answer = reply.text;
        result.recommendation = note.Product_Recommendation__c
            + '\n\n[추가 질문] ' + maskedQuestion
            + '\n[답변] ' + reply.text;
        Meeting_Note__c upd = new Meeting_Note__c(Id = note.Id, Product_Recommendation__c = result.recommendation);
        if (!String.isBlank(reply.sessionId)) {
            upd.Agent_Session_Id__c = reply.sessionId;
        }
        MeetingNoteAgentRecommender.bypass = true;
        try {
            update as user upd;
        } finally {
            MeetingNoteAgentRecommender.bypass = false;
        }
        return result;
    }

    /**
     * 어느 토픽으로 라우팅되든 "지금 어떤 기회·고객사 얘기 중인지" 를 잃지 않도록
     * 기회 Id·기회명·고객사를 매번 앞에 붙인다. (docs/60 — 일반 토픽이 맥락 없이 답하던 문제)
     */
    @TestVisible
    private static String buildFollowupUtterance(Meeting_Note__c note, String maskedQuestion) {
        String oppName = note.Opportunity__r == null ? '' : note.Opportunity__r.Name;
        String accName = (note.Opportunity__r == null || note.Opportunity__r.Account == null)
            ? '' : note.Opportunity__r.Account.Name;
        return '지금 진행 중인 기회 Id ' + note.Opportunity__c
            + ' (기회명: ' + oppName + ', 고객사: ' + accName + ') 에 대해, '
            + '방금 준 상품 추천을 바탕으로 한 추가 질문입니다. 이 기회와 고객사 맥락을 기준으로 답해줘: '
            + maskedQuestion;
    }
}