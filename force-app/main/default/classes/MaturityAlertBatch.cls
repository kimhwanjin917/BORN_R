/**
 * Batch + Schedulable Apex that creates maturity follow-up Tasks for the
 * Account Owner (RM) of every Asset whose UsageEndDate falls within the next
 * 30 days. Idempotent: an Asset that already has an open maturity-alert Task is
 * skipped, so re-runs and resets never create duplicates.
 *
 * @example
 * // One-off run
 * MaturityAlertBatch.run();
 *
 * // Schedule daily at 6 AM
 * MaturityAlertBatch.scheduleDaily();
 */
public with sharing class MaturityAlertBatch implements Database.Batchable<SObject>, Schedulable, Database.Stateful {

    // ─── Constants ───────────────────────────────────────────────────────
    private static final Integer DEFAULT_BATCH_SIZE = 200;
    private static final Integer ALERT_WINDOW_DAYS = 30;
    private static final String TASK_STATUS_OPEN = 'Open';

    /** Human-facing Subject prefix; the product name is appended per Asset. */
    @TestVisible
    private static final String SUBJECT_PREFIX = '만기 30일 전 후속 영업 — ';

    /**
     * SOQL LIKE pattern used for idempotency. Kept separate from SUBJECT_PREFIX
     * so the dedup rule can be adjusted without touching Task creation.
     */
    @TestVisible
    private static final String SUBJECT_LIKE_PATTERN = '만기 30일 전 후속 영업%';

    /** Runs every weekday at 6:00 AM. */
    public static final String CRON_WEEKDAYS_6AM = '0 0 6 ? * MON-FRI';

    // ─── Stateful Tracking ───────────────────────────────────────────────
    private Integer totalCreated = 0;
    private Integer totalErrors = 0;
    private List<String> errorMessages = new List<String>();

    // ─── Schedulable Interface ───────────────────────────────────────────

    /**
     * Scheduled entry point. Launches the batch job.
     * @param sc The schedulable context
     */
    public void execute(SchedulableContext sc) {
        Database.executeBatch(this, DEFAULT_BATCH_SIZE);
    }

    // ─── Batchable Interface ─────────────────────────────────────────────

    /**
     * Scopes Assets maturing within the alert window (today .. today+30).
     * @param bc The batch context
     * @return QueryLocator for the Assets to process
     */
    public Database.QueryLocator start(Database.BatchableContext bc) {
        Date windowStart = Date.today();
        Date windowEnd = windowStart.addDays(ALERT_WINDOW_DAYS);
        return Database.getQueryLocator([
            SELECT Id, UsageEndDate, Product2.Name, Account.OwnerId
            FROM Asset
            WHERE UsageEndDate >= :windowStart
              AND UsageEndDate <= :windowEnd
              AND AccountId != NULL
            WITH USER_MODE
        ]);
    }

    /**
     * Creates a follow-up Task for each in-scope Asset that does not already
     * have an open maturity-alert Task.
     * @param bc The batch context
     * @param scope Assets in the current chunk
     */
    public void execute(Database.BatchableContext bc, List<Asset> scope) {
        Set<Id> assetIds = new Map<Id, Asset>(scope).keySet();
        Set<Id> assetsWithOpenAlert = findAssetsWithOpenAlert(assetIds);

        List<Task> tasksToInsert = new List<Task>();
        for (Asset record : scope) {
            if (assetsWithOpenAlert.contains(record.Id)) {
                continue;
            }
            tasksToInsert.add(buildTask(record));
        }

        if (!tasksToInsert.isEmpty()) {
            List<Database.SaveResult> results = Database.insert(tasksToInsert, false, AccessLevel.USER_MODE);
            processResults(results);
        }
    }

    /**
     * Logs a summary once all chunks complete.
     * @param bc The batch context
     */
    public void finish(Database.BatchableContext bc) {
        String summary = String.format(
            'MaturityAlertBatch completed. Tasks created: {0}, Errors: {1}',
            new List<Object>{ totalCreated, totalErrors }
        );
        System.debug(LoggingLevel.INFO, summary);
        if (!errorMessages.isEmpty()) {
            System.debug(LoggingLevel.ERROR, 'Error details: ' + String.join(errorMessages, '\n'));
        }
    }

    // ─── Private Helpers ─────────────────────────────────────────────────

    /**
     * Returns the subset of Asset Ids that already have an open maturity-alert
     * Task. This single SOQL is the idempotency guard for re-runs/resets.
     * @param assetIds Candidate Asset Ids from the current chunk
     * @return Asset Ids that must be skipped
     */
    private Set<Id> findAssetsWithOpenAlert(Set<Id> assetIds) {
        Set<Id> assetsWithOpenAlert = new Set<Id>();
        if (assetIds.isEmpty()) {
            return assetsWithOpenAlert;
        }
        for (Task existing : [
            SELECT WhatId
            FROM Task
            WHERE WhatId IN :assetIds
              AND IsClosed = false
              AND Subject LIKE :SUBJECT_LIKE_PATTERN
            WITH USER_MODE
        ]) {
            assetsWithOpenAlert.add(existing.WhatId);
        }
        return assetsWithOpenAlert;
    }

    /**
     * Builds the follow-up Task for an Asset.
     * @param record Asset with UsageEndDate, Product2.Name, Account.OwnerId
     * @return An unsaved Task assigned to the Account Owner (RM)
     */
    private Task buildTask(Asset record) {
        String productName = (record.Product2 != null) ? record.Product2.Name : '';
        return new Task(
            OwnerId = record.Account.OwnerId,
            WhatId = record.Id,
            Subject = SUBJECT_PREFIX + productName,
            ActivityDate = record.UsageEndDate,
            Status = TASK_STATUS_OPEN
        );
    }

    /**
     * Tallies successes and failures from a partial-success insert.
     * @param results SaveResults from the Task insert
     */
    private void processResults(List<Database.SaveResult> results) {
        for (Database.SaveResult result : results) {
            if (result.isSuccess()) {
                totalCreated++;
            } else {
                totalErrors++;
                for (Database.Error err : result.getErrors()) {
                    errorMessages.add(err.getStatusCode() + ' - ' + err.getMessage());
                }
            }
        }
    }

    // ─── Static Helpers ──────────────────────────────────────────────────

    /**
     * Convenience method to run the batch immediately with the default size.
     * @return The batch job Id
     */
    public static Id run() {
        return Database.executeBatch(new MaturityAlertBatch(), DEFAULT_BATCH_SIZE);
    }

    /**
     * Schedules the job every weekday at 6 AM.
     * @return The scheduled job Id
     */
    public static String scheduleDaily() {
        return System.schedule(
            'MaturityAlertBatch - Weekdays 6AM',
            CRON_WEEKDAYS_6AM,
            new MaturityAlertBatch()
        );
    }
}