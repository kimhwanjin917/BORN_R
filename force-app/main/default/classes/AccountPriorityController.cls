public with sharing class AccountPriorityController {
    @AuraEnabled(cacheable=true)
    public static List<Account> getTopAccounts(Integer maxRows) {
        Integer rowLimit = (maxRows == null || maxRows <= 0) ? 10 : maxRows;
        return [
            SELECT Id, Name, Priority_Score__c, Priority_Rationale_Summary__c
            FROM Account
            WHERE Priority_Score__c != null
            AND OwnerId = :UserInfo.getUserId()
            WITH USER_MODE
            ORDER BY Priority_Score__c DESC, Name ASC
            LIMIT :rowLimit
        ];
    }
}