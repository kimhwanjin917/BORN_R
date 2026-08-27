/** 마감 리포트 스케줄러 (기본 18:00 KST). */
public with sharing class BoniWrapupScheduler implements Schedulable {
    public static final String JOB_NAME = 'Boni Wrapup';
    public void execute(SchedulableContext sc) { System.enqueueJob(new BoniPublisher(BoniPublisher.Mode.WRAPUP)); }
    public static String cronFor(BoniDashboardService.Settings s) { return '0 0 ' + s.wrapupHour + ' * * ?'; }
    public static String scheduleDefault() { return System.schedule(JOB_NAME, cronFor(BoniDashboardService.load()), new BoniWrapupScheduler()); }
}