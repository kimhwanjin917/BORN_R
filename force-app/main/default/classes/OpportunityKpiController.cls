public with sharing class OpportunityKpiController {

    public class StageCount {
        @AuraEnabled public String stageName;
        @AuraEnabled public Integer count;
        public StageCount(String stageName, Integer count) {
            this.stageName = stageName;
            this.count = count;
        }
    }

    public class OpportunityKpi {
        @AuraEnabled public Integer openCount;
        @AuraEnabled public List<StageCount> stages;
        public OpportunityKpi() {
            this.openCount = 0;
            this.stages = new List<StageCount>();
        }
    }

    @AuraEnabled(cacheable=true)
    public static OpportunityKpi getOpenKpi() {
        OpportunityKpi kpi = new OpportunityKpi();
        Id userId = UserInfo.getUserId();
        for (AggregateResult ar : [
            SELECT StageName stageName, COUNT(Id) total
            FROM Opportunity
            WHERE OwnerId = :userId AND IsClosed = false
            WITH USER_MODE
            GROUP BY StageName
            ORDER BY COUNT(Id) DESC
        ]) {
            Integer count = (Integer) ar.get('total');
            kpi.openCount += count;
            kpi.stages.add(new StageCount((String) ar.get('stageName'), count));
        }
        return kpi;
    }
}