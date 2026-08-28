/**
 * Invocable Apex action that converts a Lead and wires up the resulting records.
 * Callable from Flows, Process Builder, and Agentforce.
 *
 * For each request it:
 *  - Converts the Lead via Database.convertLead (creates Account, Contact, Opportunity)
 *  - Creates a "고객 미팅" Event on the new Opportunity (WhatId) and Contact (WhoId)
 *  - Re-points related CorporateFinancialStatement__c / ExternalSignal__c records to the new Account
 *  - Transfers Lead fields to the new Account (Priority_Score always; the two
 *    external-id fields only when the Account value is blank)
 *
 * Accepts a bulkified List&lt;Request&gt; and returns a parallel List&lt;Response&gt;.
 */
public with sharing class LeadConvertService {

    private static final String EVENT_SUBJECT = '고객 미팅';

    // ─── Invocable Method ────────────────────────────────────────────────

    /**
     * Converts each supplied Lead and returns the created Opportunity Id.
     * @param requests List of Request inputs from the calling Flow
     * @return List of Response outputs, one per request, in the same order
     */
    @InvocableMethod(
        label='Convert Lead and Schedule Meeting'
        description='Converts a Lead, creates a meeting Event on the new Opportunity, reconnects external data, and transfers fields to the new Account.'
        category='Lead Management'
    )
    public static List<Response> convertLeads(List<Request> requests) {
        List<Response> responses = new List<Response>();
        if (requests == null || requests.isEmpty()) {
            return responses;
        }

        // A Response placeholder is created per request so ordering is preserved.
        Map<Integer, Response> responsesByIndex = new Map<Integer, Response>();
        Set<Id> leadIds = new Set<Id>();
        for (Integer i = 0; i < requests.size(); i++) {
            Response res = new Response();
            responsesByIndex.put(i, res);
            responses.add(res);

            Request req = requests[i];
            if (req == null || req.leadId == null) {
                res.isSuccess = false;
                res.errorMessage = 'leadId is required.';
                res.errorType = 'VALIDATION';
            } else if (req.meetingDateTime == null) {
                res.isSuccess = false;
                res.errorMessage = 'meetingDateTime is required.';
                res.errorType = 'VALIDATION';
            } else {
                leadIds.add(req.leadId);
            }
        }

        if (leadIds.isEmpty()) {
            return responses;
        }

        Map<Id, Lead> leadsById = new Map<Id, Lead>([
            SELECT Id, Priority_Score__c, Business_Registration_Number__c, Assigned_Company_Code__c, Department__c
            FROM Lead
            WHERE Id IN :leadIds
            WITH USER_MODE
        ]);

        String convertedStatus = getConvertedStatus();

        // Build one LeadConvert per valid, still-open request; track which
        // response each maps to so results can be reported back in order.
        List<Database.LeadConvert> conversions = new List<Database.LeadConvert>();
        List<Integer> conversionIndexes = new List<Integer>();
        for (Integer i = 0; i < requests.size(); i++) {
            Response res = responsesByIndex.get(i);
            if (res.isSuccess == false) {
                continue; // already failed validation
            }
            Id leadId = requests[i].leadId;
            if (!leadsById.containsKey(leadId)) {
                res.isSuccess = false;
                res.errorMessage = 'Lead not found or not accessible: ' + leadId;
                res.errorType = 'NOT_FOUND';
                continue;
            }
            Database.LeadConvert lc = new Database.LeadConvert();
            lc.setLeadId(leadId);
            lc.setConvertedStatus(convertedStatus);
            conversions.add(lc);
            conversionIndexes.add(i);
        }

        if (conversions.isEmpty()) {
            return responses;
        }

        List<Database.LeadConvertResult> convertResults = Database.convertLead(conversions, false);

        // Gather the created record Ids for the successful conversions.
        Map<Id, Id> accountIdByLeadId = new Map<Id, Id>();
        Map<Id, Id> contactIdByLeadId = new Map<Id, Id>();
        Map<Id, Id> opportunityIdByLeadId = new Map<Id, Id>();
        for (Integer c = 0; c < convertResults.size(); c++) {
            Database.LeadConvertResult result = convertResults[c];
            Integer requestIndex = conversionIndexes[c];
            Response res = responsesByIndex.get(requestIndex);
            Id leadId = requests[requestIndex].leadId;

            if (result.isSuccess()) {
                res.isSuccess = true;
                res.opportunityId = result.getOpportunityId();
                accountIdByLeadId.put(leadId, result.getAccountId());
                contactIdByLeadId.put(leadId, result.getContactId());
                opportunityIdByLeadId.put(leadId, result.getOpportunityId());
            } else {
                res.isSuccess = false;
                res.errorMessage = formatErrors(result.getErrors());
                res.errorType = 'CONVERSION_FAILED';
            }
        }

        if (accountIdByLeadId.isEmpty()) {
            return responses;
        }

        createMeetingEvents(requests, conversionIndexes, responsesByIndex,
            contactIdByLeadId, opportunityIdByLeadId);
        transferLeadFieldsToAccounts(leadsById, accountIdByLeadId);
        transferDepartmentToContacts(leadsById, contactIdByLeadId);
        reconnectExternalRecords(accountIdByLeadId.keySet(), accountIdByLeadId);

        return responses;
    }

    // ─── Private Helpers ─────────────────────────────────────────────────

    /**
     * Resolves a converted Lead status, preferring the default converted status.
     * Database.convertLead validates convertedStatus against the LeadStatus value
     * (ApiName), not its label. When the status label is localized (e.g. "전환")
     * the ApiName can still be "Converted", so returning MasterLabel would fail
     * with "invalid convertedStatus".
     * @return ApiName of a converted LeadStatus
     * @throws LeadConvertServiceException when no converted status is configured
     */
    private static String getConvertedStatus() {
        List<LeadStatus> statuses = [
            SELECT ApiName
            FROM LeadStatus
            WHERE IsConverted = true
            WITH USER_MODE
            ORDER BY IsDefault DESC
            LIMIT 1
        ];
        if (statuses.isEmpty()) {
            throw new LeadConvertServiceException('No converted LeadStatus is configured in this org.');
        }
        return statuses[0].ApiName;
    }

    /**
     * Creates a "고객 미팅" Event for each successful conversion.
     * @param requests Original requests (source of meetingDateTime)
     * @param conversionIndexes Request indexes that were submitted for conversion
     * @param responsesByIndex Responses keyed by request index
     * @param contactIdByLeadId Created Contact Id keyed by Lead Id
     * @param opportunityIdByLeadId Created Opportunity Id keyed by Lead Id
     */
    private static void createMeetingEvents(
        List<Request> requests,
        List<Integer> conversionIndexes,
        Map<Integer, Response> responsesByIndex,
        Map<Id, Id> contactIdByLeadId,
        Map<Id, Id> opportunityIdByLeadId
    ) {
        List<Event> events = new List<Event>();
        for (Integer requestIndex : conversionIndexes) {
            Response res = responsesByIndex.get(requestIndex);
            if (res.isSuccess != true) {
                continue;
            }
            Request req = requests[requestIndex];
            if (req.createMeetingEvent == false) {
                continue; // caller keeps its own Event as the meeting record
            }
            Id opportunityId = opportunityIdByLeadId.get(req.leadId);
            events.add(new Event(
                Subject = EVENT_SUBJECT,
                WhatId = opportunityId,
                WhoId = contactIdByLeadId.get(req.leadId),
                StartDateTime = req.meetingDateTime,
                DurationInMinutes = 60
            ));
        }
        if (!events.isEmpty()) {
            insert as user events;
        }
    }

    /**
     * Copies Lead field values onto the created Accounts. Priority_Score__c is
     * always overwritten; the two external-id fields are set only when blank.
     * @param leadsById Source Leads keyed by Id
     * @param accountIdByLeadId Created Account Id keyed by Lead Id
     */
    private static void transferLeadFieldsToAccounts(
        Map<Id, Lead> leadsById,
        Map<Id, Id> accountIdByLeadId
    ) {
        Map<Id, Id> leadIdByAccountId = new Map<Id, Id>();
        for (Id leadId : accountIdByLeadId.keySet()) {
            leadIdByAccountId.put(accountIdByLeadId.get(leadId), leadId);
        }

        Map<Id, Account> accountsById = new Map<Id, Account>([
            SELECT Id, Priority_Score__c, Business_Registration_Number__c, Assigned_Company_Code__c
            FROM Account
            WHERE Id IN :leadIdByAccountId.keySet()
            WITH USER_MODE
        ]);

        List<Account> accountsToUpdate = new List<Account>();
        for (Account acc : accountsById.values()) {
            Lead sourceLead = leadsById.get(leadIdByAccountId.get(acc.Id));
            if (sourceLead == null) {
                continue;
            }
            acc.Priority_Score__c = sourceLead.Priority_Score__c;
            if (String.isBlank(acc.Business_Registration_Number__c)) {
                acc.Business_Registration_Number__c = sourceLead.Business_Registration_Number__c;
            }
            if (String.isBlank(acc.Assigned_Company_Code__c)) {
                acc.Assigned_Company_Code__c = sourceLead.Assigned_Company_Code__c;
            }
            accountsToUpdate.add(acc);
        }
        if (!accountsToUpdate.isEmpty()) {
            update as user accountsToUpdate;
        }
    }

    /**
     * Copies the Lead's Department__c onto the created Contact's standard
     * Department field. Salesforce's declarative lead-conversion mapping cannot
     * target a standard Contact field from a custom Lead field, so it is set
     * explicitly here. Blank Lead values are skipped so a Contact is never cleared.
     * @param leadsById Source Leads keyed by Id
     * @param contactIdByLeadId Created Contact Id keyed by Lead Id
     */
    private static void transferDepartmentToContacts(
        Map<Id, Lead> leadsById,
        Map<Id, Id> contactIdByLeadId
    ) {
        List<Contact> contactsToUpdate = new List<Contact>();
        for (Id leadId : contactIdByLeadId.keySet()) {
            Lead sourceLead = leadsById.get(leadId);
            if (sourceLead == null || String.isBlank(sourceLead.Department__c)) {
                continue;
            }
            contactsToUpdate.add(new Contact(
                Id = contactIdByLeadId.get(leadId),
                Department = sourceLead.Department__c
            ));
        }
        if (!contactsToUpdate.isEmpty()) {
            update as user contactsToUpdate;
        }
    }

    /**
     * Re-points CorporateFinancialStatement__c and ExternalSignal__c records
     * whose Lead__c matches a converted Lead to the newly created Account.
     * @param leadIds Converted Lead Ids
     * @param accountIdByLeadId Created Account Id keyed by Lead Id
     */
    private static void reconnectExternalRecords(Set<Id> leadIds, Map<Id, Id> accountIdByLeadId) {
        List<SObject> recordsToUpdate = new List<SObject>();

        for (CorporateFinancialStatement__c statement : [
            SELECT Id, Lead__c, Account__c
            FROM CorporateFinancialStatement__c
            WHERE Lead__c IN :leadIds
            WITH USER_MODE
        ]) {
            statement.Account__c = accountIdByLeadId.get(statement.Lead__c);
            recordsToUpdate.add(statement);
        }

        for (ExternalSignal__c signal : [
            SELECT Id, Lead__c, Account__c
            FROM ExternalSignal__c
            WHERE Lead__c IN :leadIds
            WITH USER_MODE
        ]) {
            signal.Account__c = accountIdByLeadId.get(signal.Lead__c);
            recordsToUpdate.add(signal);
        }

        if (!recordsToUpdate.isEmpty()) {
            update as user recordsToUpdate;
        }
    }

    /**
     * Joins database error messages into a single string.
     * @param errors Errors from a Database result
     * @return Concatenated error messages
     */
    private static String formatErrors(List<Database.Error> errors) {
        List<String> messages = new List<String>();
        for (Database.Error err : errors) {
            messages.add(err.getMessage());
        }
        return String.join(messages, '; ');
    }

    // ─── Request / Response DTOs ─────────────────────────────────────────

    /**
     * Input parameters from the calling Flow.
     */
    public class Request {
        @InvocableVariable(label='Lead Id' description='The Id of the Lead to convert' required=true)
        public Id leadId;

        @InvocableVariable(label='Meeting Date/Time' description='Start date and time of the customer meeting' required=true)
        public Datetime meetingDateTime;

        @InvocableVariable(label='Create Meeting Event' description='When false, skips creating the meeting Event (caller supplies its own). Defaults to true when null.')
        public Boolean createMeetingEvent;
    }

    /**
     * Output results returned to the calling Flow.
     */
    public class Response {
        @InvocableVariable(label='Opportunity Id' description='Id of the Opportunity created by the conversion')
        public Id opportunityId;

        @InvocableVariable(label='Success' description='Whether the conversion succeeded')
        public Boolean isSuccess;

        @InvocableVariable(label='Error Message' description='Error details if the conversion failed')
        public String errorMessage;

        @InvocableVariable(label='Error Type' description='Category of the failure if the conversion failed')
        public String errorType;
    }

    /**
     * Domain exception for Lead conversion failures.
     */
    public class LeadConvertServiceException extends Exception {}
}