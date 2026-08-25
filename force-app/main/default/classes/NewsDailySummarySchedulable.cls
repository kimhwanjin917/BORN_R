/**
 * 매일 오전 6시에 일일 뉴스 요약 생성을 기동하는 스케줄러.
 *
 * 실제 생성·저장은 NewsDailySummarySaveQueueable 이 맡는다(프롬프트 템플릿 호출이 콜아웃이라 Queueable 로 분리).
 * 담당 기업 뉴스는 우선순위 상위 기업 기준이므로, 점수 배치(새벽 3시) 이후인 6시에 실행한다.
 */
public with sharing class NewsDailySummarySchedulable implements Schedulable {

    @TestVisible private static final String JOB_NAME = 'NewsDailySummary - Daily 6AM';
    @TestVisible private static final String CRON_DAILY_6AM = '0 0 6 * * ?';

    /**
     * 스케줄 실행 진입점. 일일 뉴스 요약 생성 Queueable 을 기동한다.
     * @param context 스케줄 컨텍스트
     */
    public void execute(SchedulableContext context) {
        System.enqueueJob(new NewsDailySummarySaveQueueable());
    }

    /**
     * 매일 오전 6시에 이 스케줄러를 등록한다.
     * @return 스케줄된 잡 Id
     * @example
     * NewsDailySummarySchedulable.scheduleDaily();
     */
    public static String scheduleDaily() {
        return System.schedule(JOB_NAME, CRON_DAILY_6AM, new NewsDailySummarySchedulable());
    }
}