/**
 * 담당사(Account.Assigned_Company_Code__c 보유) 공시를 주기 수집해
 * CorporateFinancialStatement__c 에 External_Key__c 기준 upsert 하는 배치.
 *
 * 콜아웃과 DML 을 한 트랜잭션에서 안전하게 처리하기 위해 scope size 를 1 로 고정한다
 * (회사당 1 execute → 콜아웃 1회 + upsert 1회). 회사별 실패는 서로 격리되며,
 * 일시적 오류는 DartCollectionQueueable 로 위임해 재처리·관리자 알림을 태운다.
 */
public with sharing class DartCollectionBatch implements Database.Batchable<SObject>, Database.AllowsCallouts, Database.Stateful {
    private final String businessYear;
    private final String reportCode;

    // 회사별 실패 누적(로그/후속 확인용)
    private Integer successCount = 0;
    private Integer failureCount = 0;

    /**
     * @param businessYear 사업연도(예: '2023')
     * @param reportCode 보고서 코드(11011/11012/11013/11014)
     */
    public DartCollectionBatch(String businessYear, String reportCode) {
        if (String.isBlank(businessYear) || String.isBlank(reportCode)) {
            throw new IllegalArgumentException('businessYear, reportCode 는 필수입니다.');
        }
        this.businessYear = businessYear;
        this.reportCode = reportCode;
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
                DartFinancialService.collectFinancials(corpCode, businessYear, reportCode);
                successCount++;
            } catch (DartFinancialService.DartServiceException e) {
                // 일시적/영구 실패 모두 Queueable 로 위임 → 재시도·최종 실패 시 관리자 알림
                failureCount++;
                System.enqueueJob(new DartCollectionQueueable(corpCode, businessYear, reportCode));
            }
        }
    }

    public void finish(Database.BatchableContext context) {
        System.debug('DART 수집 배치 완료. 성공: ' + successCount + ', 실패(재처리 위임): ' + failureCount);
    }
}