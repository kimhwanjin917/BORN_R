/**
 * docs/51 — 미팅 중 추천 진입점. 진승혜 님의 MeetingNoteTrigger(정제·공유)는 건드리지 않고
 * 별도 after 트리거에서 정제본이 생긴 메모만 MeetingNoteAgentRecommender 큐에 넣는다.
 * (before 트리거의 정제가 끝난 뒤 after 에서 읽으므로 Sanitized_Content__c 가 채워져 있다.)
 */
trigger MeetingNoteRecommendTrigger on Meeting_Note__c (after insert, after update) {
    MeetingNoteAgentRecommender.enqueueForNotes(Trigger.new, Trigger.oldMap);
}