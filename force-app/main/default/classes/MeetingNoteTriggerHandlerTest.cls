/**
 * Tests for MeetingNoteTriggerHandler at the DML boundary: inserting a
 * Meeting_Note__c must populate Sanitized_Content__c and Masked_Count__c from
 * MaskingService while leaving Raw_Content__c unchanged.
 *
 * Regex internals are NOT re-tested here (MaskingServiceTest owns that). These
 * tests only assert the trigger wired masking in and preserved the original.
 *
 * The masking tests leave Opportunity__c null so MeetingNoteSharingService is a
 * no-op and stays out of the way. The relationship-backfill tests below do use
 * real parents, because that is exactly what they are about. Contact names are
 * stored fully in LastName so Contact.Name is deterministic regardless of org
 * locale.
 */
@isTest
private class MeetingNoteTriggerHandlerTest {
    @TestSetup
    static void setupTestData() {
        // Observed in this org: inserting a Contact fails with
        //   FIELD_CUSTOM_VALIDATION_EXCEPTION, 담당자 이메일을 입력해 주세요.: [Email]
        //   REQUIRED_FIELD_MISSING, Required fields are missing: [LastName, name_new__c]
        // so Department, Email, LastName and name_new__c must all be supplied. Why
        // LastName is reported missing when it is set has not been established.
        // This mirrors MaskingServiceTest's setup, which passes.
        Database.insert(new List<Contact>{
            new Contact(LastName = '김철수', name_new__c = '김철수',
                Department = 'Sales', Email = 't1@test.example'),
            new Contact(LastName = '이영희', name_new__c = '이영희',
                Department = 'Sales', Email = 't2@test.example')
        }, AccessLevel.SYSTEM_MODE);

        // Parents for the relationship-backfill tests. Account requires Industry
        // (Required_PL validation rule) and Business_Registration_Number__c.
        // The name deliberately shares no substring with any masking input above.
        Account acct = new Account(
            Name = 'Borny Backfill Account',
            Industry = 'Banking',
            Business_Registration_Number__c = '3000000001'
        );
        insert acct;

        insert new Opportunity(
            Name = 'Borny Backfill Opportunity',
            AccountId = acct.Id,
            StageName = 'Prospecting',
            CloseDate = Date.newInstance(2026, 12, 31)
        );

        // name_new__c is Text(10), so this name is kept short. It is deliberately
        // not Korean: MaskingService masks Korean Contact names it finds in the org,
        // and the masking tests above assert exact output.
        Database.insert(new Contact(
            LastName = 'Backfill',
            name_new__c = 'Backfill',
            AccountId = acct.Id,
            Department = 'Sales',
            Email = 't3@test.example'
        ), AccessLevel.SYSTEM_MODE);
    }

    private static Account backfillAccount() {
        return [SELECT Id FROM Account WHERE Name = 'Borny Backfill Account' LIMIT 1];
    }
    private static Opportunity backfillOpportunity() {
        return [SELECT Id, AccountId FROM Opportunity WHERE Name = 'Borny Backfill Opportunity' LIMIT 1];
    }
    private static Contact backfillContact() {
        return [SELECT Id, AccountId FROM Contact WHERE LastName = 'Backfill' LIMIT 1];
    }

    @isTest
    static void shouldMaskPhone_WhenNoteInserted() {
        Meeting_Note__c note = new Meeting_Note__c(Raw_Content__c = '연락처 010-1234-5678');

        Test.startTest();
        insert note;
        Test.stopTest();

        Meeting_Note__c saved = query(note.Id);
        Assert.areEqual('연락처 010-****-****', saved.Sanitized_Content__c, 'Phone should be masked in sanitized content');
        Assert.areEqual(1, saved.Masked_Count__c, 'One value should be masked');
        Assert.areEqual('연락처 010-1234-5678', saved.Raw_Content__c, 'Raw content must be preserved unchanged');
    }

