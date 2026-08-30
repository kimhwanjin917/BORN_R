/**
 * Trigger handler for Meeting_Note__c.
 *
 * Responsibilities by context:
 *   - before insert/update: mask PII in Raw_Content__c and populate
 *     Sanitized_Content__c and Masked_Count__c. Raw_Content__c is never modified.
 *     Then backfill the Account/Meeting Date relationship fields that the caller
 *     did not supply, so a note is never orphaned from its company history.
 *   - after insert/update:  delegate Apex Managed Sharing to MeetingNoteSharingService.
 */
public with sharing class MeetingNoteTriggerHandler {
    /**
     * Routes the current trigger context to the appropriate handler method.
     */
    public void run() {
        if (Trigger.isBefore && (Trigger.isInsert || Trigger.isUpdate)) {
            applyMasking((List<Meeting_Note__c>) Trigger.new);
            backfillRelationships((List<Meeting_Note__c>) Trigger.new);
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
        // 이미 해석된 Meeting Note 관계에서 현재 미팅의 담당자/고객사 이름을 읽는다.
        // 새 context resolver 를 만들지 않고 note 의 Account__c / Contact__c 를 그대로 쓴다.
        Map<Id, String> accountNames = new Map<Id, String>();
        Map<Id, String> contactNames = new Map<Id, String>();
        Set<Id> accountIds = new Set<Id>();
        Set<Id> contactIds = new Set<Id>();
        for (Meeting_Note__c note : notes) {
            if (note.Account__c != null) accountIds.add(note.Account__c);
            if (note.Contact__c != null) contactIds.add(note.Contact__c);
        }
        if (!accountIds.isEmpty()) {
            for (Account acct : [SELECT Id, Name FROM Account WHERE Id IN :accountIds]) {
                accountNames.put(acct.Id, acct.Name);
            }
        }
        if (!contactIds.isEmpty()) {
            for (Contact con : [SELECT Id, Name FROM Contact WHERE Id IN :contactIds]) {
                contactNames.put(con.Id, con.Name);
            }
        }

        for (Meeting_Note__c note : notes) {
            if (String.isBlank(note.Raw_Content__c)) {
                note.Sanitized_Content__c = note.Raw_Content__c;
                note.Masked_Count__c = 0;
                continue;
            }
            MaskingService.MaskingResult result = MaskingService.mask(
                note.Raw_Content__c,
                contactNames.get(note.Contact__c),
                accountNames.get(note.Account__c)
            );
            note.Sanitized_Content__c = result.sanitizedText;
            note.Masked_Count__c = result.maskedCount;
        }
    }

    /**
     * Safety net for notes created outside the Meeting Session flow (data loads,
     * the object's own New button, other automations). Only ever fills blanks —
     * a value the caller supplied is never overwritten, so the flow's resolved
     * context always wins.
     *
     *   Account__c      <- Opportunity.AccountId, else Contact.AccountId
     *   Meeting_Date__c <- today
     *
     * @param notes Trigger.new Meeting_Note__c records.
     */
    private void backfillRelationships(List<Meeting_Note__c> notes) {
        if (notes == null || notes.isEmpty()) {
            return;
        }

        // Collect the parents needed to fill a blank Account, in bulk.
        Set<Id> opportunityIds = new Set<Id>();
        Set<Id> contactIds = new Set<Id>();
        for (Meeting_Note__c note : notes) {
            if (note.Account__c != null) {
                continue;
            }
            if (note.Opportunity__c != null) {
                opportunityIds.add(note.Opportunity__c);
            } else if (note.Contact__c != null) {
                contactIds.add(note.Contact__c);
            }
        }

        Map<Id, Opportunity> opportunityById = opportunityIds.isEmpty()
            ? new Map<Id, Opportunity>()
            : new Map<Id, Opportunity>([
                SELECT Id, AccountId FROM Opportunity WHERE Id IN :opportunityIds WITH USER_MODE
            ]);
        Map<Id, Contact> contactById = contactIds.isEmpty()
            ? new Map<Id, Contact>()
            : new Map<Id, Contact>([
                SELECT Id, AccountId FROM Contact WHERE Id IN :contactIds WITH USER_MODE
            ]);

        Date today = Date.today();
        for (Meeting_Note__c note : notes) {
            if (note.Account__c == null && note.Opportunity__c != null) {
                Opportunity opp = opportunityById.get(note.Opportunity__c);
                if (opp != null) {
                    note.Account__c = opp.AccountId;
                }
            }
            if (note.Account__c == null && note.Contact__c != null) {
                Contact contact = contactById.get(note.Contact__c);
                if (contact != null) {
                    note.Account__c = contact.AccountId;
                }
            }
            if (note.Meeting_Date__c == null) {
                note.Meeting_Date__c = today;
            }
        }
    }
}