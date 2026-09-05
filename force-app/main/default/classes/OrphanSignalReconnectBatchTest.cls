/**
 * Test class for OrphanSignalReconnectBatch.
 *
 * Builds a converted Lead (with its Account) and attaches orphaned
 * ExternalSignal__c / CorporateFinancialStatement__c rows (Account__c null),
 * then runs the batch and verifies both are re-pointed to the converted Account.
 * Data is created in @TestSetup here — TestDataFactory is a frozen shared file.
 *
 * The batch runs WITH USER_MODE, so the assertions run as a dedicated user
 * carrying a permission set that grants FLS on the fields the batch reads/writes.
 */
@isTest
private class OrphanSignalReconnectBatchTest {

    private static final String TEST_USER_NAME = 'osr.tester@orphanreconnect.test.example.com';

    @TestSetup
    static void setupTestData() {
        User testUser = createTestUser();
        assignFlsPermissionSet(testUser.Id);

        // Data DML isolated from the setup-object DML above (MIXED_DML_OPERATION).
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Lead lead = new Lead(
                LastName = 'Kim',
                FirstName = 'Test',
                Company = 'Acme Corp',
                Status = 'Open - Not Contacted',
                Industry = 'Insurance',
                Email = 'lead.osr@orphanreconnect.test.example.com',
                name_new__c = '김담당'
            );
            insert lead;

            // Convert it so the parent Lead is IsConverted = true with an Account.
            Database.LeadConvert lc = new Database.LeadConvert();
            lc.setLeadId(lead.Id);
            lc.setConvertedStatus(getConvertedStatus());
            Database.LeadConvertResult result = Database.convertLead(lc, false);
            Assert.isTrue(result.isSuccess(), 'Test Lead should convert');

            // Orphans: attached AFTER conversion, so Account__c is null and the
            // conversion trigger never reconnected them — exactly what the batch
            // exists to sweep.
            insert new CorporateFinancialStatement__c(Lead__c = lead.Id);
            insert new ExternalSignal__c(Lead__c = lead.Id);
        }
    }

    private static User createTestUser() {
        Profile admin = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        User u = new User(
            FirstName = 'OSR',
            LastName = 'Tester',
            Email = 'osr.tester@orphanreconnect.test.example.com',
            Username = TEST_USER_NAME,
            Alias = 'osrtest',
            ProfileId = admin.Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        insert u;
        return u;
    }

    private static void assignFlsPermissionSet(Id userId) {
        PermissionSet ps = new PermissionSet(Name = 'OSR_Test_Fls', Label = 'OSR Test FLS');
        insert ps;

        insert new List<ObjectPermissions>{
            newObjectPerm(ps.Id, 'CorporateFinancialStatement__c'),
            newObjectPerm(ps.Id, 'ExternalSignal__c')
        };

        insert new List<FieldPermissions>{
            newFieldPerm(ps.Id, 'CorporateFinancialStatement__c', 'CorporateFinancialStatement__c.Lead__c', false),
            newFieldPerm(ps.Id, 'CorporateFinancialStatement__c', 'CorporateFinancialStatement__c.Account__c', true),
            newFieldPerm(ps.Id, 'ExternalSignal__c', 'ExternalSignal__c.Lead__c', false),
            newFieldPerm(ps.Id, 'ExternalSignal__c', 'ExternalSignal__c.Account__c', true)
        };

        insert new PermissionSetAssignment(AssigneeId = userId, PermissionSetId = ps.Id);
    }

    private static ObjectPermissions newObjectPerm(Id parentId, String sobjectType) {
        return new ObjectPermissions(
            ParentId = parentId,
            SobjectType = sobjectType,
            PermissionsRead = true,
            PermissionsViewAllRecords = true,
            PermissionsEdit = true
        );
    }

    private static FieldPermissions newFieldPerm(Id parentId, String sobjectType, String field, Boolean allowEdit) {
        return new FieldPermissions(
            ParentId = parentId,
            SobjectType = sobjectType,
            Field = field,
            PermissionsRead = true,
            PermissionsEdit = allowEdit
        );
    }

    private static String getConvertedStatus() {
        LeadStatus status = [
            SELECT ApiName FROM LeadStatus WHERE IsConverted = true
            ORDER BY IsDefault DESC LIMIT 1
        ];
        return status.ApiName;
    }

    private static User getTestUser() {
        return [SELECT Id FROM User WHERE Username = :TEST_USER_NAME LIMIT 1];
    }

    // ─── Tests ────────────────────────────────────────────────────────────

    @isTest
    static void shouldReconnectBothObjectsToConvertedAccount() {
        Lead lead = [SELECT Id, ConvertedAccountId FROM Lead LIMIT 1];

        Test.startTest();
        System.runAs(getTestUser()) {
            // start() sweeps ExternalSignal__c; finish() chains the statement run.
            Database.executeBatch(new OrphanSignalReconnectBatch(), 200);
        }
        Test.stopTest();

        ExternalSignal__c signal = [SELECT Account__c FROM ExternalSignal__c LIMIT 1];
        Assert.areEqual(lead.ConvertedAccountId, signal.Account__c,
            'ExternalSignal__c should be re-pointed to the converted Account');

        CorporateFinancialStatement__c statement =
            [SELECT Account__c FROM CorporateFinancialStatement__c LIMIT 1];
        Assert.areEqual(lead.ConvertedAccountId, statement.Account__c,
            'CorporateFinancialStatement__c should be re-pointed to the converted Account');
    }

    @isTest
    static void shouldScheduleWithoutError() {
        Test.startTest();
        System.runAs(getTestUser()) {
            String cron = '0 0 1 * * ?';
            System.schedule('OSR Reconnect Test', cron, new OrphanSignalReconnectBatch());
        }
        Test.stopTest();

        CronTrigger ct = [
            SELECT CronExpression FROM CronTrigger
            WHERE CronJobDetail.Name = 'OSR Reconnect Test' LIMIT 1
        ];
        Assert.areEqual('0 0 1 * * ?', ct.CronExpression, 'Schedule should register the batch');
    }
}