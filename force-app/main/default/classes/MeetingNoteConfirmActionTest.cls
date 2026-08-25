/**
 * Tests for MeetingNoteConfirmAction.
 *
 * Test data is built inline via @TestSetup (TestDataFactory is a frozen shared
 * file and is intentionally not used here). Account requires Industry and
 * Business_Registration_Number__c to satisfy the org's active validation rules.
 *
 * Coverage focuses on the Invocable boundary: two sequential invocations must
 * accumulate newest-on-top, Last_Meeting_Date__c must be set to today, and
 * Raw_Content__c must never appear in the Opportunity meeting log.
 *
 * The Meeting_Note__c before-trigger derives Sanitized_Content__c by masking
 * Raw_Content__c, so test data seeds Raw_Content__c with real PII (phone
 * numbers). The raw phone digits get masked out of Sanitized_Content__c, which
 * lets the "raw never logged" assertion verify the pre-mask digits are absent.
 */
@isTest
private class MeetingNoteConfirmActionTest {

    // Raw phone numbers seeded into Raw_Content__c; the trigger masks these to
    // 010-****-**** in Sanitized_Content__c, so the digit runs below must never
    // reach the meeting log.
    private static final String RAW_PII_FIRST = '010-1111-2222';
    private static final String RAW_PII_SECOND = '010-3333-4444';

    @TestSetup
    static void makeData() {
        Account acct = new Account(
            Name = 'Borny Test Account',
            Industry = 'Banking',
            Business_Registration_Number__c = '1234567890'
        );
        insert acct;

        Opportunity opp = new Opportunity(
            Name = 'Borny Test Opportunity',
            AccountId = acct.Id,
            Amount = 250000,
            StageName = 'Prospecting',
            CloseDate = Date.newInstance(2026, 12, 31)
        );
        insert opp;

        // Two Meeting Notes on the same Opportunity. The before-trigger recomputes
        // Sanitized_Content__c from Raw_Content__c (masking the phone numbers), so
        // any Sanitized_Content__c set here would be overwritten — seed only Raw.
        // The 'First'/'Second' tokens survive masking and identify each note.
        List<Meeting_Note__c> notes = new List<Meeting_Note__c>{
            new Meeting_Note__c(
                Opportunity__c = opp.Id,
                Raw_Content__c = 'First meeting notes, contact ' + RAW_PII_FIRST
            ),
            new Meeting_Note__c(
                Opportunity__c = opp.Id,
                Raw_Content__c = 'Second meeting notes, contact ' + RAW_PII_SECOND
            )
        };
        insert notes;
    }

    /**
     * Two sequential invocations must leave the newest entry at the top of the log
     * while preserving the earlier entry below it.
     */
    @isTest
    static void shouldAccumulateNewestOnTop_WhenInvokedTwice() {
        // Sanitized_Content__c is a textarea (not sortable), so identify each note
        // by the surviving 'First'/'Second' token rather than ORDER BY.
        Id firstNoteId;
        Id secondNoteId;
        for (Meeting_Note__c note : [
            SELECT Id, Sanitized_Content__c FROM Meeting_Note__c
        ]) {
            if (note.Sanitized_Content__c != null &&
                    note.Sanitized_Content__c.startsWith('First')) {
                firstNoteId = note.Id;
            } else {
                secondNoteId = note.Id;
            }
        }
        System.assertNotEquals(null, firstNoteId, 'First note should be found');
        System.assertNotEquals(null, secondNoteId, 'Second note should be found');

        Test.startTest();
        MeetingNoteConfirmAction.confirm(new List<MeetingNoteConfirmAction.Request>{
            buildRequest(firstNoteId, 'First recommendation')
        });
        MeetingNoteConfirmAction.confirm(new List<MeetingNoteConfirmAction.Request>{
            buildRequest(secondNoteId, 'Second recommendation')
        });
        Test.stopTest();

        Opportunity opp = [SELECT Id, Meeting_Log__c FROM Opportunity LIMIT 1];
        String log = opp.Meeting_Log__c;

        System.assertNotEquals(null, log, 'Meeting log should be populated after two invocations');

        Integer secondPos = log.indexOf('Second meeting notes');
        Integer firstPos = log.indexOf('First meeting notes');
        System.assertNotEquals(-1, firstPos, 'First entry must remain in the log');
        System.assertNotEquals(-1, secondPos, 'Second entry must be present in the log');
        System.assert(secondPos < firstPos,
            'Newest (second) entry must appear above the earlier (first) entry');

        // Both recommendation summaries are present.
        System.assert(log.contains('First recommendation'), 'First recommendation should be logged');
        System.assert(log.contains('Second recommendation'), 'Second recommendation should be logged');
    }

