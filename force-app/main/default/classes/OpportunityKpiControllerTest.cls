/**
 * Stage names here are the org's own active stages (미팅 … 계약 체결, Closed Won).
 * The earlier English stages are inactive in this org, so a test built on
 * 'Prospecting' would not exercise anything the card actually renders.
 */
@isTest
private class OpportunityKpiControllerTest {

    private static final Decimal FEE_RATE = 10; // percent — keeps the arithmetic readable
    private static final Decimal ONE_MILLION = 1000000;

    @TestSetup
    static void setup() {
        Product2 product = new Product2(
            Name = 'RP',
            IsActive = true,
            Default_Fee_Rate__c = FEE_RATE
        );
        insert product;

        Date today = Date.today();
        Date quarterStart = Date.newInstance(today.year(), ((today.month() - 1) / 3) * 3 + 1, 1);

        List<Opportunity> opps = new List<Opportunity>{
            // 미팅 ×3 — one of them closing inside the 7 day window, one just outside it.
            open('미팅 마감임박', '미팅', ONE_MILLION, product.Id, today, today.addDays(7)),
            open('미팅 마감밖', '미팅', ONE_MILLION, product.Id, today, today.addDays(8)),
            open('미팅 평범', '미팅', ONE_MILLION, product.Id, today, today.addDays(60)),

            open('수수료 협의 평범', '수수료 협의', ONE_MILLION * 2, product.Id, today, today.addDays(60)),

            // 20일 > 14일 → 접촉 끊김. 14일은 경계라 걸리지 않아야 한다.
            open('심사 끊김', '심사', ONE_MILLION, product.Id, today.addDays(-20), today.addDays(60)),
            open('심사 경계', '심사', ONE_MILLION, product.Id, today.addDays(-14), today.addDays(60)),

            // 31일 > 30일 → 미활동.
            open('수수료 협의 미활동', '수수료 협의', ONE_MILLION, product.Id, today.addDays(-31), today.addDays(60)),

            // 주력 상품이 없으면 수수료 수익은 0이지만 건수에는 잡힌다.
            open('계약 체결 상품없음', '계약 체결', ONE_MILLION, null, today, today.addDays(60)),

            closed('이번분기 수주', 'Closed Won', ONE_MILLION * 5, product.Id, today),
            closed('지난분기 수주', 'Closed Won', ONE_MILLION * 9, product.Id, quarterStart.addDays(-1)),
            closed('실주', 'Closed Lost', ONE_MILLION * 9, product.Id, today)
        };
        insert opps;

        Date weekStart = today.toStartOfWeek();
        insert new List<Task>{
            new Task(Subject = '이번 주 할 일', Status = 'Not Started', ActivityDate = weekStart),
            new Task(Subject = '이번 주 완료분', Status = 'Completed', ActivityDate = weekStart),
            new Task(Subject = '다음 주 할 일', Status = 'Not Started', ActivityDate = weekStart.addDays(7))
        };
    }

    @isTest
    static void countsOpenDealsPlusThisQuartersWins() {
        Test.startTest();
        OpportunityKpiController.Pipeline pipeline = OpportunityKpiController.getPipeline(null, null, null, null);
        Test.stopTest();

        // 진행 중 8건 + 이번 분기 수주 1건. 지난 분기 수주와 실주는 빠진다.
        System.assertEquals(9, pipeline.totalCount, '진행 중 + 이번 분기 수주만 세어야 한다');
    }

    @isTest
    static void sumsFeeRevenueOnOpenDealsOnly() {
        Test.startTest();
        OpportunityKpiController.Pipeline pipeline = OpportunityKpiController.getPipeline(null, null, null, null);
        Test.stopTest();

        // 상품이 붙은 진행 중 기회 7건의 거래금액 합 8백만 × 10%.
        System.assertEquals(
            800000,
            pipeline.openFeeRevenue,
            '수주·실주를 제외한 진행 중 기회의 수수료 수익만 합산해야 한다'
        );
    }

