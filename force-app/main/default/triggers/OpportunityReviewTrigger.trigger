/**
 * docs/52 · ADR-0003 — 22번 심사 진입점. 28번 Flow(Opportunity_Meeting_Log_To_Slack)와 같은 조건
 * (Meeting_Log__c 변경)에서, 아직 승인되지 않은 기회를 OpportunityReviewService 큐에 넣는다.
 * 28번 Flow 는 건드리지 않는다.
 */
trigger OpportunityReviewTrigger on Opportunity (after update) {
    OpportunityReviewService.enqueueForOpportunities(Trigger.new, Trigger.oldMap);
}