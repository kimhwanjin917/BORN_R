/**
 * 딜팀 멤버가 바뀌면 해당 딜의 Apex 공유를 다시 계산한다.
 * 등록/수정 → 접근 부여, 기간 만료 → 접근 회수.
 *
 * 저장 전에는 두 가지를 더 한다.
 *   • 월크로스 일시가 비어 있으면 등록 시각으로 채운다 (기입 누락 방지)
 *   • 삭제를 막는다 — 명단에서 지우는 대신 접근 종료 일시를 채우게 한다 (이력 보존)
 */
trigger IBDealTeamMemberTrigger on IB_Deal_Team_Member__c (
    before insert, before delete,
    after insert, after update, after delete, after undelete
) {
    if (Trigger.isBefore) {
        if (Trigger.isInsert) {
            IBDealSharingService.stampWallCrossing(Trigger.new);
        } else if (Trigger.isDelete) {
            IBDealSharingService.blockDeletion(Trigger.old);
        }
        return;
    }

    Set<Id> dealIds = new Set<Id>();

    if (Trigger.isDelete) {
        dealIds.addAll(IBDealSharingService.dealIdsOf(Trigger.old));
    } else {
        dealIds.addAll(IBDealSharingService.dealIdsOf(Trigger.new));
        if (Trigger.isUpdate) {
            // 멤버가 다른 딜로 옮겨간 경우 이전 딜도 재계산해야 한다
            dealIds.addAll(IBDealSharingService.dealIdsOf(Trigger.old));
        }
    }

    IBDealSharingService.recalculate(dealIds);
}