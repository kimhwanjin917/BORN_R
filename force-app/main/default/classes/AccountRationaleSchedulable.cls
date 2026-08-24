/**
 * 매일 오전 6시에 우선순위 상위 기업(Account) 의 사유 생성을 기동하는 스케줄러.
 *
 * 실제 생성·저장은 AccountRationaleQueueable 이 맡는다(프롬프트 템플릿 호출이 콜아웃이라 Queueable 로 분리).
 * PriorityScoreBatch(새벽 3시)가 점수를 갱신한 뒤 실행되도록 6시로 잡아, 최신 점수 상위 Account 를 대상으로 한다.
 */
public with sharing class AccountRationaleSchedulable implements Schedulable {

    @TestVisible private static final String JOB_NAME = 'AccountRationale - Daily 6AM';
    @TestVisible private static final String CRON_DAILY_6AM = '0 0 6 * * ?';

    /**
     * 스케줄 실행 진입점. 상위 Account 사유 생성 Queueable 을 기동한다.
     * @param context 스케줄 컨텍스트
     */
    public void execute(SchedulableContext context) {
        System.enqueueJob(new AccountRationaleQueueable());
    }

    /**
     * 매일 오전 6시에 이 스케줄러를 등록한다.
     * @return 스케줄된 잡 Id
     * @example
     * AccountRationaleSchedulable.scheduleDaily();
     */
    public static String scheduleDaily() {
        return System.schedule(JOB_NAME, CRON_DAILY_6AM, new AccountRationaleSchedulable());
    }
}
