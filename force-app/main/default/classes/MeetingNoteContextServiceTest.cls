/**
 * Tests for MeetingNoteContextService.
 *
 * Test data is built inline in @TestSetup (team rule: TestDataFactory is a frozen
 * shared file and must not be used or modified here). Account requires Industry
 * (Required_PL validation rule) and Business_Registration_Number__c; Contact
 * requires Department, Email, LastName and name_new__c. Korean names are stored entirely in LastName so
 * Contact.Name is deterministic regardless of org locale.
 *
 * The last test is the one the data model actually has to satisfy: whichever
 * object the session is launched from, the resulting Meeting_Note__c must come
 * out with the same shape.
 */
@isTest
private class MeetingNoteContextServiceTest {

    private static final Date MEETING_DAY = Date.newInstance(2026, 8, 20);

    @TestSetup
    static void makeData() {
        List<Account> accounts = new List<Account>{
            // 진행 중 기회 1건 — 자동 연결되어야 한다.
            new Account(Name = 'Borny Sole Opp Account', Industry = 'Banking',
                Business_Registration_Number__c = '1000000001'),
            // 진행 중 기회 2건 — 자동 연결하면 안 된다.
            new Account(Name = 'Borny Many Opp Account', Industry = 'Banking',
                Business_Registration_Number__c = '1000000002'),
            // 진행 중 기회 0건.
            new Account(Name = 'Borny No Opp Account', Industry = 'Banking',
                Business_Registration_Number__c = '1000000003')
        };
        insert accounts;

        insert new List<Opportunity>{
            new Opportunity(Name = 'Sole Opp', AccountId = accounts[0].Id,
                StageName = 'Prospecting', CloseDate = Date.newInstance(2026, 12, 31)),
            new Opportunity(Name = 'Many Opp A', AccountId = accounts[1].Id,
                StageName = 'Prospecting', CloseDate = Date.newInstance(2026, 12, 31)),
            new Opportunity(Name = 'Many Opp B', AccountId = accounts[1].Id,
                StageName = 'Prospecting', CloseDate = Date.newInstance(2026, 11, 30))
        };

        // Observed in this org: a Contact insert without these fails with
        //   REQUIRED_FIELD_MISSING, Required fields are missing: [LastName, name_new__c]
        // even when LastName is set. The cause has not been established; supplying
        // both fields (as MaskingServiceTest does) is what makes the insert succeed.
        Database.insert(new List<Contact>{
            new Contact(LastName = '김민수', name_new__c = '김민수', AccountId = accounts[0].Id,
                Department = 'Sales', Email = 'ctx1@test.example'),
            // 고객사가 없는 담당자 — Account 해석이 실패하는 경로.
            new Contact(LastName = '이영희', name_new__c = '이영희',
                Department = 'Sales', Email = 'ctx2@test.example')
        }, AccessLevel.SYSTEM_MODE);
    }

    // ─── 조회 헬퍼 ────────────────────────────────────────────────────────

    private static Account account(String name) {
        return [SELECT Id FROM Account WHERE Name = :name LIMIT 1];
    }
    private static Opportunity opportunity(String name) {
        return [SELECT Id, AccountId FROM Opportunity WHERE Name = :name LIMIT 1];
    }
    private static Contact contact(String lastName) {
        return [SELECT Id, AccountId FROM Contact WHERE LastName = :lastName LIMIT 1];
    }

    private static MeetingNoteContextService.Result resolve(Id recordId) {
        return resolve(recordId, null);
    }

    private static MeetingNoteContextService.Result resolve(Id recordId, Id selectedOpportunityId) {
        MeetingNoteContextService.Request req = new MeetingNoteContextService.Request();
        req.recordId = recordId == null ? null : String.valueOf(recordId);
        req.selectedOpportunityId = selectedOpportunityId == null
            ? null
            : String.valueOf(selectedOpportunityId);
        return MeetingNoteContextService.resolveContext(
            new List<MeetingNoteContextService.Request>{ req })[0];
    }

    private static Event buildEvent(Id whatId, Id whoId) {
        return new Event(
            Subject = '고객 미팅',
            StartDateTime = DateTime.newInstance(MEETING_DAY, Time.newInstance(10, 0, 0, 0)),
            DurationInMinutes = 60,
            WhatId = whatId,
            WhoId = whoId
        );
    }

