/**
 * Trigger handler for Meeting_Note__c.
 *
 * Responsibilities by context:
 *   - before insert/update: mask PII in Raw_Content__c and populate
 *     Sanitized_Content__c and Masked_Count__c. Raw_Content__c is never modified.
 *   - after insert/update:  delegate Apex Managed Sharing to MeetingNoteSharingService.
 */
public with sharing class MeetingNoteTriggerHandler {
    /**
     * Routes the current trigger context to the appropriate handler method.
     */
    public void run() {
        if (Trigger.isBefore && (Trigger.isInsert || Trigger.isUpdate)) {
            applyMasking((List<Meeting_Note__c>) Trigger.new);
        } else if (Trigger.isAfter && Trigger.isInsert) {
            MeetingNoteSharingService.grantSharesForInsert((List<Meeting_Note__c>) Trigger.new);
        } else if (Trigger.isAfter && Trigger.isUpdate) {
            MeetingNoteSharingService.recalculateShares(
                (List<Meeting_Note__c>) Trigger.new,
                (Map<Id, Meeting_Note__c>) Trigger.oldMap
            );
        }
    }

    /**
     * Masks the raw content of each note (when present) and stores the sanitized
     * text and masked value count. The original Raw_Content__c is left untouched.
     * Runs in before context so field assignments persist without extra DML.
     *
     * @param notes Trigger.new Meeting_Note__c records.
     */
    private void applyMasking(List<Meeting_Note__c> notes) {
        if (notes == null || notes.isEmpty()) {
            return;
        }
        for (Meeting_Note__c note : notes) {
            if (String.isBlank(note.Raw_Content__c)) {
                note.Sanitized_Content__c = note.Raw_Content__c;
                note.Masked_Count__c = 0;
                continue;
            }
            MaskingService.MaskingResult result = MaskingService.mask(note.Raw_Content__c);
            note.Sanitized_Content__c = result.sanitizedText;
            note.Masked_Count__c = result.maskedCount;
        }
    }
}