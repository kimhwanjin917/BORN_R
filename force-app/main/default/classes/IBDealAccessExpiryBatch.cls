/**
 * 시간이 흘러 접근이 끊겨야 하는 딜을 찾아 공유를 회수한다.
 * 일 1회 스케줄 실행을 전제로 한다.
 *
 * 트리거는 멤버 레코드가 "바뀔 때"만 돌기 때문에, 시간만 지나간 경우는 잡지 못한다.
 * 이 배치가 그 구멍을 메운다. 두 가지를 본다.
 *
 *   • 딜의 Barrier_End_At__c 가 지난 경우 — 딜팀 임기 종료. 전원 회수.
 *   • 멤버의 Access_Ended_At__c 가 지난 경우 — 그 사람만 회수.
 *
 * 회수 여부 판단은 IBDealSharingService 가 하므로, 배치는 차단벽이 살아 있는 딜을
 * 모아 재계산만 부른다. 두 조건을 하나의 WHERE 로 좁히려면 semi-join 과 OR 를 같이
 * 써야 하는데 SOQL 이 허용하지 않는다. 대신 활성 딜을 매일 재계산하는 방식으로 두었다.
 * 만료뿐 아니라 어떤 이유로 어긋난 공유든 하루 안에 제자리로 돌아온다.
 */
public with sharing class IBDealAccessExpiryBatch implements Database.Batchable<sObject>, Schedulable {

    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([
            SELECT Id
            FROM IB_Deal__c
            WHERE Information_Barrier_Status__c = 'Active'
        ]);
    }

    public void execute(Database.BatchableContext bc, List<IB_Deal__c> scope) {
        Set<Id> dealIds = new Map<Id, IB_Deal__c>(scope).keySet();
        IBDealSharingService.recalculate(dealIds);
    }

    public void finish(Database.BatchableContext bc) {
        // 후처리 없음
    }

    /** 스케줄러 진입점 */
    public void execute(SchedulableContext sc) {
        Database.executeBatch(new IBDealAccessExpiryBatch(), 200);
    }
}