    @isTest
    static void buildsAColumnForEveryActiveStageExceptLost() {
        Test.startTest();
        OpportunityKpiController.Pipeline pipeline = OpportunityKpiController.getPipeline(null, null, null, null);
        Test.stopTest();

        Map<String, OpportunityKpiController.StageBucket> byStage = bucketsOf(pipeline);

        System.assertEquals(3, byStage.get('미팅').count, '미팅 건수');
        System.assertEquals(2, byStage.get('수수료 협의').count, '수수료 협의 건수');
        System.assertEquals(0, byStage.get('상품 확정').count, '기회가 없는 단계도 칸은 남아야 한다');
        System.assertEquals(2, byStage.get('심사').count, '심사 건수');
        System.assertEquals(1, byStage.get('계약 체결').count, '계약 체결 건수');
        System.assertEquals(1, byStage.get('Closed Won').count, '이번 분기 수주만');
        System.assert(!byStage.containsKey('Closed Lost'), '실주 단계는 칸을 만들지 않는다');
        System.assert(!byStage.containsKey('Prospecting'), '비활성 단계는 칸을 만들지 않는다');
    }

    @isTest
    static void reportsFeeRevenuePerStageAndZeroWithoutAProduct() {
        Test.startTest();
        OpportunityKpiController.Pipeline pipeline = OpportunityKpiController.getPipeline(null, null, null, null);
        Test.stopTest();

        Map<String, OpportunityKpiController.StageBucket> byStage = bucketsOf(pipeline);

        System.assertEquals(300000, byStage.get('미팅').feeRevenue, '미팅 수수료 수익');
        System.assertEquals(300000, byStage.get('수수료 협의').feeRevenue, '수수료 협의 수수료 수익');
        System.assertEquals(500000, byStage.get('Closed Won').feeRevenue, '수주 단계도 금액을 보여준다');
        System.assertEquals(
            0,
            byStage.get('계약 체결').feeRevenue,
            '주력 상품이 없으면 임의 요율을 쓰지 않고 0으로 둔다'
        );
        System.assertEquals(true, byStage.get('Closed Won').isWon, '수주 단계 표시');
        System.assertEquals(false, byStage.get('미팅').isWon, '진행 단계 표시');
    }

    @isTest
    static void raisesOneChipPerConcernWithoutDoubleCounting() {
        Test.startTest();
        OpportunityKpiController.Pipeline pipeline = OpportunityKpiController.getPipeline(null, null, null, null);
        Test.stopTest();

        Map<String, OpportunityKpiController.Alert> byKey = alertsOf(pipeline);

        System.assertEquals(1, byKey.get('stalled').count, '20일 경과 1건만. 14일은 경계라 제외');
        System.assertEquals('심사', byKey.get('stalled').stageName, '칩이 가리키는 단계');
        System.assertEquals(1, byKey.get('closing').count, '오늘+7일은 포함, 오늘+8일은 제외');
        System.assertEquals(1, byKey.get('inactive').count, '31일 경과 1건. 접촉 끊김 건은 중복으로 세지 않는다');
    }

    @isTest
    static void countsOverdueDealsAsClosing() {
        Opportunity overdue = [SELECT Id FROM Opportunity WHERE Name = '미팅 평범' LIMIT 1];
        overdue.CloseDate = Date.today().addDays(-3);
        update overdue;

        Test.startTest();
        OpportunityKpiController.Pipeline pipeline = OpportunityKpiController.getPipeline(null, null, null, null);
        Test.stopTest();

        System.assertEquals(
            2,
            alertsOf(pipeline).get('closing').count,
            '종료 예정일이 지난 기회도 마감 임박에 포함된다'
        );
    }

    @isTest
    static void treatsANeverMetDealAsFreshUntilItAges() {
        Opportunity neverMet = [SELECT Id FROM Opportunity WHERE Name = '미팅 평범' LIMIT 1];
        neverMet.Last_Meeting_Date__c = null;
        update neverMet;

        Test.startTest();
        OpportunityKpiController.Pipeline pipeline = OpportunityKpiController.getPipeline(null, null, null, null);
        Test.stopTest();

        // 오늘 만들어진 기회라 최근 미팅일이 비어 있어도 방치된 것은 아니다.
        System.assertEquals(
            1,
            alertsOf(pipeline).get('inactive').count,
            '미팅 기록이 없으면 생성일을 기준으로 본다'
        );
    }

