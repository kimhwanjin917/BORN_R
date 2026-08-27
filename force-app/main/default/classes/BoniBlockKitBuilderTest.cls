@IsTest
private class BoniBlockKitBuilderTest {

    private static BoniDashboardData sample() {
        BoniDashboardData d = new BoniDashboardData();
        d.today = Date.newInstance(2026, 8, 27); d.generatedAt = Datetime.now(); d.role = 'RM'; d.dataUserName = '윤 주환';
        BoniDashboardData.EventItem e = new BoniDashboardData.EventItem();
        e.id = '00Uaj0000000001AAA'; e.subject = '삼성전기 자금팀 미팅'; e.startAt = Datetime.newInstance(2026, 8, 27, 10, 30, 0); e.accountName = '삼성전기';
        d.events.add(e);
        BoniDashboardData.MaturityItem m = new BoniDashboardData.MaturityItem();
        m.oppId = '006aj0000000001AAA'; m.accountName = '클래시스'; m.amount = 81200000000L; m.maturityDate = Date.newInstance(2026, 8, 28); m.daysLeft = 1; m.productName = 'RP';
        d.maturities.add(m);
        BoniDashboardData.TaskItem t = new BoniDashboardData.TaskItem();
        t.id = '00Taj0000000001AAA'; t.subject = '대성정밀 제안서 발송'; t.overdueDays = 2; t.dueDate = Date.newInstance(2026, 8, 25);
        d.tasks.add(t);
        d.pipeline.closingThisWeek = 2; d.pipeline.closingAmount = 12000000000L; d.pipeline.stale = 1; d.pipeline.openTotal = 5;
        return d;
    }

    @IsTest
    static void formatKrw_roundsToKoreanUnits() {
        Assert.areEqual('812억', BoniBlockKitBuilder.formatKrw(81200000000L));
        Assert.areEqual('1.2조', BoniBlockKitBuilder.formatKrw(1200000000000L));
        Assert.areEqual('5,000만', BoniBlockKitBuilder.formatKrw(50000000));
        Assert.areEqual('0원', BoniBlockKitBuilder.formatKrw(null));
    }

    @IsTest
    static void homeView_hasTypeHomeAndAllSectionsAndButtons() {
        Map<String, Object> v = BoniBlockKitBuilder.homeView(sample());
        Assert.areEqual('home', v.get('type'));
        String json = JSON.serialize(v);
        Assert.isTrue(json.contains('오늘 일정'));
        Assert.isTrue(json.contains('만기 도래'));
        Assert.isTrue(json.contains('고객 시그널'));
        Assert.isTrue(json.contains('파이프라인'));
        Assert.isTrue(json.contains('할 일'));
        Assert.isTrue(json.contains(BoniBlockKitBuilder.ACTION_REFRESH));
        Assert.isTrue(json.contains(BoniBlockKitBuilder.ACTION_ROLLOVER));
        Assert.isTrue(json.contains('006aj0000000001AAA'), '버튼 value 에 Opp Id');
        Assert.isTrue(json.contains('812억'));
        Assert.isTrue(json.contains('D-1'));
        Assert.isTrue(((List<Object>) v.get('blocks')).size() < 100, 'Slack 블록 상한');
    }

    @IsTest
    static void homeView_emptySections_showGuidance() {
        BoniDashboardData d = new BoniDashboardData();
        d.today = Date.today(); d.generatedAt = Datetime.now(); d.role = 'RM'; d.calendarConnected = false;
        String json = JSON.serialize(BoniBlockKitBuilder.homeView(d));
        Assert.isTrue(json.contains('캘린더 연결'));
        Assert.isTrue(json.contains('없습니다'));
    }

    @IsTest
    static void sections_truncateToFivePlusMore() {
        BoniDashboardData d = sample();
        for (Integer i = 0; i < 7; i++) {
            BoniDashboardData.TaskItem t = new BoniDashboardData.TaskItem();
            t.id = '00Taj000000000' + i + 'AAA'; t.subject = 'T' + i; t.overdueDays = 0; d.tasks.add(t);
        }
        String json = JSON.serialize(BoniBlockKitBuilder.homeView(d));
        Assert.isTrue(json.contains('3건 더'), '8건 중 5건 표시 + 3건 더');
    }

    @IsTest
    static void briefingAndWrapup_produceBlocksAndFallbackText() {
        BoniDashboardData d = sample();
        Assert.isFalse(BoniBlockKitBuilder.briefingBlocks(d).isEmpty());
        Assert.isTrue(BoniBlockKitBuilder.briefingText(d).contains('8월 27일'));
        d.wrapup = new BoniDashboardData.WrapupData();
        d.wrapup.updatedOpps.add('클래시스 · Closed Won'); d.wrapup.completedTasks = 1; d.wrapup.carriedTasks = 2;
        String json = JSON.serialize(BoniBlockKitBuilder.wrapupBlocks(d));
        Assert.isTrue(json.contains('클래시스'));
        Assert.isTrue(BoniBlockKitBuilder.wrapupText(d).contains('완료'));
    }
}