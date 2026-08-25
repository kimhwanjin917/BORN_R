/**
 * 우선순위 상위 기업(Account) 의 "왜 상위인가" 사유를 Account_Priority_Rationale 프롬프트 템플릿(LLM)으로
 * 생성해 Account 필드에 저장하는 Queueable.
 *
 * 프롬프트 템플릿 호출은 콜아웃이므로 Batch 가 아닌 Queueable(Database.AllowsCallouts)로 처리한다.
 * 대상이 상위 N(기본 10)건으로 작아 QueryLocator 청킹이 필요 없다.
 *
 * AI 이원화 원칙(AccountPriorityRationaleProvider 와 동일): 이 클래스는 점수를 재계산하지 않는다.
 * PriorityScoreBatch 가 산정한 Priority_Score__c 상위 Account 를 골라, 그 점수의 "사유 텍스트"만
 * 프롬프트 템플릿으로 생성해 저장한다. 근거 재무·시그널 주입은 AccountPriorityRationaleProvider 가 맡는다.
 * 영업 진행 중(열린 Opportunity 보유) Account 는 PriorityScoreBatch 가 점수를 null 로 두므로 자연히 대상에서 빠진다.
 *
 * 스케줄: AccountRationaleSchedulable 이 매일 오전 6시에 이 Queueable 을 기동한다.
 */
public with sharing class AccountRationaleQueueable implements Queueable, Database.AllowsCallouts {

    @TestVisible private static final String PROMPT_TEMPLATE_API_NAME = 'Account_Priority_Rationale';
    @TestVisible private static final Integer DEFAULT_TOP_COUNT = 10;
    @TestVisible private static final String SUMMARY_MARKER = '요약:';
    @TestVisible private static final String DETAIL_MARKER = '상세:';

    private final Integer topCount;

    /** 기본 상위 10건 대상. */
    public AccountRationaleQueueable() {
        this(DEFAULT_TOP_COUNT);
    }

    /**
     * @param topCount 사유를 생성할 상위 Account 수(우선순위 점수 내림차순)
     */
    public AccountRationaleQueueable(Integer topCount) {
        this.topCount = (topCount == null || topCount <= 0) ? DEFAULT_TOP_COUNT : topCount;
    }

    /**
     * 우선순위 상위 기업(Account) 를 조회해 각 기업의 사유를 프롬프트 템플릿으로 생성하고 저장한다.
     * @param context Queueable 컨텍스트
     */
    public void execute(QueueableContext context) {
        List<Account> topAccounts = [
            SELECT Id, Name, Priority_Score__c
            FROM Account
            WHERE Priority_Score__c != null
            WITH USER_MODE
            ORDER BY Priority_Score__c DESC NULLS LAST, Name ASC
            LIMIT :topCount
        ];
        if (topAccounts.isEmpty()) {
            return;
        }

        Datetime generatedAt = Datetime.now();
        List<Account> toUpdate = new List<Account>();
        for (Account account : topAccounts) {
            RationaleText rationale = generateRationale(account.Id);
            if (rationale == null) {
                continue;
            }
            account.Priority_Rationale_Summary__c = truncateLeft(rationale.summary, 255);
            account.Priority_Rationale_Detail__c = truncateLeft(rationale.detail, 2000);
            account.Priority_Rationale_Updated_At__c = generatedAt;
            toUpdate.add(account);
        }

        if (!toUpdate.isEmpty()) {
            Database.update(toUpdate, false, AccessLevel.USER_MODE);
        }
    }

    /**
     * 한 Account 에 대해 프롬프트 템플릿을 호출하고 응답을 요약/상세로 분리한다.
     * 호출이 실패하거나 빈 응답이면 null 을 돌려 그 Account 는 갱신에서 제외한다.
     * @param accountId 사유를 생성할 Account Id
     * @return 요약·상세 텍스트, 실패 시 null
     */
    @TestVisible
    private RationaleText generateRationale(Id accountId) {
        String response;
        try {
            response = invokeTemplate(accountId);
        } catch (Exception e) {
            // 개별 Account 실패가 나머지 Account 생성을 막지 않도록 격리한다.
            return null;
        }
        if (String.isBlank(response)) {
            return null;
        }
        return parseResponse(response);
    }

    /**
     * Account_Priority_Rationale 프롬프트 템플릿을 호출해 생성된 텍스트를 반환한다.
     * 테스트에서는 stub 응답으로 대체할 수 있도록 seam 으로 분리한다.
     * @param accountId 템플릿 입력(RelatedAccount)으로 전달할 Account Id
     * @return LLM 이 생성한 원문 텍스트
     */
    @TestVisible
    private String invokeTemplate(Id accountId) {
        if (stubResponse != null) {
            return stubResponse;
        }
        ConnectApi.EinsteinPromptTemplateGenerationsInput input =
            new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        input.isPreview = false;
        input.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        input.additionalConfig.applicationName = 'PromptBuilderPreview';

        ConnectApi.WrappedValue accountValue = new ConnectApi.WrappedValue();
        accountValue.value = accountId;

        Map<String, ConnectApi.WrappedValue> inputParams = new Map<String, ConnectApi.WrappedValue>();
        inputParams.put('Input:RelatedAccount', accountValue);
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