/**
 * Batch-boundary tests for DealProgressSummaryBatch.
 *
 * Verifies three contracts:
 *  1. Snapshot integrity — one Deal_Progress_Summary__c per Opportunity, with
 *     every status/structure field matching its source Opportunity.
 *  2. No identifying-text leakage — no Summary field contains the Account.Name
 *     or Opportunity.Name sentinel strings seeded in setup.
 *  3. Sharing boundary — a team lead (no ownership, no Opportunity sharing) can
 *     read the Summary snapshots (OWD ReadWrite) but sees zero of the RM's
 *     Opportunities (OWD Private). This is the whole point: manage progress
 *     without opening the source deals.
 *
 * Object access for the custom Deal_Progress_Summary__c object is provisioned at
 * runtime via a PermissionSet created here (not deployed metadata), mirroring the
 * project's MeetingNoteSharingServiceTest pattern. No TestDataFactory is created
 * or modified (team-frozen); all data is built in @TestSetup.
 */
@isTest
private class DealProgressSummaryBatchTest {
    private static final String STANDARD_USER_PROFILE = 'Standard User';
    private static final String STAGE = '탐색';
    private static final String TEAM_CODE = 'T-100';
    // Sentinel tokens are deliberately unusual so any leak into a Summary field
    // is unambiguous. Neither may ever appear in a snapshot.
    private static final String ACCOUNT_SENTINEL = 'ZZSENTINELACCT';
    private static final String OPP_SENTINEL = 'ZZSENTINELOPP';
    private static final Integer OPP_COUNT = 3;

    @TestSetup
    static void setupTestData() {
        Profile standardProfile = [SELECT Id FROM Profile WHERE Name = :STANDARD_USER_PROFILE LIMIT 1];
        String suffix = String.valueOf(DateTime.now().getTime());

        User rmUser = buildUser('dpsRm', suffix, standardProfile.Id);
        rmUser.Team_Code__c = TEAM_CODE;
        User teamLead = buildUser('dpsLead', suffix, standardProfile.Id);

        // Setup-object DML (User, PermissionSet, assignments) is isolated from the
        // non-setup DML below to avoid MIXED_DML_OPERATION.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new List<User>{ rmUser, teamLead };

            PermissionSet permSet = new PermissionSet(
                Name = 'DealProgressSummaryTestAccess',
                Label = 'Deal Progress Summary Test Access'
            );
            insert permSet;
            insert new ObjectPermissions(
                ParentId = permSet.Id,
                SobjectType = 'Deal_Progress_Summary__c',
                PermissionsRead = true
            );
            insert new PermissionSetAssignment(
                AssigneeId = teamLead.Id,
                PermissionSetId = permSet.Id
            );
        }

