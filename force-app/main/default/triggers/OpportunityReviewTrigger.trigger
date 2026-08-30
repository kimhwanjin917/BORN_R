/**
 * docs/58 Scene 3 (2026-08-28, ADR-0004) — 비활성(Inactive).
 * 미팅 로그 저장 시 자동 심사(ADR-0003)도, 자동 딜 채널 생성도 하지 않는다.
 * 상품팀 전달은 Opportunity 의 [상품팀 전달] 버튼(sendToProductTeamAction → DealTermCollabController.sendToProductTeam),
 * 심사·계약서는 [계약서 생성](DealTermCollabController.createContract) 이 맡는다.
 * 파일과 이름은 되돌리기 쉽게 남긴다. 이전 본문: docs/rollback/2026-08-28_scene3/.
 */
trigger OpportunityReviewTrigger on Opportunity (after update) {
    OpportunityDealChannelService.enqueueForOpportunities(Trigger.new, Trigger.oldMap);
}