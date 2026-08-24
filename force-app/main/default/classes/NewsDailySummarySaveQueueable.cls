/**
 * 일일 뉴스 요약을 News_Daily_Summary 프롬프트 템플릿(LLM)으로 생성해
 * ExternalSignal__c(Signal_Type__c='일일요약') 레코드로 저장하는 Queueable.
 *
 * 프롬프트 템플릿 호출은 콜아웃이므로 Queueable(Database.AllowsCallouts)로 처리한다.
 * 뉴스 요약은 특정 레코드가 아닌 org 전체 요약이라, 요약 일자(Summary_Date__c) 기준으로
 * 하루 한 건만 유지한다(같은 날짜의 일일요약 레코드가 있으면 갱신, 없으면 생성).
 *
 * AI 이원화 원칙(NewsDailySummaryProvider 와 동일): 뉴스를 새로 만들지 않는다.
 * 근거 뉴스 주입은 NewsDailySummaryProvider 가, 요약문 생성은 프롬프트 템플릿이 맡는다.
 *
 * 스케줄: NewsDailySummarySchedulable 이 매일 이 Queueable 을 기동한다.
 *
 * 조회·저장은 시스템 모드(PriorityScoreBatch 와 동일 방침)로 수행한다. 일일요약 레코드는 백엔드
 * 스케줄 잡만 기록하고 사용자가 직접 입력하지 않으므로, 스케줄 소유자의 FLS 에 저장이 좌우되지 않게 한다.
 */
public with sharing class NewsDailySummarySaveQueueable implements Queueable, Database.AllowsCallouts {

    @TestVisible private static final String PROMPT_TEMPLATE_API_NAME = 'News_Daily_Summary';
    @TestVisible private static final String DAILY_SUMMARY_SIGNAL = '일일요약';

    /**
     * 오늘 날짜 기준 일일 뉴스 요약을 생성해 ExternalSignal__c(Signal_Type__c='일일요약')에 저장한다.
     * 응답이 비어 있으면 저장하지 않아, 기존 요약을 빈 값으로 덮어쓰지 않는다.
     * @param context Queueable 컨텍스트
     */
    public void execute(QueueableContext context) {
        String summaryText;
        try {
            summaryText = invokeTemplate();
        } catch (Exception e) {
            // 콜아웃 실패 시 기존 요약을 보존하기 위해 저장하지 않는다.
            return;
        }
        if (String.isBlank(summaryText)) {
            return;
        }

        // 스케줄 소유자의 FLS 에 좌우되지 않도록 시스템 모드로 조회·저장한다.
        // 일일요약 레코드는 백엔드 스케줄 잡만 기록하며 사용자가 직접 입력하지 않는다.
        Date today = Date.today();
        List<ExternalSignal__c> existing = [
            SELECT Id
            FROM ExternalSignal__c
            WHERE Signal_Type__c = :DAILY_SUMMARY_SIGNAL AND Summary_Date__c = :today
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        ExternalSignal__c record = existing.isEmpty()
            ? new ExternalSignal__c(
                Signal_Type__c = DAILY_SUMMARY_SIGNAL,
                Signal_Date__c = today,
                Title__c = String.valueOf(today) + ' 일일 뉴스 요약',
                External_Key__c = 'DAILY_SUMMARY_' + String.valueOf(today)
            )
            : existing[0];
        record.Summary_Date__c = today;
        record.Summary_Text__c = summaryText;
        record.Generated_At__c = Datetime.now();

        Database.upsert(record, true, AccessLevel.SYSTEM_MODE);
    }

    /**
     * News_Daily_Summary 프롬프트 템플릿을 호출해 생성된 요약 텍스트를 반환한다.
     * 이 템플릿은 특정 레코드 입력이 필요 없다(org 전체 요약).
     * 테스트에서는 stub 응답으로 대체할 수 있도록 seam 으로 분리한다.
     * @return LLM 이 생성한 요약 텍스트
     */
    @TestVisible
    private String invokeTemplate() {
        if (stubResponse != null) {
            return stubResponse;
        }
        ConnectApi.EinsteinPromptTemplateGenerationsInput input =
            new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        input.isPreview = false;
        input.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        input.additionalConfig.applicationName = 'PromptBuilderPreview';
        input.inputParams = new Map<String, ConnectApi.WrappedValue>();

        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation result =
            ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(PROMPT_TEMPLATE_API_NAME, input);

        if (result == null || result.generations == null || result.generations.isEmpty()) {
            return null;
        }
        return result.generations[0].text;
    }

    /** 테스트 seam: 값이 있으면 invokeTemplate 이 실제 콜아웃 대신 이 문자열을 반환한다. */
    @TestVisible
    private static String stubResponse;
}
