/**
 * Daily snapshot batch: reads every RM's Opportunities and upserts a deal-level
 * progress snapshot into Deal_Progress_Summary__c, keyed on the opaque
 * Source_Opportunity_Key__c (the Opportunity Id). Lets managers track deal
 * progress without opening the source Opportunity records.
 *
 * WITHOUT SHARING — this is the ONLY `without sharing` class in the codebase.
 * The batch must aggregate Opportunities across ALL RMs regardless of the
 * running user's sharing, so it intentionally runs in system context. All SOQL
 * and DML below therefore use AccessLevel.SYSTEM_MODE, justified by this
 * single elevated-access point. Do not add a second `without sharing` class;
 * route any cross-RM read through this batch instead.
 *
 * Never copies customer-identifying text (Account.Name, Opportunity.Name, etc.)
 * into the summary. Only structural/status fields and User references are stored.
 *
 * @example
 * // Run immediately
 * DealProgressSummaryBatch.run();
 *
 * // Schedule daily at 01:00
 * DealProgressSummaryBatch.scheduleDaily();
 */
public without sharing class DealProgressSummaryBatch
    implements Database.Batchable<SObject>, Database.Stateful, Schedulable {

    private static final Integer DEFAULT_BATCH_SIZE = 200;
    private static final String CRON_DAILY_1AM = '0 0 1 * * ?';
    private static final String SCHEDULED_JOB_NAME = 'Deal Progress Summary - Daily';

    // Reporting period (current month, "YYYY-MM") and sync stamp are fixed for
    // the whole run so every snapshot in one execution is internally consistent.
    private final String reportingPeriod;
    private final Datetime syncedAt;

    private Integer totalProcessed = 0;
    private Integer totalErrors = 0;
    private List<String> errorMessages = new List<String>();

    /**
     * Captures the run-wide reporting period and sync timestamp at construction
     * so they stay stable across all batch chunks.
     */
    public DealProgressSummaryBatch() {
        Date today = Date.today();
        this.reportingPeriod =
            String.valueOf(today.year()) + '-' + leftPadMonth(today.month());
        this.syncedAt = Datetime.now();
    }

    /**
     * Schedulable entry point: launches the batch when the scheduled job fires.
     *
     * @param context The schedulable context supplied by the platform.
     */
    public void execute(SchedulableContext context) {
        Database.executeBatch(new DealProgressSummaryBatch(), DEFAULT_BATCH_SIZE);
    }

    /**
     * Selects every Opportunity to snapshot. Runs in SYSTEM_MODE so deals owned
     * by any RM are included regardless of the running user's sharing/FLS.
     *
     * @param context The batch context.
     * @return QueryLocator over all Opportunities.
     */
    public Database.QueryLocator start(Database.BatchableContext context) {
        return Database.getQueryLocator([
            SELECT Id, OwnerId, StageName, IsClosed, IsWon,
                   LastStageChangeDate, Owner.Team_Code__c
            FROM Opportunity
            WITH SYSTEM_MODE
            ORDER BY Id
        ]);
    }

    /**
     * Builds one Deal_Progress_Summary__c snapshot per Opportunity in the chunk
     * and upserts on the opaque Source_Opportunity_Key__c external id.
     *
     * @param context The batch context.
     * @param scope Opportunities in the current chunk.
     */
    public void execute(Database.BatchableContext context, List<Opportunity> scope) {
        if (scope == null || scope.isEmpty()) {
            return;
        }

        List<Deal_Progress_Summary__c> summaries = new List<Deal_Progress_Summary__c>();
        for (Opportunity opp : scope) {
            summaries.add(toSummary(opp));
        }

        // SYSTEM_MODE upsert: the batch is the sole cross-RM writer of snapshots
        // and must not be constrained by the running user's FLS/sharing.
        List<Database.UpsertResult> results = Database.upsert(
            summaries,
            Deal_Progress_Summary__c.Source_Opportunity_Key__c,
            false,
            AccessLevel.SYSTEM_MODE
        );
        processResults(results);
    }

    /**
     * Logs a run summary after all chunks complete.
     *
     * @param context The batch context.
     */
    public void finish(Database.BatchableContext context) {
        System.debug(LoggingLevel.INFO, String.format(
            'DealProgressSummaryBatch completed. Period: {0}, Processed: {1}, Errors: {2}',
            new List<Object>{ reportingPeriod, totalProcessed, totalErrors }
        ));
        if (!errorMessages.isEmpty()) {
            System.debug(LoggingLevel.ERROR, 'Errors: ' + String.join(errorMessages, '\n'));
        }
    }

    /**
     * Maps a single Opportunity to its deal-level snapshot. Deliberately omits
     * every customer-identifying text field; only status/structure and User
     * references are copied.
     *
     * @param opp Source Opportunity.
     * @return The snapshot record to upsert.
     */
    private Deal_Progress_Summary__c toSummary(Opportunity opp) {
        return new Deal_Progress_Summary__c(
            Source_Opportunity_Key__c = opp.Id,
            RM__c = opp.OwnerId,
            Stage__c = opp.StageName,
            Is_Closed__c = opp.IsClosed,
            Is_Won__c = opp.IsWon,
            Reporting_Period__c = reportingPeriod,
            Stage_Changed_At__c = opp.LastStageChangeDate,
            Team_Code__c = opp.Owner == null ? null : opp.Owner.Team_Code__c,
            Last_Synced_At__c = syncedAt
        );
    }

    /**
     * Tracks upsert successes/failures for the finish() summary.
     *
     * @param results Upsert results for the current chunk.
     */
    private void processResults(List<Database.UpsertResult> results) {
        for (Database.UpsertResult result : results) {
            if (result.isSuccess()) {
                totalProcessed++;
            } else {
                totalErrors++;
                for (Database.Error err : result.getErrors()) {
                    errorMessages.add(err.getStatusCode() + ' - ' + err.getMessage());
                }
            }
        }
    }

    /**
     * @param monthNumber Calendar month 1-12.
     * @return Two-digit, zero-padded month string.
     */
    private String leftPadMonth(Integer monthNumber) {
        return monthNumber < 10 ? '0' + monthNumber : String.valueOf(monthNumber);
    }

    /**
     * Runs the batch immediately with the default chunk size.
     *
     * @return The batch job Id.
     */
    public static Id run() {
        return Database.executeBatch(new DealProgressSummaryBatch(), DEFAULT_BATCH_SIZE);
    }

    /**
     * Schedules the batch to run daily at 01:00.
     *
     * @return The scheduled job Id.
     */
    public static Id scheduleDaily() {
        return System.schedule(SCHEDULED_JOB_NAME, CRON_DAILY_1AM, new DealProgressSummaryBatch());
    }
}