/**
 * Nightly refresh: syncs recommendation outcomes and regenerates today's proposals for every
 * account that has a financial statement. Schedule with scheduleDaily().
 */
public with sharing class RadarRefreshSchedulable implements Schedulable {
    public static final String JOB_NAME = 'Opportunity Radar Nightly Refresh';
    public static final String CRON_DAILY_0330 = '0 30 3 * * ?';

    /** @return scheduled job id */
    public static Id scheduleDaily() {
        return System.schedule(JOB_NAME, CRON_DAILY_0330, new RadarRefreshSchedulable());
    }

    public void execute(SchedulableContext context) {
        Set<Id> accountIds = new Set<Id>();
        for (AggregateResult row : [
            SELECT Account__c accountId FROM CorporateFinancialStatement__c
            WHERE Account__c != null WITH USER_MODE GROUP BY Account__c LIMIT 2000
        ]) {
            accountIds.add((Id) row.get('accountId'));
        }
        RecommendationOutcomeService.syncOutcomes(accountIds);
        RadarRecommendationService.regenerate(accountIds);
    }
}