    // ─── Opportunity 진입 ─────────────────────────────────────────────────

    @isTest
    static void shouldResolveOpportunityAndAccount_WhenLaunchedFromOpportunity() {
        Opportunity opp = opportunity('Sole Opp');

        Test.startTest();
        MeetingNoteContextService.Result result = resolve(opp.Id);
        Test.stopTest();

        Assert.areEqual('Opportunity', result.sourceObject, 'Source object should be Opportunity');
        Assert.areEqual(String.valueOf(opp.Id), result.opportunityId, 'The entry Opportunity is used as-is');
        Assert.areEqual(String.valueOf(opp.AccountId), result.accountId, 'Account comes from Opportunity.AccountId');
        Assert.areEqual(null, result.contactId, 'Contact must not be guessed from an Opportunity');
        Assert.areEqual(null, result.eventId, 'No Event is involved');
        Assert.areEqual(Date.today(), result.meetingDate, 'Meeting date defaults to today');
    }

    // ─── Account 진입 ─────────────────────────────────────────────────────

    @isTest
    static void shouldLinkSoleOpenOpportunity_WhenLaunchedFromAccountWithOneOpp() {
        Account acct = account('Borny Sole Opp Account');
        Opportunity opp = opportunity('Sole Opp');

        Test.startTest();
        MeetingNoteContextService.Result result = resolve(acct.Id);
        Test.stopTest();

        Assert.areEqual(String.valueOf(acct.Id), result.accountId, 'The entry Account is used as-is');
        Assert.areEqual(String.valueOf(opp.Id), result.opportunityId, 'A single open Opportunity is linked automatically');
    }

    @isTest
    static void shouldNotPickAnyOpportunity_WhenAccountHasSeveralOpenOpps() {
        Account acct = account('Borny Many Opp Account');

        Test.startTest();
        MeetingNoteContextService.Result result = resolve(acct.Id);
        Test.stopTest();

        Assert.areEqual(String.valueOf(acct.Id), result.accountId, 'Account is still resolved');
        Assert.areEqual(null, result.opportunityId, 'An arbitrary Opportunity must never be chosen');
        Assert.isTrue(result.message.contains('여러 건'), 'The ambiguity should be reported: ' + result.message);
    }

    @isTest
    static void shouldResolveAccountOnly_WhenAccountHasNoOpenOpportunity() {
        Account acct = account('Borny No Opp Account');

        Test.startTest();
        MeetingNoteContextService.Result result = resolve(acct.Id);
        Test.stopTest();

        Assert.areEqual(String.valueOf(acct.Id), result.accountId, 'Account-only meetings are supported');
        Assert.areEqual(null, result.opportunityId, 'No Opportunity exists to link');
        Assert.isTrue(result.message.contains('진행 중인 기회가 없어'), 'Should explain why: ' + result.message);
    }

    // ─── Contact 진입 ─────────────────────────────────────────────────────

    @isTest
    static void shouldResolveContactAndItsAccount_WhenLaunchedFromContact() {
        Contact con = contact('김민수');
        Opportunity opp = opportunity('Sole Opp');

        Test.startTest();
        MeetingNoteContextService.Result result = resolve(con.Id);
        Test.stopTest();

        Assert.areEqual(String.valueOf(con.Id), result.contactId, 'The entry Contact is used as-is');
        Assert.areEqual(String.valueOf(con.AccountId), result.accountId, 'Account comes from Contact.AccountId');
        Assert.areEqual(String.valueOf(opp.Id), result.opportunityId, 'The account has exactly one open Opportunity');
    }

    @isTest
    static void shouldReportMissingAccount_WhenContactHasNoAccount() {
        Contact con = contact('이영희');

        Test.startTest();
        MeetingNoteContextService.Result result = resolve(con.Id);
        Test.stopTest();

        Assert.areEqual(String.valueOf(con.Id), result.contactId, 'Contact is still resolved');
        Assert.areEqual(null, result.accountId, 'No Account can be resolved');
        Assert.isTrue(result.message.contains('고객사가 없습니다'), 'Should explain why: ' + result.message);
    }

    // ─── Event 진입 ───────────────────────────────────────────────────────

