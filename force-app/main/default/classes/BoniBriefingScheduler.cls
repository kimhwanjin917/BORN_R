/** 아침 브리핑 스케줄러 (기본 07:30 KST). 실행은 BoniPublisher(BRIEFING) Queueable 에 위임. */
public with sharing class BoniBriefingScheduler implements Schedulable {
    public static final String JOB_NAME = 'Boni Briefing';
    public void execute(SchedulableContext sc) { System.enqueueJob(new BoniPublisher(BoniPublisher.Mode.BRIEFING)); }
    public static String cronFor(BoniDashboardService.Settings s) { return '0 30 ' + s.briefingHour + ' * * ?'; }
    public static String scheduleDefault() { return System.schedule(JOB_NAME, cronFor(BoniDashboardService.load()), new BoniBriefingScheduler()); }
}