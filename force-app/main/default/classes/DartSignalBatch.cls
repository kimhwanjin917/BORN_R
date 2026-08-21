/**
 * 담당사(Account.Assigned_Company_Code__c 보유)의 공시 시그널(설비투자·차입)을 주기 수집해
 * ExternalSignal__c 에 External_Key__c 기준 upsert 하는 배치.
 *
 * 재무제표 수집(DartCollectionBatch)과는 독립된 흐름이다(ERD 상 재무제표·외부 영업신호는
 * 서로 관계 없는 별도 오브젝트). 콜아웃+DML 을 회사당 1 execute 로 안전하게 처리하기 위해
 * scope size 를 1 로 실행한다. 회사별 실패는 서로 격리되며, 일시적 오류는
 * DartSignalQueueable 로 위임해 재처리·관리자 알림을 태운다.
 */
public with sharing class DartSignalBatch implements Database.Batchable<SObject>, Database.AllowsCallouts, Database.Stateful {
    private final String beginDate;
    private final String endDate;

    // 회사별 실패 누적(로그/후속 확인용)
    private Integer successCount = 0;
    private Integer failureCount = 0;

    /**
     * @param beginDate 조회 시작일(YYYYMMDD)
     * @param endDate 조회 종료일(YYYYMMDD)
     */
    public DartSignalBatch(String beginDate, String endDate) {
        if (String.isBlank(beginDate) || String.isBlank(endDate)) {
            throw new IllegalArgumentException('beginDate, endDate 는 필수입니다.');
        }
        this.beginDate = beginDate;
        this.endDate = endDate;
    }

    public Database.QueryLocator start(Database.BatchableContext context) {
        return Database.getQueryLocator([
            SELECT Id, Assigned_Company_Code__c
            FROM Account
            WHERE Assigned_Company_Code__c != null
            WITH USER_MODE
        ]);
    }

    public void execute(Database.BatchableContext context, List<Account> scope) {
        for (Account acct : scope) {
            String corpCode = acct.Assigned_Company_Code__c;
            try {
                DartSignalService.collectSignals(corpCode, beginDate, endDate);
                successCount++;
            } catch (DartSignalService.DartServiceException e) {
                // 일시적/영구 실패 모두 Queueable 로 위임 → 재시도·최종 실패 시 관리자 알림
                failureCount++;
                System.enqueueJob(new DartSignalQueueable(corpCode, beginDate, endDate));
            }
        }
    }

    public void finish(Database.BatchableContext context) {
        System.debug('DART 시그널 수집 배치 완료. 성공: ' + successCount + ', 실패(재처리 위임): ' + failureCount);
    }
}