    @isTest
    static void shouldUseWhatIdOpportunityAndWhoIdContact_WhenLaunchedFromEvent() {
        Opportunity opp = opportunity('Sole Opp');
        Contact con = contact('김민수');
        Event evt = buildEvent(opp.Id, con.Id);
        insert evt;

        Test.startTest();
        MeetingNoteContextService.Result result = resolve(evt.Id);
        Test.stopTest();

        Assert.areEqual(String.valueOf(evt.Id), result.eventId, 'The Event is recorded');
        Assert.areEqual(String.valueOf(opp.Id), result.opportunityId, 'WhatId Opportunity is used');
        Assert.areEqual(String.valueOf(opp.AccountId), result.accountId, 'Account comes from the Opportunity');
        Assert.areEqual(String.valueOf(con.Id), result.contactId, 'WhoId Contact becomes the meeting contact');
        Assert.areEqual(MEETING_DAY, result.meetingDate, 'Meeting date comes from the Event, not today');
    }

    @isTest
    static void shouldUseWhatIdAccount_WhenEventIsLinkedToAnAccount() {
        Account acct = account('Borny Many Opp Account');
        Event evt = buildEvent(acct.Id, null);
        insert evt;

        Test.startTest();
        MeetingNoteContextService.Result result = resolve(evt.Id);
        Test.stopTest();

        Assert.areEqual(String.valueOf(acct.Id), result.accountId, 'WhatId Account is used');
        Assert.areEqual(null, result.opportunityId, 'Two open opportunities means no automatic link');
    }

    @isTest
    static void shouldNeverTreatWhoIdAsOpportunity_WhenEventHasOnlyAContact() {
        Contact con = contact('김민수');
        Event evt = buildEvent(null, con.Id);
        insert evt;

        Test.startTest();
        MeetingNoteContextService.Result result = resolve(evt.Id);
        Test.stopTest();

        Assert.areEqual(String.valueOf(con.Id), result.contactId, 'WhoId Contact becomes the meeting contact');
        Assert.areEqual(String.valueOf(con.AccountId), result.accountId, 'Account falls back to Contact.AccountId');
        Assert.areNotEqual(String.valueOf(con.Id), result.opportunityId, 'WhoId must never be used as an Opportunity');
        Assert.areEqual(String.valueOf(opportunity('Sole Opp').Id), result.opportunityId,
            'The Opportunity comes from the account, not from WhoId');
    }

    // ─── 사용자가 고른 기회 우선 ──────────────────────────────────────────

    @isTest
    static void shouldPreferSelectedOpportunity_WhenSupplied() {
        Account acct = account('Borny Many Opp Account');
        Opportunity chosen = opportunity('Many Opp B');

        Test.startTest();
        MeetingNoteContextService.Result result = resolve(acct.Id, chosen.Id);
        Test.stopTest();

        Assert.areEqual(String.valueOf(chosen.Id), result.opportunityId, 'The explicitly selected Opportunity wins');
        Assert.areEqual(String.valueOf(acct.Id), result.accountId, 'Account stays the entry Account');
    }

    // ─── 방어적 입력 ──────────────────────────────────────────────────────

    @isTest
    static void shouldReportBadInput_WhenRecordIdIsBlank() {
        MeetingNoteContextService.Request req = new MeetingNoteContextService.Request();
        req.recordId = '   ';

        Test.startTest();
        List<MeetingNoteContextService.Result> results = MeetingNoteContextService.resolveContext(
            new List<MeetingNoteContextService.Request>{ req });
        Test.stopTest();

        Assert.areEqual(1, results.size(), 'One result per request');
        Assert.areEqual(null, results[0].accountId, 'Nothing can be resolved');
        Assert.isTrue(results[0].message.contains('전달되지 않았'), 'Should say the id is missing: ' + results[0].message);
    }

    @isTest
    static void shouldReturnEmptyList_WhenNoRequests() {
        Test.startTest();
        List<MeetingNoteContextService.Result> results =
            MeetingNoteContextService.resolveContext(new List<MeetingNoteContextService.Request>());
        Test.stopTest();

        Assert.areEqual(0, results.size(), 'No requests yields no results');
    }

