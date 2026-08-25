/**
 * Single trigger for Meeting_Note__c. Delegates all logic to
 * MeetingNoteTriggerHandler:
 *   - before insert/update: PII masking into Sanitized_Content__c / Masked_Count__c
 *   - after insert/update:  Apex Managed Sharing via MeetingNoteSharingService
 */
trigger MeetingNoteTrigger on Meeting_Note__c (before insert, before update, after insert, after update) {
    new MeetingNoteTriggerHandler().run();
}