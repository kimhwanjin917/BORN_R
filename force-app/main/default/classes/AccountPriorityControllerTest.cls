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
    static void excludesAccountsOwnedByOtherUsers() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User otherUser = new User(
            FirstName = 'Other',
            LastName = 'Owner',
            Email = 'other.owner@example.com.invalid',
            Username = 'other.owner.' + String.valueOf(DateTime.now().getTime()) + '@example.com.invalid',
            Alias = 'oown',
            TimeZoneSidKey = 'Asia/Seoul',
            LocaleSidKey = 'ko_KR',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            ProfileId = p.Id
        );
        insert otherUser;

        Account foreignAcct = new Account(
            Name = 'Foreign Owner Acct',
            Priority_Score__c = 999,
            Business_Registration_Number__c = String.valueOf(1000000099),
            OwnerId = otherUser.Id
        );
        insert foreignAcct;

        Test.startTest();
        List<Account> result = AccountPriorityController.getTopAccounts(10);
        Test.stopTest();

        for (Account acct : result) {
            System.assertNotEquals(
                foreignAcct.Id,
                acct.Id,
                'Accounts owned by other users must be excluded'
            );
        }
        System.assertEquals(5, result.size(), 'Only the running user\'s scored accounts should be returned');
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