/**
 * 우선순위 상위 발굴 Lead 의 "왜 상위인가" 사유를 Lead_Priority_Rationale 프롬프트 템플릿(LLM)으로
 * 생성해 Lead 필드에 저장하는 Queueable.
 *
 * 프롬프트 템플릿 호출은 콜아웃이므로 Batch 가 아닌 Queueable(Database.AllowsCallouts)로 처리한다.
 * 대상이 상위 N(기본 10)건으로 작아 QueryLocator 청킹이 필요 없다.
 *
 * AI 이원화 원칙(LeadPriorityRationaleProvider 와 동일): 이 클래스는 점수를 재계산하지 않는다.
 * PriorityScoreBatch 가 산정한 Priority_Score__c 상위 Lead 를 골라, 그 점수의 "사유 텍스트"만
 * 프롬프트 템플릿으로 생성해 저장한다. 근거 재무·시그널 주입은 LeadPriorityRationaleProvider 가 맡는다.
 *
 * 스케줄: LeadRationaleSchedulable 이 매일 오전 6시에 이 Queueable 을 기동한다.
 */
public with sharing class LeadRationaleQueueable implements Queueable, Database.AllowsCallouts {

    @TestVisible private static final String PROMPT_TEMPLATE_API_NAME = 'Lead_Priority_Rationale';
    @TestVisible private static final Integer DEFAULT_TOP_COUNT = 10;
    @TestVisible private static final String SUMMARY_MARKER = '요약:';
    @TestVisible private static final String DETAIL_MARKER = '상세:';

    private final Integer topCount;

    /** 기본 상위 10건 대상. */
    public LeadRationaleQueueable() {
        this(DEFAULT_TOP_COUNT);
    }

    /**
     * @param topCount 사유를 생성할 상위 Lead 수(우선순위 점수 내림차순)
     */
    public LeadRationaleQueueable(Integer topCount) {
        this.topCount = (topCount == null || topCount <= 0) ? DEFAULT_TOP_COUNT : topCount;
    }

    /**
     * 우선순위 상위 발굴 Lead 를 조회해 각 Lead 의 사유를 프롬프트 템플릿으로 생성하고 저장한다.
     * @param context Queueable 컨텍스트
     */
    public void execute(QueueableContext context) {
        List<Lead> topLeads = [
            SELECT Id, Company, Assigned_Company_Code__c, Priority_Score__c
            FROM Lead
            WHERE IsConverted = false AND Status = '신규' AND Priority_Score__c != null
            WITH USER_MODE
            ORDER BY Priority_Score__c DESC NULLS LAST, Name ASC
            LIMIT :topCount
        ];
        if (topLeads.isEmpty()) {
            return;
        }

        Datetime generatedAt = Datetime.now();
        List<Lead> toUpdate = new List<Lead>();
        for (Lead lead : topLeads) {
            RationaleText rationale = generateRationale(lead.Id);
            if (rationale == null) {
                continue;
            }
            lead.Priority_Rationale_Summary__c = truncateLeft(rationale.summary, 255);
            lead.Priority_Rationale_Detail__c = truncateLeft(rationale.detail, 2000);
            lead.Priority_Rationale_Updated_At__c = generatedAt;
            toUpdate.add(lead);
        }

        if (!toUpdate.isEmpty()) {
            Database.update(toUpdate, false, AccessLevel.USER_MODE);
        }
    }

    /**
     * 한 Lead 에 대해 프롬프트 템플릿을 호출하고 응답을 요약/상세로 분리한다.
     * 호출이 실패하거나 빈 응답이면 null 을 돌려 그 Lead 는 갱신에서 제외한다.
     * @param leadId 사유를 생성할 Lead Id
     * @return 요약·상세 텍스트, 실패 시 null
     */
    @TestVisible
    private RationaleText generateRationale(Id leadId) {
        String response;
        try {
            response = invokeTemplate(leadId);
        } catch (Exception e) {
            // 개별 Lead 실패가 나머지 Lead 생성을 막지 않도록 격리한다.
            return null;
        }
        if (String.isBlank(response)) {
            return null;
        }
        return parseResponse(response);
    }

    /**
     * Lead_Priority_Rationale 프롬프트 템플릿을 호출해 생성된 텍스트를 반환한다.
     * 테스트에서는 stub 응답으로 대체할 수 있도록 seam 으로 분리한다.
     * @param leadId 템플릿 입력(RelatedLead)으로 전달할 Lead Id
     * @return LLM 이 생성한 원문 텍스트
     */
    @TestVisible
    private String invokeTemplate(Id leadId) {
        if (stubResponse != null) {
            return stubResponse;
        }
        ConnectApi.EinsteinPromptTemplateGenerationsInput input =
            new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        input.isPreview = false;
        input.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        input.additionalConfig.applicationName = 'PromptBuilderPreview';

        ConnectApi.WrappedValue leadValue = new ConnectApi.WrappedValue();
        leadValue.value = leadId;

        Map<String, ConnectApi.WrappedValue> inputParams = new Map<String, ConnectApi.WrappedValue>();
        inputParams.put('Input:RelatedLead', leadValue);
        input.inputParams = inputParams;

        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation result =
            ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(PROMPT_TEMPLATE_API_NAME, input);

        if (result == null || result.generations == null || result.generations.isEmpty()) {
            return null;
        }
        return result.generations[0].text;
    }

    /**
     * 프롬프트 출력("요약: ...\n상세: ...")을 요약·상세 두 부분으로 분리한다.
     * 마커가 없으면 전체를 상세로 담고 요약은 앞부분에서 만든다.
     * @param response LLM 원문 텍스트
     * @return 요약·상세를 담은 RationaleText
     */
    @TestVisible
    private RationaleText parseResponse(String response) {
        String text = response.trim();
        RationaleText result = new RationaleText();

        Integer summaryIndex = text.indexOf(SUMMARY_MARKER);
        Integer detailIndex = text.indexOf(DETAIL_MARKER);

        if (summaryIndex >= 0 && detailIndex > summaryIndex) {
            result.summary = text.substring(summaryIndex + SUMMARY_MARKER.length(), detailIndex).trim();
            result.detail = text.substring(detailIndex + DETAIL_MARKER.length()).trim();
        } else if (detailIndex >= 0) {
            result.detail = text.substring(detailIndex + DETAIL_MARKER.length()).trim();
            result.summary = firstLine(result.detail);
        } else {
            result.detail = text;
            result.summary = firstLine(text);
        }
        return result;
    }

    private String firstLine(String text) {
        if (String.isBlank(text)) {
            return text;
        }
        Integer newline = text.indexOf('\n');
        return newline < 0 ? text : text.substring(0, newline).trim();
    }

    private String truncateLeft(String value, Integer maxLength) {
        if (value == null) {
            return null;
        }
        return value.length() <= maxLength ? value : value.substring(0, maxLength);
    }

    /** 프롬프트 출력의 요약·상세 두 부분. */
    public class RationaleText {
        public String summary;
        public String detail;
    }

    /** 테스트 seam: 값이 있으면 invokeTemplate 이 실제 콜아웃 대신 이 문자열을 반환한다. */
    @TestVisible
    private static String stubResponse;
}