    @isTest
    static void shouldMaskEmail_WhenNoteInserted() {
        Meeting_Note__c note = new Meeting_Note__c(Raw_Content__c = '메일 hong.gildong@example.com');

        Test.startTest();
        insert note;
        Test.stopTest();

        Meeting_Note__c saved = query(note.Id);
        Assert.areEqual('메일 ho***@example.com', saved.Sanitized_Content__c, 'Email should be masked');
        Assert.areEqual(1, saved.Masked_Count__c, 'One value should be masked');
        Assert.areEqual('메일 hong.gildong@example.com', saved.Raw_Content__c, 'Raw content must be preserved');
    }

    @isTest
    static void shouldMaskAccount_WhenNoteInserted() {
        Meeting_Note__c note = new Meeting_Note__c(Raw_Content__c = '계좌 123-45-678901');

        Test.startTest();
        insert note;
        Test.stopTest();

        Meeting_Note__c saved = query(note.Id);
        Assert.areEqual('계좌 ***-**-******', saved.Sanitized_Content__c, 'Account number should be masked');
        Assert.areEqual(1, saved.Masked_Count__c, 'One value should be masked');
        Assert.areEqual('계좌 123-45-678901', saved.Raw_Content__c, 'Raw content must be preserved');
    }

    @isTest
    static void shouldMaskContactName_WhenNoteInserted() {
        Meeting_Note__c note = new Meeting_Note__c(Raw_Content__c = '고객 김철수 님');

        Test.startTest();
        insert note;
        Test.stopTest();

        Meeting_Note__c saved = query(note.Id);
        Assert.areEqual('고객 김** 님', saved.Sanitized_Content__c, 'Contact name should be masked to surname + **');
        Assert.areEqual(1, saved.Masked_Count__c, 'One value should be masked');
        Assert.areEqual('고객 김철수 님', saved.Raw_Content__c, 'Raw content must be preserved');
    }

    @isTest
    static void shouldMaskAllTypes_WhenMixedContentInserted() {
        Meeting_Note__c note = new Meeting_Note__c(
            Raw_Content__c = '고객 김철수, 전화 010-1234-5678, 계좌 123-45-678901, 메일 test@abc.com'
        );

        Test.startTest();
        insert note;
        Test.stopTest();

        Meeting_Note__c saved = query(note.Id);
        Assert.areEqual(
            '고객 김**, 전화 010-****-****, 계좌 ***-**-******, 메일 te***@abc.com',
            saved.Sanitized_Content__c,
            'All PII types should be masked'
        );
        Assert.areEqual(4, saved.Masked_Count__c, 'Four values should be masked');
    }

    @isTest
    static void shouldMaskZero_WhenNoPiiInserted() {
        Meeting_Note__c note = new Meeting_Note__c(Raw_Content__c = '오늘 회의는 순조로웠습니다');

        Test.startTest();
        insert note;
        Test.stopTest();

        Meeting_Note__c saved = query(note.Id);
        Assert.areEqual('오늘 회의는 순조로웠습니다', saved.Sanitized_Content__c, 'Content without PII is unchanged');
        Assert.areEqual(0, saved.Masked_Count__c, 'Nothing should be masked');
    }

    @isTest
    static void shouldSetZeroCount_WhenRawContentBlank() {
        Meeting_Note__c note = new Meeting_Note__c(Raw_Content__c = null);

        Test.startTest();
        insert note;
        Test.stopTest();

        Meeting_Note__c saved = query(note.Id);
        Assert.areEqual(0, saved.Masked_Count__c, 'Blank raw content masks nothing');
        Assert.areEqual(null, saved.Sanitized_Content__c, 'Blank raw content yields blank sanitized content');
    }

    @isTest
    static void shouldRemask_WhenRawContentUpdated() {
        Meeting_Note__c note = new Meeting_Note__c(Raw_Content__c = '회의 준비 중');
        insert note;

        note.Raw_Content__c = '전화 010-1234-5678';

        Test.startTest();
        update note;
        Test.stopTest();

        Meeting_Note__c saved = query(note.Id);
        Assert.areEqual('전화 010-****-****', saved.Sanitized_Content__c, 'Update should re-mask the new raw content');
        Assert.areEqual(1, saved.Masked_Count__c, 'One value should be masked after update');
        Assert.areEqual('전화 010-1234-5678', saved.Raw_Content__c, 'Raw content must be preserved on update');
    }

