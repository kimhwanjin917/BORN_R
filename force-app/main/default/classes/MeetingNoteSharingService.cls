/**
 * Grants Apex Managed Sharing on Meeting_Note__c records to the owner of the
 * related Opportunity. Meeting_Note__c is OWD Private and its Opportunity__c
 * lookup does not cascade sharing, so the related Opportunity's owner (RM) has
 * no implicit access. This service creates a Meeting_Note__Share (Edit) row
 * using the custom sharing reason `for_Manager__c` as the rowCause.
 *
 * Invoke from the Meeting_Note__c trigger handler on after insert and on
 * after update when the Opportunity__c lookup changes.
 */
public with sharing class MeetingNoteSharingService {
    private static final String ROW_CAUSE = Schema.Meeting_Note__Share.RowCause.for_Manager__c;
    private static final String ACCESS_LEVEL_EDIT = 'Edit';

    /**
     * Raised when Apex Managed Sharing rows cannot be written.
     */
    public class MeetingNoteSharingException extends Exception {}

    /**
     * Convenience entry point for after-insert trigger context.
     *
     * @param newNotes Newly inserted Meeting_Note__c records (Trigger.new).
     * @example
     * MeetingNoteSharingService.grantSharesForInsert(Trigger.new);
     */
    public static void grantSharesForInsert(List<Meeting_Note__c> newNotes) {
        recalculateShares(newNotes, null);
    }

    /**
     * Grants (insert) or recomputes (update) the Opportunity-owner share for the
     * supplied Meeting_Note__c records. On update, only notes whose Opportunity__c
     * lookup changed are reprocessed: stale `for_Manager__c` shares are removed and
     * fresh ones are created for the new Opportunity owner.
     *
     * @param newNotes Trigger.new records to (re)share. Null/empty is a no-op.
     * @param oldByNoteId Trigger.oldMap; pass null for insert context.
     * @example
     * MeetingNoteSharingService.recalculateShares(Trigger.new, Trigger.oldMap);
     */
    public static void recalculateShares(List<Meeting_Note__c> newNotes, Map<Id, Meeting_Note__c> oldByNoteId) {
        if (newNotes == null || newNotes.isEmpty()) {
            return;
        }

        Boolean isInsert = (oldByNoteId == null);
        List<Meeting_Note__c> notesToProcess = selectNotesNeedingReshare(newNotes, oldByNoteId, isInsert);
        if (notesToProcess.isEmpty()) {
            return;
        }

        Set<Id> opportunityIds = new Set<Id>();
        for (Meeting_Note__c note : notesToProcess) {
            opportunityIds.add(note.Opportunity__c);
        }

        Map<Id, Opportunity> opportunityById = new Map<Id, Opportunity>(
            [SELECT Id, OwnerId FROM Opportunity WHERE Id IN :opportunityIds WITH USER_MODE]
        );

        // On update where the Opportunity changed, remove the previously granted
        // managed shares before re-granting for the new owner.
        if (!isInsert) {
            deleteStaleShares(notesToProcess);
        }

        List<Meeting_Note__Share> sharesToInsert = new List<Meeting_Note__Share>();
        for (Meeting_Note__c note : notesToProcess) {
            Opportunity opp = opportunityById.get(note.Opportunity__c);
            if (opp == null) {
                continue;
            }
            // The record owner already has full access; a share row to the owner
            // is redundant and rejected by the platform.
            if (opp.OwnerId == note.OwnerId) {
                continue;
            }
            Meeting_Note__Share share = new Meeting_Note__Share();
            share.ParentId = note.Id;
            share.UserOrGroupId = opp.OwnerId;
            share.AccessLevel = ACCESS_LEVEL_EDIT;
            share.RowCause = ROW_CAUSE;
            sharesToInsert.add(share);
        }

        if (sharesToInsert.isEmpty()) {
            return;
        }

        // Apex Managed Sharing is a platform-level grant: custom-rowCause share
        // rows can only be written by Apex in system context, and the running
        // (note-creating) user is not expected to hold edit access on the share
        // object. SYSTEM_MODE is therefore required and justified here.
        List<Database.SaveResult> results = Database.insert(sharesToInsert, false, AccessLevel.SYSTEM_MODE);
        assertNoShareErrors(results);
    }

    /**
     * Filters the trigger records down to those that need a (re)share: notes with
     * an Opportunity on insert, or notes whose Opportunity__c lookup changed on update.
     *
     * @param newNotes Trigger.new records.
     * @param oldByNoteId Trigger.oldMap (null on insert).
     * @param isInsert Whether the context is insert.
     * @return Notes requiring share recomputation.
     */
    private static List<Meeting_Note__c> selectNotesNeedingReshare(
        List<Meeting_Note__c> newNotes,
        Map<Id, Meeting_Note__c> oldByNoteId,
        Boolean isInsert
    ) {
        List<Meeting_Note__c> notesToProcess = new List<Meeting_Note__c>();
        for (Meeting_Note__c note : newNotes) {
            if (note.Opportunity__c == null) {
                continue;
            }
            if (isInsert || opportunityChanged(note, oldByNoteId)) {
                notesToProcess.add(note);
            }
        }
        return notesToProcess;
    }

    /**
     * @param note Current-state note.
     * @param oldByNoteId Trigger.oldMap.
     * @return True when the Opportunity__c lookup differs from its prior value.
     */
    private static Boolean opportunityChanged(Meeting_Note__c note, Map<Id, Meeting_Note__c> oldByNoteId) {
        Meeting_Note__c oldNote = oldByNoteId.get(note.Id);
        return (oldNote != null && oldNote.Opportunity__c != note.Opportunity__c);
    }

    /**
     * Deletes the existing `for_Manager__c` managed shares for the supplied notes
     * so they can be recomputed for the current Opportunity owner.
     *
     * @param notes Notes whose stale managed shares must be removed.
     */
    private static void deleteStaleShares(List<Meeting_Note__c> notes) {
        Set<Id> noteIds = new Set<Id>();
        for (Meeting_Note__c note : notes) {
            noteIds.add(note.Id);
        }
        if (noteIds.isEmpty()) {
            return;
        }
        List<Meeting_Note__Share> existingShares = [
            SELECT Id
            FROM Meeting_Note__Share
            WHERE ParentId IN :noteIds AND RowCause = :ROW_CAUSE
            WITH SYSTEM_MODE
        ];
        if (!existingShares.isEmpty()) {
            Database.delete(existingShares, false, AccessLevel.SYSTEM_MODE);
        }
    }

    /**
     * Inspects share insert results and raises on genuine failures, tolerating
     * duplicate-row errors (share already present).
     *
     * @param results Save results from the share insert.
     * @throws MeetingNoteSharingException When a non-duplicate error occurs.
     */
    private static void assertNoShareErrors(List<Database.SaveResult> results) {
        List<String> errors = new List<String>();
        for (Database.SaveResult result : results) {
            if (result.isSuccess()) {
                continue;
            }
            for (Database.Error error : result.getErrors()) {
                if (error.getStatusCode() == StatusCode.DUPLICATE_VALUE) {
                    continue;
                }
                errors.add(error.getStatusCode() + ': ' + error.getMessage());
            }
        }
        if (!errors.isEmpty()) {
            throw new MeetingNoteSharingException(
                'Failed to grant Meeting Note sharing: ' + String.join(errors, '; ')
            );
        }
    }
}