@IsTest
private class BoniSchedulerTest {
    private class Mock implements HttpCalloutMock { public HttpResponse respond(HttpRequest r) { HttpResponse s = new HttpResponse(); s.setStatusCode(200); s.setBody('{"ok":true,"ts":"1","channel":{"id":"D"}}'); return s; } }

    @IsTest
    static void schedulers_enqueuePublisher() {
        Test.setMock(HttpCalloutMock.class, new Mock());
        Test.startTest();
        String j1 = System.schedule('T Boni Briefing', '0 30 7 * * ?', new BoniBriefingScheduler());
        String j2 = System.schedule('T Boni Home', '0 0 * * * ?', new BoniHomeRefreshScheduler());
        String j3 = System.schedule('T Boni Wrapup', '0 0 18 * * ?', new BoniWrapupScheduler());
        Test.stopTest();
        Assert.areEqual(3, [SELECT COUNT() FROM CronTrigger WHERE Id IN :new List<Id>{ j1, j2, j3 }]);
    }

    @IsTest
    static void scheduleDefault_usesMdtHours() {
        BoniDashboardService.Settings s = BoniDashboardService.load();
        Assert.isTrue(BoniBriefingScheduler.cronFor(s).startsWith('0 30 ' + s.briefingHour + ' '));
        Assert.isTrue(BoniWrapupScheduler.cronFor(s).startsWith('0 0 ' + s.wrapupHour + ' '));
        Assert.areEqual('0 0 * * * ?', BoniHomeRefreshScheduler.CRON_HOURLY);
    }
}