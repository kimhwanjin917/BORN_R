/**
 * Tests Apex Managed Sharing granted by MeetingNoteSharingService.
 *
 * Meeting_Note__c is OWD Private with an Opportunity__c lookup that does not
 * cascade sharing. The service grants Meeting_Note__Share (Edit, rowCause
 * `for_Manager__c`) to the related Opportunity's owner. These tests verify,
 * via System.runAs, that only the Opportunity owner gains visibility.
 *
 * Object access for the custom Meeting_Note__c object is provisioned at test
 * runtime through a PermissionSet created here (not deployed metadata), so the
 * running users have object-level Read but no record-level sharing except what
 * the service grants.
 */
@isTest
private class MeetingNoteSharingServiceTest {
    private static final String STANDARD_USER_PROFILE = 'Standard User';

    @TestSetup
    static void setupTestData() {
        Profile standardProfile = [SELECT Id FROM Profile WHERE Name = :STANDARD_USER_PROFILE LIMIT 1];
        String uniqueSuffix = String.valueOf(DateTime.now().getTime());

        User oppOwnerRm = buildUser('mtgOwner', uniqueSuffix, standardProfile.Id);
        User otherRm = buildUser('mtgOther', uniqueSuffix, standardProfile.Id);
        User teamLead = buildUser('mtgLead', uniqueSuffix, standardProfile.Id);

        // Setup-object DML (User, PermissionSet, assignments) must be isolated
        // from the non-setup DML below to avoid MIXED_DML_OPERATION.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new List<User>{ oppOwnerRm, otherRm, teamLead };

            PermissionSet permSet = new PermissionSet(
                Name = 'MtgNoteTestAccess',
                Label = 'Mtg Note Test Access'
            );
            insert permSet;
            insert new ObjectPermissions(
                ParentId = permSet.Id,
                SobjectType = 'Meeting_Note__c',
                PermissionsRead = true
            );
            insert new List<PermissionSetAssignment>{
                new PermissionSetAssignment(AssigneeId = oppOwnerRm.Id, PermissionSetId = permSet.Id),
                new PermissionSetAssignment(AssigneeId = otherRm.Id, PermissionSetId = permSet.Id),
                new PermissionSetAssignment(AssigneeId = teamLead.Id, PermissionSetId = permSet.Id)
            };
        }

        Opportunity opp = new Opportunity(
            Name = 'Mtg Note Test Opp',
            StageName = '미팅',
            CloseDate = Date.today().addDays(30),
            OwnerId = oppOwnerRm.Id
        );
        insert opp;

        Meeting_Note__c note = new Meeting_Note__c(Opportunity__c = opp.Id);
        insert note;

        // Simulates the after-insert trigger wiring (handler not yet in place).
        MeetingNoteSharingService.grantSharesForInsert(new List<Meeting_Note__c>{ note });
    }

    private static User buildUser(String alias, String suffix, Id profileId) {
        String local = alias + suffix;
        return new User(
            FirstName = 'Test',
            LastName = alias,
            Alias = alias.left(8),
            Email = local + '@test.example.com',
            Username = local + '@test.example.com.mtgnote',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            TimeZoneSidKey = 'America/Los_Angeles',
            ProfileId = profileId
        );
    }

    private static User getUser(String lastName) {
        return [SELECT Id FROM User WHERE LastName = :lastName AND Username LIKE '%.mtgnote' LIMIT 1];
    }

    @isTest
    static void shouldSeeNote_WhenOpportunityOwnerRm() {
        User oppOwnerRm = getUser('mtgOwner');

        List<Meeting_Note__c> visible;
        System.runAs(oppOwnerRm) {
            visible = [SELECT Id FROM Meeting_Note__c];
        }

        Assert.areEqual(1, visible.size(), 'Opportunity owner RM should see the shared Meeting Note');
    }

    @isTest
    static void shouldSeeZero_WhenOtherRm() {
        User otherRm = getUser('mtgOther');

        List<Meeting_Note__c> visible;
        System.runAs(otherRm) {
            visible = [SELECT Id FROM Meeting_Note__c];
        }

        Assert.areEqual(0, visible.size(), 'A non-owner RM must not see the Meeting Note');
    }

    @isTest
    static void shouldSeeZero_WhenTeamLead() {
        User teamLead = getUser('mtgLead');

        List<Meeting_Note__c> visible;
        System.runAs(teamLead) {
            visible = [SELECT Id FROM Meeting_Note__c];
        }

        Assert.areEqual(0, visible.size(), 'A team lead without explicit sharing must not see the Meeting Note');
    }

    @isTest
    static void shouldReshare_WhenOpportunityOwnerChanges() {
        // Given a note already shared to the first Opportunity owner
        Meeting_Note__c note = [SELECT Id, OwnerId, Opportunity__c FROM Meeting_Note__c LIMIT 1];
        User newOwnerRm = getUser('mtgOther');

        Opportunity newOpp = new Opportunity(
            Name = 'Reassigned Opp',
            StageName = '미팅',
            CloseDate = Date.today().addDays(30),
            OwnerId = newOwnerRm.Id
        );
        insert newOpp;

        Meeting_Note__c oldState = note.clone(true, true, false, false);
        note.Opportunity__c = newOpp.Id;
        update note;

        // When the lookup changes to an Opportunity owned by the other RM
        Test.startTest();
        MeetingNoteSharingService.recalculateShares(
            new List<Meeting_Note__c>{ note },
            new Map<Id, Meeting_Note__c>{ note.Id => oldState }
        );
        Test.stopTest();

        // Then the new owner sees it and the original owner no longer does
        List<Meeting_Note__c> newOwnerView;
        System.runAs(newOwnerRm) {
            newOwnerView = [SELECT Id FROM Meeting_Note__c];
        }
        Assert.areEqual(1, newOwnerView.size(), 'New Opportunity owner should see the Meeting Note after re-share');

        User originalOwnerRm = getUser('mtgOwner');
        List<Meeting_Note__c> originalOwnerView;
        System.runAs(originalOwnerRm) {
            originalOwnerView = [SELECT Id FROM Meeting_Note__c];
        }
        Assert.areEqual(0, originalOwnerView.size(), 'Previous Opportunity owner should lose access after re-share');
    }

    @isTest
    static void shouldNotShare_WhenNoOpportunity() {
        Meeting_Note__c note = new Meeting_Note__c();
        insert note;

        Test.startTest();
        MeetingNoteSharingService.grantSharesForInsert(new List<Meeting_Note__c>{ note });
        Test.stopTest();

        List<Meeting_Note__Share> shares = [
            SELECT Id FROM Meeting_Note__Share
            WHERE ParentId = :note.Id AND RowCause = :Schema.Meeting_Note__Share.RowCause.for_Manager__c
        ];
        Assert.areEqual(0, shares.size(), 'No managed share should exist for a note without an Opportunity');
    }
}