public with sharing class LeadPriorityController {
    @AuraEnabled(cacheable=true)
    public static List<Lead> getTopLeads(Integer maxRows) {
        Integer rowLimit = (maxRows == null || maxRows <= 0) ? 10 : maxRows;
        return [
            SELECT Id, Company, Priority_Score__c, Priority_Rationale_Summary__c
            FROM Lead
            WHERE IsConverted = false AND Status = '신규' AND Priority_Score__c != null
            WITH USER_MODE
            ORDER BY Priority_Score__c DESC, Name ASC
            LIMIT :rowLimit
        ];
    }
}