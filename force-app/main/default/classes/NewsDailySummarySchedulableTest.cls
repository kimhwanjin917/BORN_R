/**
 * NewsDailySummarySchedulable 테스트.
 * CRON 등록과 직접 실행(execute)을 검증한다. 실제 요약 생성은 NewsDailySummarySaveQueueableTest 가 다룬다.
 */
@isTest
private class NewsDailySummarySchedulableTest {

    @isTest
    static void shouldRegisterCron_WhenScheduledDaily() {
        Test.startTest();
        String jobId = NewsDailySummarySchedulable.scheduleDaily();
        Test.stopTest();

        CronTrigger scheduledJob = [
            SELECT CronExpression FROM CronTrigger WHERE Id = :jobId
        ];
        Assert.areEqual(
            NewsDailySummarySchedulable.CRON_DAILY_6AM,
            scheduledJob.CronExpression,
            '매일 오전 6시 CRON 으로 등록돼야 한다'
        );
    }

    @isTest
    static void shouldEnqueueQueueable_WhenExecuted() {
        NewsDailySummarySaveQueueable.stubResponse = '오늘의 뉴스 요약:\n한 줄 총평: 테스트.';

        Test.startTest();
        new NewsDailySummarySchedulable().execute(null);
        Test.stopTest();

        Integer queuedJobs = [
            SELECT COUNT() FROM AsyncApexJob
            WHERE JobType = 'Queueable' AND ApexClass.Name = 'NewsDailySummarySaveQueueable'
        ];
        Assert.areEqual(1, queuedJobs, 'execute 는 요약 생성 Queueable 을 1건 기동해야 한다');
    }
}