    @isTest
    static void honoursTheThresholdsTheAdminSets() {
        Test.startTest();
        OpportunityKpiController.Pipeline pipeline = OpportunityKpiController.getPipeline('수수료 협의', 30, 365, 7);
        Test.stopTest();

        Map<String, OpportunityKpiController.Alert> byKey = alertsOf(pipeline);

        System.assertEquals(1, byKey.get('stalled').count, '감시 단계를 수수료 협의로 바꾸면 31일 경과 건이 잡힌다');
        System.assertEquals('수수료 협의', byKey.get('stalled').stageName, '칩이 새 단계를 가리킨다');
        System.assert(!byKey.containsKey('inactive'), '미활동 기준을 365일로 올리면 해당 없음');
        System.assert(byKey.get('stalled').label.contains('수수료 협의'), '칩 문구도 새 단계를 쓴다');
    }

    @isTest
    static void countsOnlyThisWeeksUnfinishedTasks() {
        Test.startTest();
        OpportunityKpiController.Pipeline pipeline = OpportunityKpiController.getPipeline(null, null, null, null);
        Test.stopTest();

        System.assertEquals(
            1,
            pipeline.weekActionCount,
            '완료된 할 일과 다음 주 할 일은 이번 주 액션이 아니다'
        );
    }

    @isTest
    static void keepsTheStageColumnsWhenThereIsNothingInThePipeline() {
        delete [SELECT Id FROM Opportunity];
        delete [SELECT Id FROM Task];

        Test.startTest();
        OpportunityKpiController.Pipeline pipeline = OpportunityKpiController.getPipeline(null, null, null, null);
        Test.stopTest();

        System.assertEquals(0, pipeline.totalCount, '기회가 없으면 0건');
        System.assertEquals(0, pipeline.openFeeRevenue, '기회가 없으면 수수료 수익도 0');
        System.assertEquals(0, pipeline.weekActionCount, '할 일이 없으면 0건');
        System.assertEquals(0, pipeline.alerts.size(), '알릴 것이 없으면 칩도 없다');
        System.assert(!pipeline.stages.isEmpty(), '단계 칸 자체는 남는다');
    }

    // ── helpers ──────────────────────────────────────────────

    private static Opportunity open(
        String name,
        String stage,
        Decimal amount,
        Id productId,
        Date lastMeeting,
        Date closeDate
    ) {
        return new Opportunity(
            Name = name,
            StageName = stage,
            Amount = amount,
            CloseDate = closeDate,
            Primary_Product__c = productId,
            Last_Meeting_Date__c = lastMeeting
        );
    }

    private static Opportunity closed(String name, String stage, Decimal amount, Id productId, Date closeDate) {
        return new Opportunity(
            Name = name,
            StageName = stage,
            Amount = amount,
            CloseDate = closeDate,
            Primary_Product__c = productId,
            Last_Meeting_Date__c = closeDate
        );
    }

    private static Map<String, OpportunityKpiController.StageBucket> bucketsOf(
        OpportunityKpiController.Pipeline pipeline
    ) {
        Map<String, OpportunityKpiController.StageBucket> byStage = new Map<String, OpportunityKpiController.StageBucket>();
        for (OpportunityKpiController.StageBucket bucket : pipeline.stages) {
            byStage.put(bucket.stageName, bucket);
        }
        return byStage;
    }

    private static Map<String, OpportunityKpiController.Alert> alertsOf(
        OpportunityKpiController.Pipeline pipeline
    ) {
        Map<String, OpportunityKpiController.Alert> byKey = new Map<String, OpportunityKpiController.Alert>();
        for (OpportunityKpiController.Alert alert : pipeline.alerts) {
            byKey.put(alert.key, alert);
        }
        return byKey;
    }
}