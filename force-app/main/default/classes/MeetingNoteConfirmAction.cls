/**
 * Invocable action that confirms an agent's meeting recommendation and appends it
 * to the linked Opportunity's running meeting log.
 *
 * For each request the action reads the Meeting_Note__c's Sanitized_Content__c and
 * the supplied recommendationText, then prepends a dated block to the head of the
 * related Opportunity's Meeting_Log__c so the newest entry is always on top. The
 * Opportunity's Last_Meeting_Date__c is set to today.
 *
 * Raw_Content__c is never read or written — only the sanitized content reaches the
 * log, by design.
 *
 * All reads and the update run in user mode; if the running user cannot access the
 * Meeting Note or its Opportunity, that request's Response reports the failure
 * instead of throwing, so a partial batch still commits the accessible records.
 *
 * Callable from Flows, Process Builder, and Agentforce.
 */
public with sharing class MeetingNoteConfirmAction {

    /**
     * Confirms each meeting recommendation and updates the related Opportunity log.
     *
     * @param requests List of Request inputs (meetingNoteId + recommendationText)
     * @return List of Response outputs, one per request, in the same order
     */
    @InvocableMethod(
        label='Confirm Meeting Note Recommendation'
        description='Appends the sanitized meeting note and agent recommendation to the top of the Opportunity meeting log and updates the last meeting date.'
        category='Sales'
    )
    public static List<Response> confirm(List<Request> requests) {
        List<Response> responses = new List<Response>();
        if (requests == null || requests.isEmpty()) {
            return responses;
        }

        // Bulkified read of the requested Meeting Notes (user mode). Raw_Content__c is
        // deliberately excluded from the SELECT so it can never leak into the log.
        Set<Id> meetingNoteIds = new Set<Id>();
        for (Request req : requests) {
            if (req != null && req.meetingNoteId != null) {
                meetingNoteIds.add(req.meetingNoteId);
            }
        }

        Map<Id, Meeting_Note__c> notesById = meetingNoteIds.isEmpty()
            ? new Map<Id, Meeting_Note__c>()
            : new Map<Id, Meeting_Note__c>([
                SELECT Id, Sanitized_Content__c, Opportunity__c
                FROM Meeting_Note__c
                WHERE Id IN :meetingNoteIds
                WITH USER_MODE
            ]);

        // Bulkified read of the related Opportunities (user mode) so the log can be
        // prepended to the current value.
        Set<Id> opportunityIds = new Set<Id>();
        for (Meeting_Note__c note : notesById.values()) {
            if (note.Opportunity__c != null) {
                opportunityIds.add(note.Opportunity__c);
            }
        }

        Map<Id, Opportunity> opportunitiesById = opportunityIds.isEmpty()
            ? new Map<Id, Opportunity>()
            : new Map<Id, Opportunity>([
                SELECT Id, Meeting_Log__c, Last_Meeting_Date__c
                FROM Opportunity
                WHERE Id IN :opportunityIds
                WITH USER_MODE
            ]);

        Date today = Date.today();
        String dateHeader = DateTime.newInstance(today.year(), today.month(), today.day())
            .format('yyyy-MM-dd');

        // Process requests in order, prepending each entry to the front of the log.
        // Because entries are prepended, the last request for a given Opportunity ends
        // up at the very top — newest on top. Opportunities are mutated in the map so
        // multiple requests for the same Opportunity accumulate before the single DML.
        Map<Id, Opportunity> opportunitiesToUpdate = new Map<Id, Opportunity>();
        for (Request req : requests) {
            responses.add(processRequest(req, notesById, opportunitiesById,
                opportunitiesToUpdate, dateHeader, today));
        }

        if (!opportunitiesToUpdate.isEmpty()) {
            // Partial-success update in user mode: an FLS/CRUD or record-level failure
            // on one Opportunity does not roll back the rest of the batch.
            List<Database.SaveResult> saveResults = Database.update(
                opportunitiesToUpdate.values(), false, AccessLevel.USER_MODE);
            applySaveResults(saveResults, opportunitiesToUpdate.values(), responses);
        }

        return responses;
    }

    /**
     * Validates one request, builds the dated log entry, and stages the Opportunity
     * for update. Failures are reported on the Response rather than thrown.
     *
     * @param req The input request
     * @param notesById Accessible Meeting Notes keyed by Id
     * @param opportunitiesById Accessible Opportunities keyed by Id (mutated in place)
     * @param opportunitiesToUpdate Accumulator of Opportunities needing a DML update
     * @param dateHeader Today's date formatted as yyyy-MM-dd
     * @param today Today's date for Last_Meeting_Date__c
     * @return A populated Response for this request
     */
    private static Response processRequest(
        Request req,
        Map<Id, Meeting_Note__c> notesById,
        Map<Id, Opportunity> opportunitiesById,
        Map<Id, Opportunity> opportunitiesToUpdate,
        String dateHeader,
        Date today
    ) {
        Response res = new Response();
        res.isSuccess = false;

        if (req == null || req.meetingNoteId == null) {
            res.errorMessage = 'A meetingNoteId is required.';
            res.errorType = 'InvalidInput';
            return res;
        }

        Meeting_Note__c note = notesById.get(req.meetingNoteId);
        if (note == null) {
            res.errorMessage = 'Meeting Note not found or not accessible: ' + req.meetingNoteId;
            res.errorType = 'RecordNotAccessible';
            return res;
        }

        if (note.Opportunity__c == null) {
            res.errorMessage = 'Meeting Note is not linked to an Opportunity: ' + req.meetingNoteId;
            res.errorType = 'MissingRelationship';
            return res;
        }

        Opportunity opp = opportunitiesById.get(note.Opportunity__c);
        if (opp == null) {
            res.errorMessage = 'Related Opportunity not found or not accessible: ' + note.Opportunity__c;
            res.errorType = 'RecordNotAccessible';
            return res;
        }

        String entry = buildEntry(dateHeader, note.Sanitized_Content__c, req.recommendationText);
        opp.Meeting_Log__c = prepend(entry, opp.Meeting_Log__c);
        opp.Last_Meeting_Date__c = today;

        opportunitiesToUpdate.put(opp.Id, opp);

        res.isSuccess = true;
        res.opportunityId = opp.Id;
        return res;
    }

    /**
     * Builds a single dated log block from the sanitized note content and the
     * recommendation. Raw content is never a parameter here.
     *
     * @param dateHeader Today's date formatted as yyyy-MM-dd
     * @param sanitizedContent The Meeting Note's Sanitized_Content__c (may be blank)
     * @param recommendationText The agent recommendation summary (may be blank)
     * @return A formatted "[YYYY-MM-DD] ..." block
     */
    private static String buildEntry(String dateHeader, String sanitizedContent, String recommendationText) {
        List<String> parts = new List<String>();
        if (!String.isBlank(sanitizedContent)) {
            parts.add(sanitizedContent.trim());
        }
        if (!String.isBlank(recommendationText)) {
            parts.add(recommendationText.trim());
        }
        String body = String.join(parts, '\n\n');
        return '[' + dateHeader + ']\n' + body;
    }

    /**
     * Prepends a new entry to the front of the existing log so the newest entry is
     * on top, preserving prior entries below.
     *
     * @param entry The new dated entry
     * @param existingLog The current Meeting_Log__c value (may be blank)
     * @return The combined log with the new entry first
     */
    private static String prepend(String entry, String existingLog) {
        if (String.isBlank(existingLog)) {
            return entry;
        }
        return entry + '\n\n' + existingLog;
    }

    /**
     * Maps DML failures back onto the Responses whose Opportunity failed to save,
     * flipping them from success to failure with the DML error detail.
     *
     * @param saveResults DML results in the same order as updatedOpportunities
     * @param updatedOpportunities The Opportunities passed to Database.update
     * @param responses The Responses to annotate on failure
     */
    private static void applySaveResults(
        List<Database.SaveResult> saveResults,
        List<Opportunity> updatedOpportunities,
        List<Response> responses
    ) {
        Set<Id> failedOpportunityIds = new Set<Id>();
        Map<Id, String> errorByOpportunityId = new Map<Id, String>();
        for (Integer i = 0; i < saveResults.size(); i++) {
            Database.SaveResult sr = saveResults[i];
            if (!sr.isSuccess()) {
                Id failedId = updatedOpportunities[i].Id;
                failedOpportunityIds.add(failedId);
                errorByOpportunityId.put(failedId, sr.getErrors()[0].getMessage());
            }
        }

        if (failedOpportunityIds.isEmpty()) {
            return;
        }

        for (Response res : responses) {
            if (res.isSuccess && failedOpportunityIds.contains(res.opportunityId)) {
                res.isSuccess = false;
                res.errorMessage = errorByOpportunityId.get(res.opportunityId);
                res.errorType = 'DmlException';
            }
        }
    }

    /**
     * Input parameters from the calling Flow/agent.
     */
    public class Request {
        @InvocableVariable(label='Meeting Note Id' description='The Meeting_Note__c whose sanitized content should be logged' required=true)
        public Id meetingNoteId;

        @InvocableVariable(label='Recommendation Text' description='The agent recommendation summary to append to the meeting log' required=false)
        public String recommendationText;
    }

    /**
     * Output returned to the calling Flow/agent for each request.
     */
    public class Response {
        @InvocableVariable(label='Is Success' description='True when the meeting log was updated for this request')
        public Boolean isSuccess;

        @InvocableVariable(label='Opportunity Id' description='The Opportunity whose meeting log was updated, when successful')
        public Id opportunityId;

        @InvocableVariable(label='Error Message' description='Human-readable error detail when the request fails')
        public String errorMessage;

        @InvocableVariable(label='Error Type' description='Short error classification when the request fails')
        public String errorType;
    }
}