/**
 * leadMeetingPrepBriefing LWC 의 컨트롤러.
 *
 * Lead 레코드 페이지의 "미팅 준비 브리핑" 박스가 사용한다.
 *  - getBriefing: Lead 에 저장(캐시)된 브리핑과 생성 시각을 즉시 돌려준다(cacheable).
 *  - generateBriefing: Meeting_Prep_Briefing 프롬프트 템플릿을 호출해 브리핑을 새로 만들고
 *    Meeting_Prep_Briefing__c / Meeting_Prep_Briefing_Updated_At__c 에 저장한 뒤 돌려준다.
 *
 * 프롬프트 템플릿 자체는 MeetingPrepBriefingProvider(Apex) 로 CRM·재무추이·시그널·추천 상품군을
 * grounding 하므로, 여기서는 템플릿을 호출하고 결과를 캐시하는 책임만 진다.
 * 버튼(Flow Lead_Meeting_Prep_Briefing) 과 동일한 템플릿을 쓰지만, 화면 없이 저장형으로 동작한다.
 */
public with sharing class MeetingPrepBriefingController {

    @TestVisible private static final String TEMPLATE_API_NAME = 'Meeting_Prep_Briefing';
    /** 테스트에서 ConnectApi 호출을 대신할 응답 주입 지점(테스트 컨텍스트에서만 사용). */
    @TestVisible private static String testResponseOverride;

    public class BriefingResult {
        @AuraEnabled public String briefing;
        @AuraEnabled public Datetime updatedAt;
    }

    /** 저장된 브리핑을 즉시 반환. 페이지 로드 시 호출(AI 호출 없음). */
    @AuraEnabled(cacheable=true)
    public static BriefingResult getBriefing(Id recordId) {
        Lead lead = loadLead(recordId);
        BriefingResult result = new BriefingResult();
        result.briefing = lead.Meeting_Prep_Briefing__c;
        result.updatedAt = lead.Meeting_Prep_Briefing_Updated_At__c;
        return result;
    }

    /** 프롬프트 템플릿으로 브리핑을 새로 생성해 Lead 에 저장하고 반환. "새로고침" 버튼이 호출. */
    @AuraEnabled
    public static BriefingResult generateBriefing(Id recordId) {
        if (recordId == null) {
            throw new AuraHandledException('Lead 정보가 없어 브리핑을 생성할 수 없습니다.');
        }
        try {
            String briefingText = invokePromptTemplate(recordId);
            if (String.isBlank(briefingText)) {
                throw new AuraHandledException('AI 응답이 비어 있어 브리핑을 생성하지 못했습니다.');
            }
            Datetime now = System.now();
            Lead toUpdate = new Lead(
                Id = recordId,
                Meeting_Prep_Briefing__c = briefingText,
                Meeting_Prep_Briefing_Updated_At__c = now
            );
            update as user toUpdate;

            BriefingResult result = new BriefingResult();
            result.briefing = briefingText;
            result.updatedAt = now;
            return result;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('브리핑 생성 중 오류가 발생했습니다: ' + e.getMessage());
        }
    }

    private static Lead loadLead(Id recordId) {
        return [
            SELECT Meeting_Prep_Briefing__c, Meeting_Prep_Briefing_Updated_At__c
            FROM Lead
            WHERE Id = :recordId
            WITH USER_MODE
            LIMIT 1
        ];
    }

    /**
     * Meeting_Prep_Briefing 프롬프트 템플릿을 호출해 브리핑 텍스트를 얻는다.
     * 템플릿 입력 apiName 은 RelatedLead(SObject://Lead) 이며 레코드 Id 만 넘기면 된다.
     */
    @TestVisible
    private static String invokePromptTemplate(Id recordId) {
        if (Test.isRunningTest()) {
            return testResponseOverride;
        }
        ConnectApi.EinsteinPromptTemplateGenerationsInput input =
            new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        ConnectApi.EinsteinLlmAdditionalConfigInput config =
            new ConnectApi.EinsteinLlmAdditionalConfigInput();
        config.applicationName = 'PromptTemplateGenerationsInvocable';
        input.additionalConfig = config;
        input.isPreview = false;

        ConnectApi.WrappedValue leadValue = new ConnectApi.WrappedValue();
        leadValue.value = new Map<String, Object>{ 'id' => recordId };
        input.inputParams = new Map<String, ConnectApi.WrappedValue>{ 'Input:RelatedLead' => leadValue };

        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation response =
            ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(TEMPLATE_API_NAME, input);

        if (response != null && response.generations != null && !response.generations.isEmpty()) {
            return response.generations[0].text;
        }
        return null;
    }
}
