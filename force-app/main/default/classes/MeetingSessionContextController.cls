public with sharing class MeetingSessionContextController {
    public class MeetingContext {
        @AuraEnabled public String recordId;
        @AuraEnabled public String objectApiName;
        @AuraEnabled public String objectLabel;
        @AuraEnabled public String recordName;
        @AuraEnabled public String companyName;
        @AuraEnabled public String ownerName;
        @AuraEnabled public String status;
        @AuraEnabled public String briefing;
        @AuraEnabled public String recommendationReason;
        @AuraEnabled public String sanitizedContent;
        @AuraEnabled public Integer maskedCount;
    }

    @AuraEnabled(cacheable=true)
    public static MeetingContext getMeetingContext(Id recordId) {
        MeetingContext result = new MeetingContext();
        result.recordId = String.valueOf(recordId);
        result.maskedCount = 0;
        if (recordId == null) return result;

        Schema.SObjectType objectType = recordId.getSObjectType();
        Schema.DescribeSObjectResult describeResult = objectType.getDescribe();
        String apiName = describeResult.getName();
        result.objectApiName = apiName;
        result.objectLabel = describeResult.getLabel();

        Map<String, Schema.SObjectField> fieldMap = describeResult.fields.getMap();
        List<String> fields = new List<String>{ 'Id' };
        addField(fields, fieldMap, apiName == 'Event' ? 'Subject' : 'Name');
        addField(fields, fieldMap, 'Description');

        if (apiName == 'Opportunity') {
            addField(fields, fieldMap, 'StageName');
            addField(fields, fieldMap, 'Amount');
            addField(fields, fieldMap, 'NextStep');
            fields.add('Account.Name');
            fields.add('Owner.Name');
        } else if (apiName == 'Lead') {
            addField(fields, fieldMap, 'Company');
            addField(fields, fieldMap, 'Status');
            addField(fields, fieldMap, 'Industry');
            addField(fields, fieldMap, 'AnnualRevenue');
            fields.add('Owner.Name');
        } else if (apiName == 'Account') {
            addField(fields, fieldMap, 'Industry');
            addField(fields, fieldMap, 'AnnualRevenue');
            addField(fields, fieldMap, 'Rating');
            fields.add('Owner.Name');
        } else if (apiName == 'Contact') {
            addField(fields, fieldMap, 'Title');
            fields.add('Account.Name');
            fields.add('Owner.Name');
        } else if (apiName == 'Event') {
            addField(fields, fieldMap, 'StartDateTime');
            addField(fields, fieldMap, 'EndDateTime');
            fields.add('What.Name');
            fields.add('Who.Name');
            fields.add('Owner.Name');
        }

        String briefingField = firstExisting(fieldMap, new List<String>{
            'Company_Briefing__c', 'Account_Briefing__c', 'Briefing__c', 'Meeting_Briefing__c'
        });
        String reasonField = firstExisting(fieldMap, new List<String>{
            'RP_Recommendation_Reason__c', 'Recommendation_Reason__c', 'Recommended_Reason__c', 'RP_Reason__c'
        });
        if (briefingField != null) fields.add(briefingField);
        if (reasonField != null) fields.add(reasonField);

        SObject row = Database.query('SELECT ' + String.join(fields, ',') + ' FROM ' + apiName + ' WHERE Id = :recordId LIMIT 1');
        result.recordName = textValue(row, apiName == 'Event' ? 'Subject' : 'Name');
        result.ownerName = relationshipName(row, 'Owner');
        result.companyName = resolveCompany(apiName, row);
        result.status = resolveStatus(apiName, row);

        String storedBriefing = briefingField == null ? null : textValue(row, briefingField);
        String description = textValue(row, 'Description');
        result.briefing = String.isNotBlank(storedBriefing)
            ? storedBriefing
            : buildBriefing(apiName, row, description);

        String storedReason = reasonField == null ? null : textValue(row, reasonField);
        result.recommendationReason = String.isNotBlank(storedReason)
            ? storedReason
            : buildRecommendationReason(apiName, row);

        if (apiName == 'Opportunity') loadLatestMasking(recordId, result);
        return result;
    }

    private static void loadLatestMasking(Id opportunityId, MeetingContext result) {
        Map<String, Schema.SObjectType> globals = Schema.getGlobalDescribe();
        if (!globals.containsKey('Meeting_Note__c')) return;
        Map<String, Schema.SObjectField> noteFields = globals.get('Meeting_Note__c').getDescribe().fields.getMap();
        if (!noteFields.containsKey('Opportunity__c') || !noteFields.containsKey('Sanitized_Content__c')) return;

        String countField = firstExisting(noteFields, new List<String>{ 'Masked_Count__c', 'Masking_Count__c' });
        List<String> selected = new List<String>{ 'Sanitized_Content__c' };
        if (countField != null) selected.add(countField);
        List<SObject> notes = Database.query(
            'SELECT ' + String.join(selected, ',') +
            ' FROM Meeting_Note__c WHERE Opportunity__c = :opportunityId' +
            ' ORDER BY CreatedDate DESC LIMIT 1'
        );
        if (notes.isEmpty()) return;
        result.sanitizedContent = textValue(notes[0], 'Sanitized_Content__c');
        if (countField != null && notes[0].get(countField) != null) {
            result.maskedCount = Integer.valueOf(String.valueOf(notes[0].get(countField)));
        }
    }

    private static String resolveCompany(String apiName, SObject row) {
        if (apiName == 'Opportunity' || apiName == 'Contact') return relationshipName(row, 'Account');
        if (apiName == 'Lead') return textValue(row, 'Company');
        if (apiName == 'Account') return textValue(row, 'Name');
        if (apiName == 'Event') {
            String whatName = relationshipName(row, 'What');
            return String.isNotBlank(whatName) ? whatName : relationshipName(row, 'Who');
        }
        return null;
    }

    private static String resolveStatus(String apiName, SObject row) {
        if (apiName == 'Opportunity') return textValue(row, 'StageName');
        if (apiName == 'Lead') return textValue(row, 'Status');
        if (apiName == 'Account') return textValue(row, 'Rating');
        if (apiName == 'Contact') return textValue(row, 'Title');
        if (apiName == 'Event') return textValue(row, 'StartDateTime');
        return null;
    }

    private static String buildBriefing(String apiName, SObject row, String description) {
        List<String> parts = new List<String>();
        if (apiName == 'Opportunity') {
            addPart(parts, '현재 단계', textValue(row, 'StageName'));
            addPart(parts, '다음 단계', textValue(row, 'NextStep'));
        } else if (apiName == 'Lead' || apiName == 'Account') {
            addPart(parts, '산업', textValue(row, 'Industry'));
        } else if (apiName == 'Contact') {
            addPart(parts, '직책', textValue(row, 'Title'));
        } else if (apiName == 'Event') {
            addPart(parts, '미팅 일정', textValue(row, 'StartDateTime'));
        }
        if (String.isNotBlank(description)) parts.add(description);
        return parts.isEmpty() ? '저장된 기업 브리핑이 없습니다.' : String.join(parts, ' · ');
    }

    private static String buildRecommendationReason(String apiName, SObject row) {
        if (apiName == 'Opportunity') {
            String stage = textValue(row, 'StageName');
            return String.isNotBlank(stage)
                ? '현재 영업 단계(' + stage + ')와 미팅 메모의 고객 니즈를 함께 반영합니다.'
                : '기회 정보와 미팅 메모의 고객 니즈를 함께 반영합니다.';
        }
        return '현재 고객 정보와 미팅 메모를 함께 반영해 RP 추천 근거를 구성합니다.';
    }

    private static void addField(List<String> fields, Map<String, Schema.SObjectField> fieldMap, String name) {
        if (fieldMap.containsKey(name)) fields.add(name);
    }
    private static String firstExisting(Map<String, Schema.SObjectField> fieldMap, List<String> candidates) {
        for (String candidate : candidates) if (fieldMap.containsKey(candidate)) return candidate;
        return null;
    }
    private static String textValue(SObject row, String field) {
        if (row == null || String.isBlank(field)) return null;
        try { Object value = row.get(field); return value == null ? null : String.valueOf(value); }
        catch (Exception ignored) { return null; }
    }
    private static String relationshipName(SObject row, String relationship) {
        try {
            SObject related = row.getSObject(relationship);
            return related == null ? null : textValue(related, 'Name');
        } catch (Exception ignored) { return null; }
    }
    private static void addPart(List<String> parts, String label, String value) {
        if (String.isNotBlank(value)) parts.add(label + ' ' + value);
    }
}