    /**
     * Last_Meeting_Date__c must be set to today's date after a successful confirm.
     */
    @isTest
    static void shouldUpdateLastMeetingDate_WhenConfirmed() {
        Meeting_Note__c note = [SELECT Id FROM Meeting_Note__c LIMIT 1];

        Test.startTest();
        List<MeetingNoteConfirmAction.Response> responses =
            MeetingNoteConfirmAction.confirm(new List<MeetingNoteConfirmAction.Request>{
                buildRequest(note.Id, 'A recommendation')
            });
        Test.stopTest();

        System.assertEquals(1, responses.size(), 'One response expected for one request');
        System.assertEquals(true, responses[0].isSuccess, 'Request should succeed');

        Opportunity opp = [SELECT Id, Last_Meeting_Date__c FROM Opportunity LIMIT 1];
        System.assertEquals(Date.today(), opp.Last_Meeting_Date__c,
            'Last_Meeting_Date__c must be set to today');
    }

    /**
     * Raw_Content__c must never be written into the Opportunity meeting log.
     */
    @isTest
    static void shouldExcludeRawContent_WhenConfirmed() {
        List<Meeting_Note__c> notes = [SELECT Id FROM Meeting_Note__c];

        Test.startTest();
        List<MeetingNoteConfirmAction.Request> requests =
            new List<MeetingNoteConfirmAction.Request>();
        for (Meeting_Note__c note : notes) {
            requests.add(buildRequest(note.Id, 'Rec for ' + note.Id));
        }
        MeetingNoteConfirmAction.confirm(requests);
        Test.stopTest();

        Opportunity opp = [SELECT Id, Meeting_Log__c FROM Opportunity LIMIT 1];
        System.assertNotEquals(null, opp.Meeting_Log__c, 'Meeting log should be populated');
        // The raw phone digits live only in Raw_Content__c; the trigger masks them
        // out of Sanitized_Content__c. Their absence proves raw content never
        // reached the log (only the masked, sanitized text did).
        System.assert(!opp.Meeting_Log__c.contains(RAW_PII_FIRST),
            'Raw phone number from Raw_Content__c must never appear in the meeting log');
        System.assert(!opp.Meeting_Log__c.contains(RAW_PII_SECOND),
            'Raw phone number from Raw_Content__c must never appear in the meeting log');
        System.assert(!opp.Meeting_Log__c.contains('1111'),
            'Unmasked raw digits must never appear in the meeting log');
    }

    /**
     * The dated header must lead the entry so entries are chronologically labeled.
     */
    @isTest
    static void shouldPrefixDatedHeader_WhenConfirmed() {
        Meeting_Note__c note = [SELECT Id FROM Meeting_Note__c LIMIT 1];
        Date today = Date.today();
        String expectedHeader = '[' + DateTime.newInstance(
            today.year(), today.month(), today.day()).format('yyyy-MM-dd') + ']';

        Test.startTest();
        MeetingNoteConfirmAction.confirm(new List<MeetingNoteConfirmAction.Request>{
            buildRequest(note.Id, 'A recommendation')
        });
        Test.stopTest();

        Opportunity opp = [SELECT Id, Meeting_Log__c FROM Opportunity LIMIT 1];
        System.assert(opp.Meeting_Log__c.startsWith(expectedHeader),
            'Log entry should start with the dated header ' + expectedHeader);
    }

    /**
     * Null/empty request lists and a null meetingNoteId are handled without throwing.
     */
    @isTest
    static void shouldReportError_WhenMeetingNoteIdMissing() {
        Test.startTest();
        List<MeetingNoteConfirmAction.Response> emptyResponses =
            MeetingNoteConfirmAction.confirm(
                new List<MeetingNoteConfirmAction.Request>());
        List<MeetingNoteConfirmAction.Response> nullIdResponses =
            MeetingNoteConfirmAction.confirm(new List<MeetingNoteConfirmAction.Request>{
                buildRequest(null, 'Orphan recommendation')
            });
        Test.stopTest();

        System.assertEquals(0, emptyResponses.size(),
            'Empty request list should yield an empty response list');
        System.assertEquals(1, nullIdResponses.size(), 'One response expected for one request');
        System.assertEquals(false, nullIdResponses[0].isSuccess,
            'Missing meetingNoteId should not succeed');
        System.assertEquals('InvalidInput', nullIdResponses[0].errorType,
            'Missing meetingNoteId should report InvalidInput');
    }

    private static MeetingNoteConfirmAction.Request buildRequest(Id meetingNoteId, String recommendationText) {
        MeetingNoteConfirmAction.Request req = new MeetingNoteConfirmAction.Request();
        req.meetingNoteId = meetingNoteId;
        req.recommendationText = recommendationText;
        return req;
    }
}