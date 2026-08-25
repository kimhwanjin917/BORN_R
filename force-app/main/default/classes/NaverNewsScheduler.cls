/**
 * NaverNewsBatch 를 주기 실행하는 스케줄러.
 * 콜아웃+DML 을 회사당 1 execute 로 처리하기 위해 배치 크기를 1 로 실행한다.
 *
 * 스케줄 예시(익명 Apex):
 *   System.schedule('네이버 뉴스 수집(매일 06시)', '0 0 6 * * ?', new NaverNewsScheduler());
 */
public with sharing class NaverNewsScheduler implements Schedulable {
    public void execute(SchedulableContext context) {
        Database.executeBatch(new NaverNewsBatch(), 1);
    }
}