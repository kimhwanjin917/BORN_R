/**
 * Provides KPI aggregates for Leads, grouped into Won (converted),
 * In-progress (open, working statuses) and Not-converted (open, New status).
 */
public with sharing class LeadKpiController {

    private static final String STATUS_NEW = 'New';

    /**
     * A single KPI segment: label, count and share of the total.
     */
    public class LeadKpiSegment {
        @AuraEnabled public String key;
        @AuraEnabled public String label;
        @AuraEnabled public Integer count;
        public LeadKpiSegment(String key, String label, Integer count) {
            this.key = key;
            this.label = label;
            this.count = count;
        }
    }

    /**
     * Aggregate KPI payload for all Leads visible to the running user.
     */
    public class LeadKpi {
        @AuraEnabled public Integer totalCount;
        @AuraEnabled public Integer wonCount;
        @AuraEnabled public Integer inProgressCount;
        @AuraEnabled public Integer notConvertedCount;
        @AuraEnabled public List<LeadKpiSegment> segments;
        public LeadKpi() {
            this.totalCount = 0;
            this.wonCount = 0;
            this.inProgressCount = 0;
            this.notConvertedCount = 0;
            this.segments = new List<LeadKpiSegment>();
        }
    }

    /**
     * Returns Lead counts split into Won / In-progress / Not-converted buckets
     * across all Leads the running user can see.
     *
     * @return Aggregated Lead KPI with per-segment counts.
     * @example
     * LeadKpiController.LeadKpi kpi = LeadKpiController.getLeadKpi();
     */
    @AuraEnabled(cacheable=true)
    public static LeadKpi getLeadKpi() {
        try {
            LeadKpi kpi = new LeadKpi();
            for (AggregateResult ar : [
                SELECT Status status, IsConverted isConverted, COUNT(Id) total
                FROM Lead
                WITH USER_MODE
                GROUP BY Status, IsConverted
            ]) {
                Integer count = (Integer) ar.get('total');
                Boolean isConverted = (Boolean) ar.get('isConverted');
                String status = (String) ar.get('status');
                kpi.totalCount += count;
                if (isConverted) {
                    kpi.wonCount += count;
                } else if (STATUS_NEW.equalsIgnoreCase(status)) {
                    kpi.notConvertedCount += count;
                } else {
                    kpi.inProgressCount += count;
                }
            }
            kpi.segments.add(new LeadKpiSegment('won', 'Won (전환 완료)', kpi.wonCount));
            kpi.segments.add(new LeadKpiSegment('inProgress', '진행 중', kpi.inProgressCount));
            kpi.segments.add(new LeadKpiSegment('notConverted', '미전환', kpi.notConvertedCount));
            return kpi;
        } catch (Exception e) {
            throw new AuraHandledException('리드 KPI를 불러오지 못했습니다: ' + e.getMessage());
        }
    }
}