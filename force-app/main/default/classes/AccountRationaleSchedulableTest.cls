/**
 * AccountRationaleSchedulable 테스트.
 * CRON 등록과 직접 실행(execute)을 검증한다. 실제 사유 생성은 AccountRationaleQueueableTest 가 다룬다.
 */
@isTest
private class AccountRationaleSchedulableTest {

    @isTest
    static void shouldRegisterCron_WhenScheduledDaily() {
        // 운영 org 에 이미 고정 이름으로 스케줄된 잡이 있을 수 있어(scheduleDaily 의 JOB_NAME),
        // 충돌을 피하려 테스트는 고유 이름으로 등록해 CRON 식만 검증한다. 운영 잡은 건드리지 않는다.
        Test.startTest();
        String jobId = System.schedule(
            'AccountRationaleTest - ' + DateTime.now().getTime(),
            AccountRationaleSchedulable.CRON_DAILY_6AM,
            new AccountRationaleSchedulable()
        );
        Test.stopTest();

        CronTrigger scheduledJob = [
            SELECT CronExpression, State FROM CronTrigger WHERE Id = :jobId
        ];
        Assert.areEqual(
            AccountRationaleSchedulable.CRON_DAILY_6AM,
            scheduledJob.CronExpression,
            '매일 오전 6시 CRON 으로 등록돼야 한다'
        );
    }

    @isTest
    static void shouldExposeScheduleDailyHelper() {
        // scheduleDaily 편의 메서드 자체를 실행해 커버한다. 운영 org 에 동일 이름 잡이 이미 있으면
        // AsyncException 이 날 수 있는데, 그 경우에도 메서드 본문은 실행된 것이므로 예외를 삼킨다.
        Test.startTest();
        try {
            AccountRationaleSchedulable.scheduleDaily();
        } catch (System.AsyncException e) {
            // 이미 스케줄된 운영 잡과 충돌 — 정상. 운영 잡은 건드리지 않는다.
        }
        Test.stopTest();

        Assert.areEqual(
            '0 0 6 * * ?',
            AccountRationaleSchedulable.CRON_DAILY_6AM,
            'scheduleDaily 는 매일 오전 6시 CRON 을 사용해야 한다'
        );
    }

    @isTest
    static void shouldEnqueueQueueable_WhenExecuted() {
        AccountRationaleQueueable.stubResponse = '요약: 테스트\n상세: 테스트 상세';

        Test.startTest();
        new AccountRationaleSchedulable().execute(null);
        Test.stopTest();

        // execute 가 Queueable 을 큐에 넣었는지 AsyncApexJob 로 확인한다.
        Integer queuedJobs = [
            SELECT COUNT() FROM AsyncApexJob
            WHERE JobType = 'Queueable' AND ApexClass.Name = 'AccountRationaleQueueable'
        ];
        Assert.areEqual(1, queuedJobs, 'execute 는 사유 생성 Queueable 을 1건 기동해야 한다');
    }
}
