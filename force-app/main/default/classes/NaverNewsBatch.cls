/**
 * 담당사(Account) 기업명으로 네이버 뉴스를 주기 수집해 ExternalSignal__c 에 적재하는 배치.
 *
 * DART 공시 시그널 수집(DartSignalBatch)과는 독립된 흐름으로, 콜아웃+DML 을 회사당 1
 * execute 로 안전하게 처리하기 위해 scope size 를 1 로 실행한다. 회사별 실패는 서로
 * 격리되며, 실패한 회사는 NaverNewsQueueable 로 위임해 재처리·관리자 알림을 태운다.
 *
 * 네이버 뉴스는 기업명(Account.Name)으로 검색하므로, DART(Assigned_Company_Code__c 보유)와
 * 달리 이름이 있는 모든 Account 를 대상으로 한다.
 */
public with sharing class NaverNewsBatch implements Database.Batchable<SObject>, Database.AllowsCallouts, Database.Stateful {
    // 회사별 결과 누적(로그/후속 확인용)
    private Integer successCount = 0;
    private Integer failureCount = 0;

    public Database.QueryLocator start(Database.BatchableContext context) {
        return Database.getQueryLocator([
            SELECT Id, Name
            FROM Account
            WHERE Name != null
            WITH USER_MODE
        ]);
    }

    public void execute(Database.BatchableContext context, List<Account> scope) {
        for (Account acct : scope) {
            String companyName = acct.Name;
            try {
                NaverNewsService.collectNews(companyName);
                successCount++;
            } catch (NaverNewsService.NaverNewsException e) {
                // 일시적/영구 실패 모두 Queueable 로 위임 → 재시도·최종 실패 시 관리자 알림
                failureCount++;
                System.enqueueJob(new NaverNewsQueueable(companyName));
            }
        }
    }

    public void finish(Database.BatchableContext context) {
        System.debug('네이버 뉴스 수집 배치 완료. 성공: ' + successCount + ', 실패(재처리 위임): ' + failureCount);
    }
}