        Account acct = new Account(
            Name = ACCOUNT_SENTINEL + ' Corp',
            Industry = '농업, 임업 및 어업',
            Business_Registration_Number__c = suffix.right(10)
        );
        insert acct;

        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < OPP_COUNT; i++) {
            opps.add(new Opportunity(
                Name = OPP_SENTINEL + ' ' + i,
                StageName = STAGE,
                CloseDate = Date.today().addDays(30),
                AccountId = acct.Id,
                OwnerId = rmUser.Id
            ));
        }
        insert opps;
    }

    private static User buildUser(String alias, String suffix, Id profileId) {
        String local = alias + suffix;
        return new User(
            FirstName = 'Test',
            LastName = alias,
            Alias = alias.left(8),
            Email = local + '@test.example.com',
            Username = local + '@test.example.com.dpsbatch',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            TimeZoneSidKey = 'America/Los_Angeles',
            ProfileId = profileId
        );
    }

    private static User getUser(String lastName) {
        return [SELECT Id FROM User WHERE LastName = :lastName AND Username LIKE '%.dpsbatch' LIMIT 1];
    }

    private static String expectedReportingPeriod() {
        Date today = Date.today();
        String month = today.month() < 10 ? '0' + today.month() : String.valueOf(today.month());
        return String.valueOf(today.year()) + '-' + month;
    }

    @isTest
    static void shouldSnapshotEveryOpportunity_WhenBatchRuns() {
        // Given the seeded Opportunities and their source values
        Map<Id, Opportunity> oppsById = new Map<Id, Opportunity>([
            SELECT Id, OwnerId, StageName, IsClosed, IsWon, LastStageChangeDate, Owner.Team_Code__c
            FROM Opportunity
        ]);
        Assert.areEqual(OPP_COUNT, oppsById.size(), 'Setup should seed the expected Opportunity count');

        // When the batch runs (size >= record count so a single execute() covers all)
        Test.startTest();
        Database.executeBatch(new DealProgressSummaryBatch(), 200);
        Test.stopTest();

        // Then one snapshot exists per Opportunity with matching status fields.
        // Read in SYSTEM_MODE: the batch writes RM__c in system context and this
        // assertion verifies the written content, not the running user's FLS
        // (RM__c has no profile-level field permission in this org).
        List<Deal_Progress_Summary__c> summaries = [
            SELECT Source_Opportunity_Key__c, RM__c, Stage__c, Is_Closed__c, Is_Won__c,
                   Reporting_Period__c, Stage_Changed_At__c, Team_Code__c, Last_Synced_At__c
            FROM Deal_Progress_Summary__c
            WITH SYSTEM_MODE
        ];
        Assert.areEqual(OPP_COUNT, summaries.size(), 'One snapshot should exist per Opportunity');

        String expectedPeriod = expectedReportingPeriod();
        for (Deal_Progress_Summary__c summary : summaries) {
            Opportunity source = oppsById.get((Id) summary.Source_Opportunity_Key__c);
            Assert.isNotNull(source, 'Every snapshot key must map back to a source Opportunity');
            Assert.areEqual(source.OwnerId, summary.RM__c, 'RM__c must reference the Opportunity owner');
            Assert.areEqual(source.StageName, summary.Stage__c, 'Stage__c must match the source stage');
            Assert.areEqual(source.IsClosed, summary.Is_Closed__c, 'Is_Closed__c must match the source');
            Assert.areEqual(source.IsWon, summary.Is_Won__c, 'Is_Won__c must match the source');
            Assert.areEqual(source.LastStageChangeDate, summary.Stage_Changed_At__c, 'Stage_Changed_At__c must match LastStageChangeDate');
            Assert.areEqual(TEAM_CODE, summary.Team_Code__c, 'Team_Code__c must come from the owner User');
            Assert.areEqual(expectedPeriod, summary.Reporting_Period__c, 'Reporting_Period__c must be the current YYYY-MM');
            Assert.isNotNull(summary.Last_Synced_At__c, 'Last_Synced_At__c must be stamped');
        }
    }

    @isTest
    static void shouldNotCopyIdentifyingText_WhenBatchRuns() {
        // When the batch runs
        Test.startTest();
        Database.executeBatch(new DealProgressSummaryBatch(), 200);
        Test.stopTest();

        // Then no Summary text field carries the Account.Name / Opportunity.Name sentinels
        List<Deal_Progress_Summary__c> summaries = [
            SELECT Source_Opportunity_Key__c, Stage__c, Reporting_Period__c, Team_Code__c
            FROM Deal_Progress_Summary__c
        ];
        Assert.areEqual(OPP_COUNT, summaries.size(), 'Batch should have produced snapshots to inspect');

        for (Deal_Progress_Summary__c summary : summaries) {
            List<String> textValues = new List<String>{
                summary.Source_Opportunity_Key__c,
                summary.Stage__c,
                summary.Reporting_Period__c,
                summary.Team_Code__c
            };
            for (String value : textValues) {
                if (value == null) {
                    continue;
                }
                Assert.isFalse(value.contains(ACCOUNT_SENTINEL),
                    'Summary field must not contain Account name text: ' + value);
                Assert.isFalse(value.contains(OPP_SENTINEL),
                    'Summary field must not contain Opportunity name text: ' + value);
            }
        }
    }

    @isTest
    static void shouldExposeSummaryButNotOpportunity_WhenTeamLead() {
        // Given snapshots produced by the batch
        Test.startTest();
        Database.executeBatch(new DealProgressSummaryBatch(), 200);
        Test.stopTest();

        User teamLead = getUser('dpsLead');

        // When the team lead (no ownership, no Opportunity sharing) reads both objects
        List<Deal_Progress_Summary__c> visibleSummaries;
        List<Opportunity> visibleOpps;
        System.runAs(teamLead) {
            visibleSummaries = [SELECT Id FROM Deal_Progress_Summary__c];
            visibleOpps = [SELECT Id FROM Opportunity];
        }

        // Then the summaries are visible (OWD ReadWrite) but the source deals are not (OWD Private)
        Assert.areEqual(OPP_COUNT, visibleSummaries.size(),
            'Team lead should read every deal-progress snapshot');
        Assert.areEqual(0, visibleOpps.size(),
            'Team lead must not see the RM-owned Opportunities');
    }
}