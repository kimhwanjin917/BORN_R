public with sharing class MeetingPrepEmailComposerController {

    private static final String PROMPT_TEMPLATE_NAME = 'Meeting_Prep_Email_Draft';
    private static final String SUBJECT_MARKER = '제목:';
    private static final String BODY_MARKER = '본문:';

    public class EmailDraft {
        @AuraEnabled public String subject;
        @AuraEnabled public String htmlBody;
        @AuraEnabled public String bodyText;
        @AuraEnabled public String toAddress;
        @AuraEnabled public String relatedToId;
        @AuraEnabled public String leadName;
        @AuraEnabled public String fromAddress;
        @AuraEnabled public List<String> fromOptions;
    }

    public class EmailContext {
        @AuraEnabled public String toAddress;
        @AuraEnabled public String relatedToId;
        @AuraEnabled public String leadName;
        @AuraEnabled public String fromAddress;
        @AuraEnabled public List<String> fromOptions;
    }

    // 창을 즉시 띄우기 위한 빠른 컨텍스트 (LLM 호출 없음)
    @AuraEnabled(cacheable=false)
    public static EmailContext getEmailContext(Id leadId) {
        Lead leadRecord = [
            SELECT Id, Name, Email FROM Lead WHERE Id = :leadId WITH USER_MODE LIMIT 1
        ];
        EmailContext ctx = new EmailContext();
        ctx.toAddress = leadRecord.Email;
        ctx.relatedToId = leadRecord.Id;
        ctx.leadName = leadRecord.Name;
        ctx.fromAddress = UserInfo.getUserEmail();
        ctx.fromOptions = buildFromOptions();
        return ctx;
    }

    @AuraEnabled(cacheable=true)
    public static String getRecordName(Id recordId) {
        if (recordId == null) {
            return '';
        }
        String objName = recordId.getSObjectType().getDescribe().getName();
        List<SObject> rows = Database.query(
            'SELECT Name FROM ' + String.escapeSingleQuotes(objName) + ' WHERE Id = :recordId WITH USER_MODE LIMIT 1'
        );
        return rows.isEmpty() ? '' : String.valueOf(rows[0].get('Name'));
    }

    private static List<String> buildFromOptions() {
        List<String> options = new List<String>();
        String userEmail = UserInfo.getUserEmail();
        if (String.isNotBlank(userEmail)) {
            options.add(userEmail);
        }
        for (OrgWideEmailAddress owa : [
            SELECT Address FROM OrgWideEmailAddress WHERE Purpose = 'UserSelection'
        ]) {
            if (String.isNotBlank(owa.Address) && !options.contains(owa.Address)) {
                options.add(owa.Address);
            }
        }
        return options;
    }

    @AuraEnabled(cacheable=false)
    public static EmailDraft getEmailDraft(Id leadId) {
        try {
            Lead leadRecord = [
                SELECT Id, Company, Name, Title, Industry, Email, Owner.Name
                FROM Lead
                WHERE Id = :leadId
                WITH USER_MODE
                LIMIT 1
            ];

            Invocable.Action action = Invocable.Action.createCustomAction('generatePromptResponse', PROMPT_TEMPLATE_NAME);
            action.setInvocationParameter('Input:RelatedLead', leadRecord);
            List<Invocable.Action.Result> results = action.invoke();

            if (results == null || results.isEmpty() || !results[0].isSuccess()) {
                String errorDetail = (results != null && !results.isEmpty())
                    ? String.valueOf(results[0].getErrors())
                    : '알 수 없는 오류';
                throw new AuraHandledException('메일 초안 생성 응답이 비어 있습니다: ' + errorDetail);
            }

            Object rawResponse = results[0].getOutputParameters().get('promptResponse');
            if (rawResponse == null) {
                throw new AuraHandledException('메일 초안 생성 응답이 비어 있습니다.');
            }

            EmailDraft draft = parseDraft(String.valueOf(rawResponse));
            draft.toAddress = leadRecord.Email;
            draft.relatedToId = leadRecord.Id;
            draft.leadName = leadRecord.Name;
            draft.fromAddress = UserInfo.getUserEmail();
            draft.fromOptions = buildFromOptions();
            return draft;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('첫 접촉 메일 초안 생성 중 오류가 발생했습니다: ' + e.getMessage());
        }
    }

    @TestVisible
    private static EmailDraft parseDraft(String rawText) {
        if (String.isBlank(rawText)) {
            throw new AuraHandledException('메일 초안 생성 결과가 비어 있습니다.');
        }

        Integer subjectIdx = rawText.indexOf(SUBJECT_MARKER);
        Integer bodyIdx = rawText.indexOf(BODY_MARKER);
        if (subjectIdx == -1 || bodyIdx == -1 || bodyIdx <= subjectIdx) {
            throw new AuraHandledException('메일 초안 형식을 해석할 수 없습니다: ' + rawText);
        }

        String subjectLine = rawText.substring(subjectIdx + SUBJECT_MARKER.length(), bodyIdx).trim();
        String bodyText = rawText.substring(bodyIdx + BODY_MARKER.length()).trim();

        EmailDraft draft = new EmailDraft();
        draft.subject = subjectLine;
        draft.bodyText = bodyText;
        draft.htmlBody = bodyText.replace('\n', '<br/>');
        return draft;
    }
}