    @isTest
    static void shouldReportUnsupportedObject_WhenLaunchedFromElsewhere() {
        Product2 product = new Product2(Name = 'Unsupported Entry Point', IsActive = true);
        insert product;

        Test.startTest();
        MeetingNoteContextService.Result result = resolve(product.Id);
        Test.stopTest();

        Assert.areEqual('Product2', result.sourceObject, 'Source object is reported as-is');
        Assert.areEqual(null, result.accountId, 'Nothing is guessed for an unsupported object');
        Assert.isTrue(result.message.contains('자동으로 해석할 수 없습니다'), 'Should explain: ' + result.message);
    }

    @isTest
    static void shouldResolveTheSameValues_WhenCalledFromLwc() {
        Opportunity opp = opportunity('Sole Opp');

        Test.startTest();
        MeetingNoteContextService.ContextView view = MeetingNoteContextService.getContext(opp.Id, null);
        Test.stopTest();

        Assert.areEqual(String.valueOf(opp.Id), view.opportunityId, 'LWC entry point resolves the Opportunity');
        Assert.areEqual(String.valueOf(opp.AccountId), view.accountId, 'LWC entry point resolves the Account');
        Assert.areEqual('Opportunity', view.sourceObject, 'Source object is exposed to the LWC too');
    }

    // ─── 진입점이 달라도 저장 구조는 같아야 한다 ──────────────────────────

    @isTest
    static void shouldProduceTheSameNoteShape_WhateverTheEntryPointIs() {
        Account acct = account('Borny Sole Opp Account');
        Opportunity opp = opportunity('Sole Opp');
        Contact con = contact('김민수');
        Event evt = buildEvent(opp.Id, con.Id);
        insert evt;

        Map<String, Id> entryPoints = new Map<String, Id>{
            'Opportunity' => opp.Id,
            'Account' => acct.Id,
            'Contact' => con.Id,
            'Event' => evt.Id
        };

        Test.startTest();
        List<Meeting_Note__c> notes = new List<Meeting_Note__c>();
        for (String entry : entryPoints.keySet()) {
            MeetingNoteContextService.Result context = resolve(entryPoints.get(entry));
            notes.add(new Meeting_Note__c(
                Raw_Content__c = entry + ' 진입 미팅 메모',
                Account__c = context.accountId,
                Contact__c = context.contactId,
                Opportunity__c = context.opportunityId,
                Event_Id__c = context.eventId,
                Meeting_Date__c = context.meetingDate
            ));
        }
        insert notes;
        Test.stopTest();

        Map<String, Meeting_Note__c> savedByEntry = new Map<String, Meeting_Note__c>();
        for (Meeting_Note__c note : [
            SELECT Raw_Content__c, Sanitized_Content__c, Masked_Count__c,
                   Account__c, Contact__c, Opportunity__c, Event_Id__c, Meeting_Date__c
            FROM Meeting_Note__c
        ]) {
            savedByEntry.put(note.Raw_Content__c.substringBefore(' '), note);
        }

        Assert.areEqual(4, savedByEntry.size(), 'One note per entry point');
        for (String entry : entryPoints.keySet()) {
            Meeting_Note__c note = savedByEntry.get(entry);
            Assert.areEqual(acct.Id, note.Account__c, entry + ' entry must link the same Account');
            Assert.areEqual(opp.Id, note.Opportunity__c, entry + ' entry must link the same Opportunity');
            Assert.isNotNull(note.Meeting_Date__c, entry + ' entry must carry a meeting date');
            Assert.isNotNull(note.Sanitized_Content__c, entry + ' entry must still be masked');
        }

        // 진입점별로만 달라지는 값: Contact 와 Event.
        Assert.areEqual(con.Id, savedByEntry.get('Contact').Contact__c, 'Contact entry links the contact');
        Assert.areEqual(con.Id, savedByEntry.get('Event').Contact__c, 'Event WhoId contact is linked');
        Assert.areEqual(null, savedByEntry.get('Opportunity').Contact__c, 'Opportunity entry has no contact to link');
        Assert.areEqual(String.valueOf(evt.Id), savedByEntry.get('Event').Event_Id__c, 'Only the Event entry stores an event id');
        Assert.areEqual(null, savedByEntry.get('Account').Event_Id__c, 'Account entry stores no event id');
    }
}