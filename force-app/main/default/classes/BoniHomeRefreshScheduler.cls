/** 홈 탭 매시 정각 재게시. */
public with sharing class BoniHomeRefreshScheduler implements Schedulable {
    public static final String JOB_NAME = 'Boni Home Refresh';
    public static final String CRON_HOURLY = '0 0 * * * ?';
    public void execute(SchedulableContext sc) { System.enqueueJob(new BoniPublisher(BoniPublisher.Mode.HOME)); }
    public static String scheduleDefault() { return System.schedule(JOB_NAME, CRON_HOURLY, new BoniHomeRefreshScheduler()); }
}