    // ─── 관계 보정 (backfillRelationships) ────────────────────────────────

    @isTest
    static void shouldBackfillAccountFromOpportunity_WhenAccountLeftBlank() {
        Opportunity opp = backfillOpportunity();
        Meeting_Note__c note = new Meeting_Note__c(
            Raw_Content__c = '기회에서 시작한 미팅',
            Opportunity__c = opp.Id
        );

        Test.startTest();
        insert note;
        Test.stopTest();

        Meeting_Note__c saved = queryRelationships(note.Id);
        Assert.areEqual(opp.AccountId, saved.Account__c, 'Account should be derived from the Opportunity');
        Assert.areEqual(Date.today(), saved.Meeting_Date__c, 'Meeting date should default to today');
    }

    @isTest
    static void shouldBackfillAccountFromContact_WhenThereIsNoOpportunity() {
        Contact con = backfillContact();
        Meeting_Note__c note = new Meeting_Note__c(
            Raw_Content__c = '담당자와의 미팅',
            Contact__c = con.Id
        );

        Test.startTest();
        insert note;
        Test.stopTest();

        Meeting_Note__c saved = queryRelationships(note.Id);
        Assert.areEqual(con.AccountId, saved.Account__c, 'Account should be derived from the Contact');
        Assert.areEqual(null, saved.Opportunity__c, 'No Opportunity should be invented');
    }

    @isTest
    static void shouldKeepSuppliedValues_WhenCallerAlreadyResolvedThem() {
        Account acct = backfillAccount();
        Date suppliedDate = Date.newInstance(2026, 7, 30);
        Meeting_Note__c note = new Meeting_Note__c(
            Raw_Content__c = '이미 해석된 컨텍스트',
            Account__c = acct.Id,
            Meeting_Date__c = suppliedDate
        );

        Test.startTest();
        insert note;
        Test.stopTest();

        Meeting_Note__c saved = queryRelationships(note.Id);
        Assert.areEqual(acct.Id, saved.Account__c, 'A supplied Account must not be overwritten');
        Assert.areEqual(suppliedDate, saved.Meeting_Date__c, 'A supplied meeting date must not be overwritten');
    }

    @isTest
    static void shouldAccumulateNotes_WhenSameAccountMeetsRepeatedly() {
        Account acct = backfillAccount();
        List<Meeting_Note__c> notes = new List<Meeting_Note__c>{
            new Meeting_Note__c(Raw_Content__c = '1차 미팅', Account__c = acct.Id,
                Meeting_Date__c = Date.newInstance(2026, 7, 30)),
            new Meeting_Note__c(Raw_Content__c = '2차 미팅', Account__c = acct.Id,
                Meeting_Date__c = Date.newInstance(2026, 8, 14)),
            new Meeting_Note__c(Raw_Content__c = '3차 미팅', Account__c = acct.Id,
                Meeting_Date__c = Date.newInstance(2026, 8, 28))
        };

        Test.startTest();
        insert notes;
        Test.stopTest();

        List<Meeting_Note__c> saved = [
            SELECT Id, Raw_Content__c, Meeting_Date__c
            FROM Meeting_Note__c
            WHERE Account__c = :acct.Id
            ORDER BY Meeting_Date__c DESC
        ];
        Assert.areEqual(3, saved.size(), 'Every meeting is its own record; none is overwritten');
        Assert.areEqual('3차 미팅', saved[0].Raw_Content__c, 'Newest meeting sorts first by meeting date');
        Assert.areEqual('1차 미팅', saved[2].Raw_Content__c, 'Oldest meeting sorts last');
    }

    private static Meeting_Note__c queryRelationships(Id noteId) {
        return [
            SELECT Account__c, Contact__c, Opportunity__c, Event_Id__c, Meeting_Date__c
            FROM Meeting_Note__c
            WHERE Id = :noteId
        ];
    }

    private static Meeting_Note__c query(Id noteId) {
        return [
            SELECT Raw_Content__c, Sanitized_Content__c, Masked_Count__c
            FROM Meeting_Note__c
            WHERE Id = :noteId
        ];
    }
}