/**
 * DartSignalBatch 를 주기 실행하는 스케줄러.
 * 콜아웃+DML 을 회사당 1 execute 로 처리하기 위해 배치 크기를 1 로 실행한다.
 *
 * 스케줄 예시(익명 Apex):
 *   System.schedule('DART 공시 시그널 수집(연간)', '0 0 5 1 * ?',
 *       new DartSignalScheduler('20230101', '20231231'));
 */
public with sharing class DartSignalScheduler implements Schedulable {
    private final String beginDate;
    private final String endDate;

    public DartSignalScheduler(String beginDate, String endDate) {
        this.beginDate = beginDate;
        this.endDate = endDate;
    }

    public void execute(SchedulableContext context) {
        Database.executeBatch(new DartSignalBatch(beginDate, endDate), 1);
    }
}