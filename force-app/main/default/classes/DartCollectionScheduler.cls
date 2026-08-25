/**
 * DartCollectionBatch 를 주기 실행하는 스케줄러.
 * 콜아웃+DML 을 회사당 1 execute 로 처리하기 위해 배치 크기를 1 로 실행한다.
 *
 * 스케줄 예시(익명 Apex):
 *   System.schedule('DART 재무제표 수집(연간)', '0 0 4 1 * ?',
 *       new DartCollectionScheduler('2023', '11011'));
 */
public with sharing class DartCollectionScheduler implements Schedulable {
    private final String businessYear;
    private final String reportCode;

    public DartCollectionScheduler(String businessYear, String reportCode) {
        this.businessYear = businessYear;
        this.reportCode = reportCode;
    }

    public void execute(SchedulableContext context) {
        Database.executeBatch(new DartCollectionBatch(businessYear, reportCode), 1);
    }
}