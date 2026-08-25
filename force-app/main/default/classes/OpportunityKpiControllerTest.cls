@isTest
private class OpportunityKpiControllerTest {
    @TestSetup
    static void setup() {
        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 3; i++) {
            opps.add(new Opportunity(
                Name = 'Open Prospecting ' + i,
                StageName = 'Prospecting',
                CloseDate = Date.today().addDays(30)
            ));
        }
        for (Integer i = 0; i < 2; i++) {
            opps.add(new Opportunity(
                Name = 'Open Negotiation ' + i,
                StageName = 'Negotiation/Review',
                CloseDate = Date.today().addDays(30)
            ));
        }
        opps.add(new Opportunity(
            Name = 'Won Deal',
            StageName = 'Closed Won',
            CloseDate = Date.today()
        ));
        insert opps;
    }

    @isTest
    static void returnsOpenCountAndStageDistribution() {
        Test.startTest();
        OpportunityKpiController.OpportunityKpi kpi = OpportunityKpiController.getOpenKpi();
        Test.stopTest();

        System.assertEquals(5, kpi.openCount, 'Only open opportunities should be counted');

        Map<String, Integer> byStage = new Map<String, Integer>();
        for (OpportunityKpiController.StageCount sc : kpi.stages) {
            byStage.put(sc.stageName, sc.count);
        }
        System.assertEquals(3, byStage.get('Prospecting'), 'Prospecting count');
        System.assertEquals(2, byStage.get('Negotiation/Review'), 'Negotiation count');
        System.assert(!byStage.containsKey('Closed Won'), 'Closed stages excluded');
    }
}