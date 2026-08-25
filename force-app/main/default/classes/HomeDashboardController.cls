/**
 * Home dashboard controller for the RM home page. Backs the homeScheduleNews
 * LWC (today's meetings, maturity-alert badge, priority-account news + daily
 * AI summary). Additional dashboard components (KPI, account/lead priority)
 * may be consolidated here later.
 */
public with sharing class HomeDashboardController {

    private static final Integer TOP_ACCOUNTS = 3;
    private static final Integer TOP_LEADS = 3;
    private static final Integer NEWS_LIMIT = 6;
    private static final String NEWS_SIGNAL_TYPE = '뉴스';
    private static final String MATURITY_SUBJECT_LIKE = '만기 30일 전 후속 영업%';

    /**
     * Today's meetings owned by the running user. Each row feeds the
     * '미팅 시작' button, which launches the Meeting_Session Screen Flow with
     * the Event's WhatId (the related Opportunity).
     */
    @AuraEnabled(cacheable=true)
    public static List<Event> getTodayEvents() {
        Id userId = UserInfo.getUserId();
        return [
            SELECT Id, Subject, WhoId, Who.Name, WhatId, What.Name, StartDateTime, EndDateTime
            FROM Event
            WHERE OwnerId = :userId
              AND StartDateTime = TODAY
            WITH USER_MODE
            ORDER BY StartDateTime ASC
        ];
    }

    /**
     * Open maturity-alert Tasks owned by the running user, created by
     * MaturityAlertBatch. Powers the count badge and its list.
     */
    @AuraEnabled(cacheable=true)
    public static List<Task> getMaturityAlertTasks() {
        Id userId = UserInfo.getUserId();
        return [
            SELECT Id, Subject, WhatId, What.Name, ActivityDate
            FROM Task
            WHERE OwnerId = :userId
              AND IsClosed = false
              AND Subject LIKE :MATURITY_SUBJECT_LIKE
            WITH USER_MODE
            ORDER BY ActivityDate ASC NULLS LAST
        ];
    }

    /**
     * The most recent stored daily AI news summary shared across the whole
     * team. Returns the latest non-blank summary org-wide (not per-user), or
     * null when none exists. Object sharing (ReadWrite) plus WITH USER_MODE
     * still enforce record- and field-level access.
     */
    @AuraEnabled(cacheable=true)
    public static String getDailySummary() {
        // Summary_Text__c is a Long Text Area and cannot be filtered in SOQL,
        // so the most recent non-blank value is selected in Apex.
        for (ExternalSignal__c signal : [
            SELECT Summary_Text__c
            FROM ExternalSignal__c
            WHERE Summary_Date__c != null
            WITH USER_MODE
            ORDER BY Summary_Date__c DESC
            LIMIT 50
        ]) {
            if (String.isNotBlank(signal.Summary_Text__c)) {
                return signal.Summary_Text__c;
            }
        }
        return null;
    }

    /**
     * Latest news signals for the running user's top priority accounts and
     * leads, or matching their industries. Priority is by Priority_Score__c
     * descending; news is ordered by Signal_Date__c descending.
     */
    @AuraEnabled(cacheable=true)
    public static List<ExternalSignal__c> getPriorityNews() {
        Set<Id> partyIds = new Set<Id>();
        Set<String> industries = new Set<String>();

        for (Account acct : [
            SELECT Id, Industry
            FROM Account
            WHERE Priority_Score__c != null
            WITH USER_MODE
            ORDER BY Priority_Score__c DESC, Name ASC
            LIMIT :TOP_ACCOUNTS
        ]) {
            partyIds.add(acct.Id);
            if (String.isNotBlank(acct.Industry)) {
                industries.add(acct.Industry);
            }
        }

        for (Lead ld : [
            SELECT Id, Industry
            FROM Lead
            WHERE IsConverted = false
              AND Priority_Score__c != null
            WITH USER_MODE
            ORDER BY Priority_Score__c DESC, Name ASC
            LIMIT :TOP_LEADS
        ]) {
            partyIds.add(ld.Id);
            if (String.isNotBlank(ld.Industry)) {
                industries.add(ld.Industry);
            }
        }

        if (partyIds.isEmpty() && industries.isEmpty()) {
            return new List<ExternalSignal__c>();
        }

        return [
            SELECT Id, Title__c, Summary__c, Signal_Date__c, Source_URL__c,
                   Account__c, Account__r.Name, Lead__c, Lead__r.Company, Industry__c
            FROM ExternalSignal__c
            WHERE Signal_Type__c = :NEWS_SIGNAL_TYPE
              AND (Account__c IN :partyIds
                   OR Lead__c IN :partyIds
                   OR Industry__c IN :industries)
            WITH USER_MODE
            ORDER BY Signal_Date__c DESC NULLS LAST
            LIMIT :NEWS_LIMIT
        ];
    }
}