/**
 * 딜을 지울 때 딸린 딜팀 멤버까지 함께 지워지도록 그 딜의 Id 를 남긴다.
 *
 * IB_Deal_Team_Member__c 는 삭제가 막혀 있는데(이력 보존), 마스터-디테일 연쇄 삭제에서
 * 그 차단이 그대로 걸리면 딜 자체를 지울 수 없게 된다. 지워지는 딜의 자식만 통과시킨다.
 */
trigger IBDealTrigger on IB_Deal__c (before delete) {
    IBDealSharingService.dealsBeingDeleted.addAll(Trigger.oldMap.keySet());
}