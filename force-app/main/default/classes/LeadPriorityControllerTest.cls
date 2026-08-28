@isTest
private class LeadPriorityControllerTest {
    @TestSetup
    static void setup() {
        List<Lead> leads = new List<Lead>();
        for (Integer i = 0; i < 5; i++) {
            leads.add(new Lead(
                LastName = 'Priority Lead ' + i,
                name_new__c = 'PL' + i,
                Company = 'Priority Co ' + i,
                Status = '신규',
                Email = 'priority' + i + '@example.com',
                Priority_Score__c = i * 10,
                Priority_Rationale_Summary__c = 'Reason ' + i
            ));
        }
        leads.add(new Lead(
            LastName = 'No Score Lead',
            name_new__c = 'NoScore',
            Company = 'No Score Co',
            Status = '신규',
            Email = 'noscore@example.com'
        ));
        insert leads;
    }

    @isTest
    static void returnsLeadsOrderedByScoreDesc() {
        Test.startTest();
        List<Lead> result = LeadPriorityController.getTopLeads(10);
        Test.stopTest();

        System.assertEquals(5, result.size(), 'Leads without a score must be excluded');
        for (Integer i = 0; i < result.size() - 1; i++) {
            System.assert(
                result[i].Priority_Score__c >= result[i + 1].Priority_Score__c,
                'Results must be sorted by Priority_Score__c descending'
            );
        }
    }

    @isTest
    static void respectsRowLimit() {
        Test.startTest();
        List<Lead> result = LeadPriorityController.getTopLeads(2);
        Test.stopTest();

        System.assertEquals(2, result.size(), 'Row limit must be honored');
    }

    @isTest
    static void defaultsLimitWhenNullOrNonPositive() {
        Test.startTest();
        List<Lead> nullResult = LeadPriorityController.getTopLeads(null);
        List<Lead> zeroResult = LeadPriorityController.getTopLeads(0);
        Test.stopTest();

        System.assertEquals(5, nullResult.size(), 'Null max should fall back to default limit');
        System.assertEquals(5, zeroResult.size(), 'Non-positive max should fall back to default limit');
    }
}