/**
 * Nightly safety net that re-points orphaned external records to their Account.
 *
 * LeadConvertedTrigger already reconnects CorporateFinancialStatement__c /
 * ExternalSignal__c to the new Account at conversion time. The one gap it cannot
 * cover is a signal DART attaches to a Lead *after* it was already converted:
 * no conversion event fires, so that record keeps Account__c = null forever and
 * shows up as an orphan (visible on the briefing only via its lookup fallback).
 *
 * This batch sweeps both objects for rows where Account__c is null but the
 * parent Lead is converted, and fills Account__c from Lead.ConvertedAccountId —
 * the same rule LeadConvertService.reconnectExternalRecords applies inline.
 *
 * One QueryLocator handles ExternalSignal__c; finish() chains a second run for
 * CorporateFinancialStatement__c so both objects are swept from a single
 * scheduled entry point.
 */
public with sharing class OrphanSignalReconnectBatch
    implements Database.Batchable<SObject>, Schedulable {

    // The object this run sweeps. Defaults to ExternalSignal__c; finish() chains
    // a CorporateFinancialStatement__c run so both are covered per schedule.
    private final String objectApiName;

    private static final String SIGNAL_OBJECT = 'ExternalSignal__c';
    private static final String STATEMENT_OBJECT = 'CorporateFinancialStatement__c';
    private static final Integer BATCH_SIZE = 200;

    public OrphanSignalReconnectBatch() {
        this(SIGNAL_OBJECT);
    }

    private OrphanSignalReconnectBatch(String objectApiName) {
        this.objectApiName = objectApiName;
    }

    // ─── Schedulable ─────────────────────────────────────────────────────

    /**
     * Scheduled entry point. Launches the ExternalSignal__c sweep; that run's
     * finish() chains the CorporateFinancialStatement__c sweep.
     */
    public void execute(SchedulableContext context) {
        Database.executeBatch(new OrphanSignalReconnectBatch(SIGNAL_OBJECT), BATCH_SIZE);
    }

    // ─── Batchable ───────────────────────────────────────────────────────

    /**
     * Orphaned rows for this run's object: Account__c null but the parent Lead
     * converted. WITH USER_MODE keeps the sweep inside the running user's FLS,
     * matching LeadConvertService's inline reconnect.
     */
    public Database.QueryLocator start(Database.BatchableContext context) {
        String query =
            'SELECT Id, Lead__c, Lead__r.ConvertedAccountId, Account__c ' +
            'FROM ' + objectApiName + ' ' +
            'WHERE Account__c = null ' +
            'AND Lead__c != null ' +
            'AND Lead__r.IsConverted = true ' +
            'WITH USER_MODE';
        return Database.getQueryLocator(query);
    }

    /**
     * Fills Account__c from the parent Lead's ConvertedAccountId. Rows whose
     * Lead somehow lacks a converted Account are skipped rather than nulled.
     */
    public void execute(Database.BatchableContext context, List<SObject> scope) {
        List<SObject> toUpdate = new List<SObject>();
        for (SObject record : scope) {
            Id convertedAccountId = (Id) record.getSObject('Lead__r').get('ConvertedAccountId');
            if (convertedAccountId == null) {
                continue;
            }
            record.put('Account__c', convertedAccountId);
            toUpdate.add(record);
        }
        if (toUpdate.isEmpty()) {
            return;
        }
        for (Database.SaveResult sr : Database.update(toUpdate, false, AccessLevel.USER_MODE)) {
            if (!sr.isSuccess()) {
                System.debug(LoggingLevel.ERROR,
                    'Orphan reconnect skipped for ' + sr.getId() + ': ' + formatErrors(sr.getErrors()));
            }
        }
    }

    /**
     * After the ExternalSignal__c sweep, chain the CorporateFinancialStatement__c
     * sweep so a single schedule covers both objects.
     */
    public void finish(Database.BatchableContext context) {
        if (objectApiName == SIGNAL_OBJECT) {
            Database.executeBatch(new OrphanSignalReconnectBatch(STATEMENT_OBJECT), BATCH_SIZE);
        }
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    private static String formatErrors(List<Database.Error> errors) {
        List<String> messages = new List<String>();
        for (Database.Error err : errors) {
            messages.add(err.getMessage());
        }
        return String.join(messages, '; ');
    }
}