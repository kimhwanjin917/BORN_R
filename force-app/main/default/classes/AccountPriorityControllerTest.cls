@isTest
private class AccountPriorityControllerTest {
    @TestSetup
    static void setup() {
        List<Account> accts = new List<Account>();
        for (Integer i = 0; i < 5; i++) {
            accts.add(new Account(
                Name = 'Priority Acct ' + i,
                Priority_Score__c = i * 10,
                Business_Registration_Number__c = String.valueOf(1000000000 + i)
            ));
        }
        accts.add(new Account(
            Name = 'No Score Acct',
            Business_Registration_Number__c = String.valueOf(1000000005)
        ));
        insert accts;
    }

    @isTest
    static void returnsAccountsOrderedByScoreDesc() {
        Test.startTest();
        List<Account> result = AccountPriorityController.getTopAccounts(10);
        Test.stopTest();

        System.assertEquals(5, result.size(), 'Accounts without a score must be excluded');
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
        List<Account> result = AccountPriorityController.getTopAccounts(2);
        Test.stopTest();

        System.assertEquals(2, result.size(), 'Row limit must be honored');
    }

    @isTest
    static void defaultsLimitWhenNullOrNonPositive() {
        Test.startTest();
        List<Account> nullResult = AccountPriorityController.getTopAccounts(null);
        List<Account> zeroResult = AccountPriorityController.getTopAccounts(0);
        Test.stopTest();

        System.assertEquals(5, nullResult.size(), 'Null max should fall back to default limit');
        System.assertEquals(5, zeroResult.size(), 'Non-positive max should fall back to default limit');
    }
}