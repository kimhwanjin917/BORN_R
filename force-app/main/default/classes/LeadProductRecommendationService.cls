/**
 * 한 리드의 상품추천을 LLM 으로 판정해 기록한다. 대화 없이 부르는 경로다.
 *
 * [왜 있나]
 * 추천 5개 필드에 LLM 판정을 넣는 길은 지금까지 "RM 이 에이전트와 대화하기" 하나뿐이었다.
 * 아무도 말을 걸지 않은 리드는 추천이 영원히 비고, 브리핑도 제안서도 "미정"만 보여준다.
 * 브리핑 새로고침처럼 RM 이 이미 하는 동작에 이 판정을 얹어 그 공백을 없앤다.
 *
 * [에이전트와 결과가 같아야 한다]
 * 근거는 LeadProductRecommendationProvider 가 LeadProductRecommendationAction 으로 모은다 —
 * 에이전트가 보는 재료와 같다. 저장도 LeadRecommendationSaveAction.save() 에 그대로 위임한다.
 * 그 안에 상품군-종목 Family 정합성 검증과 기간·요율 기본값 채우기가 들어 있어서, 여기서 필드를
 * 직접 update 하면 그 검증을 우회하게 된다. 판정 주체도 저장 경로도 에이전트와 동일해야 한다.
 *
 * [폴백]
 * LLM 호출이 실패하거나 응답을 읽을 수 없으면 LeadRecommendationEngine(재무 규칙)으로 떨어진다.
 * 프롬프트 템플릿이 아직 org 에 없으면 항상 이 경로를 타므로, 템플릿 도입 전에도 동작이 그대로다.
 *
 * 호출은 콜아웃이다. DML 을 먼저 한 트랜잭션에서 부르면 uncommitted work pending 이 나므로,
 * 프롬프트 템플릿 호출 앞에 DML 이 없는 자리에서만 부를 것.
 */
public with sharing class LeadProductRecommendationService {

    @TestVisible
    private static final String PROMPT_TEMPLATE_API_NAME = 'Lead_Product_Recommendation';

    /** 판정이 어디서 나왔는지. 호출부가 로그·표시에 쓴다. */
    public enum Source { ALREADY_PRESENT, LLM, RULE_ENGINE, NONE }

    public class Outcome {
        /** 필드명을 source 로 두면 Apex 가 대소문자를 구분하지 않아 Source 열거형을 가린다. */
        public Source decidedBy = Source.NONE;
        public String detail;
    }

    /**
     * 추천이 없으면 채운다. 이미 있으면 건드리지 않는다 — 에이전트가 기록한 값을 덮으면 안 된다.
     * 어떤 경우에도 예외를 던지지 않는다. 추천 채우기 실패가 호출부(브리핑 생성 등)를 막으면 안 된다.
     * @param leadId 대상 Lead Id
     * @return 어느 경로로 채웠는지
     */
    public static Outcome ensureRecommendation(Id leadId) {
        Outcome result = new Outcome();
        if (leadId == null) {
            result.detail = 'Lead Id 가 없습니다.';
            return result;
        }

        // 상품 종목 lookup은 RM 권한 세트에서 선택 필드일 수 있다. 필드 하나의 FLS
        // 부족으로 추천 전체가 실패하지 않도록 항상 읽을 수 있는 상품군만 조회한다.
        List<Lead> leads = [
            SELECT Id, Recommended_Product_Family__c
            FROM Lead
            WHERE Id = :leadId
            WITH USER_MODE
            LIMIT 1
        ];
        if (leads.isEmpty()) {
            result.detail = '리드를 찾을 수 없거나 조회 권한이 없습니다.';
            return result;
        }
        if (String.isNotBlank(leads[0].Recommended_Product_Family__c)) {
            result.decidedBy = Source.ALREADY_PRESENT;
            result.detail = '이미 저장된 추천이 있어 그대로 둡니다.';
            return result;
        }

        if (saveLlmVerdict(leadId)) {
            result.decidedBy = Source.LLM;
            result.detail = 'LLM 판정을 기록했습니다.';
            return result;
        }

        // 폴백. 규칙 엔진도 저장에 실패하면 추천은 비어 있는 채로 남는다 —
        // 근거 없는 값을 넣느니 비워 두는 편이 낫다.
        LeadRecommendationEngine.Result fallback = LeadRecommendationEngine.ensureRecommendation(leadId);
        if (fallback != null && fallback.saved) {
            result.decidedBy = Source.RULE_ENGINE;
            result.detail = 'LLM 판정을 얻지 못해 재무 규칙으로 채웠습니다.';
        } else {
            result.detail = fallback == null ? '추천을 만들지 못했습니다.' : fallback.skipReason;
        }
        return result;
    }

    /**
     * 프롬프트 템플릿으로 판정을 받아 SaveAction 으로 기록한다.
     * @param leadId 대상 Lead Id
     * @return 기록에 성공했으면 true
     */
    @TestVisible
    private static Boolean saveLlmVerdict(Id leadId) {
        String raw;
        try {
            raw = invokeTemplate(leadId);
        } catch (Exception e) {
            // 템플릿이 아직 없거나 LLM 이 응답하지 않는 경우. 폴백으로 넘긴다.
            System.debug(LoggingLevel.WARN, '상품추천 템플릿 호출 실패 (' + leadId + '): ' + e.getMessage());
            return false;
        }
        if (String.isBlank(raw)) {
            return false;
        }

        Verdict verdict = parseVerdict(raw);
        if (verdict == null || String.isBlank(verdict.productFamily)) {
            return false;
        }

        LeadRecommendationSaveAction.Request req = new LeadRecommendationSaveAction.Request();
        req.leadId = leadId;
        req.productFamily = verdict.productFamily.trim();
        req.productName = verdict.productName;
        // 0 이나 음수는 값이 아니라 "모름"으로 본다. 그대로 넘기면 SaveAction 이 null 일 때만
        // 상품 기본값으로 채우기 때문에 요율 0% 같은 값이 저장된다 — 실제로 모델이 0 을 준 적이 있다.
        req.termDays = positiveOrNull(verdict.termDays);
        req.feeRate = positiveOrNull(verdict.feeRate);
        req.rationale = verdict.rationale;

        List<LeadRecommendationSaveAction.Response> out =
            LeadRecommendationSaveAction.save(new List<LeadRecommendationSaveAction.Request>{ req });
        if (out == null || out.isEmpty() || out[0] == null || out[0].isSuccess != true) {
            // 상품군과 종목의 Family 가 안 맞는 등 SaveAction 이 거부한 경우.
            System.debug(LoggingLevel.WARN,
                '상품추천 저장 거부: ' + (out == null || out.isEmpty() ? '응답 없음' : out[0].message));
            return false;
        }
        return true;
    }

    /**
     * Lead_Product_Recommendation 템플릿을 호출한다.
     * 테스트에서 stub 으로 대체할 수 있도록 seam 으로 분리한다 — 템플릿이 org 에 없어도 전 경로를 검증한다.
     * @param leadId 템플릿 입력(RelatedLead)으로 넘길 Lead Id
     * @return LLM 이 생성한 원문 텍스트
     */
    @TestVisible
    private static String invokeTemplate(Id leadId) {
        if (Test.isRunningTest()) {
            return stubResponse;
        }
        ConnectApi.EinsteinPromptTemplateGenerationsInput input =
            new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        input.isPreview = false;
        input.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        input.additionalConfig.applicationName = 'PromptTemplateGenerationsInvocable';

        // Id 를 그대로 넣으면 "Invalid input value ... for item Input:RelatedLead" 가 난다.
        // SObject 입력은 {'id' => 레코드Id} 맵으로 감싸야 한다 (MeetingPrepBriefingController 와 같은 형식).
        ConnectApi.WrappedValue leadValue = new ConnectApi.WrappedValue();
        leadValue.value = new Map<String, Object>{ 'id' => leadId };
        input.inputParams = new Map<String, ConnectApi.WrappedValue>{ 'Input:RelatedLead' => leadValue };

        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation result =
            ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(PROMPT_TEMPLATE_API_NAME, input);

        if (result == null || result.generations == null || result.generations.isEmpty()) {
            return null;
        }
        return result.generations[0].text;
    }

    /**
     * LLM 원문에서 판정 JSON 을 꺼낸다.
     *
     * 모델이 코드펜스나 앞뒤 설명을 붙여도 읽히도록 첫 '{' 부터 마지막 '}' 까지를 잘라 쓴다.
     * 형식이 어긋나면 null 을 돌려 폴백으로 넘긴다 — 문장에서 종목명을 추측해 끼워 넣으면
     * 카탈로그에 없는 이름이 들어가고, 그건 조용히 잘못된 추천이 된다.
     * @param raw LLM 원문 텍스트
     * @return 판정 값, 읽을 수 없으면 null
     */
    @TestVisible
    private static Verdict parseVerdict(String raw) {
        Integer openAt = raw.indexOf('{');
        Integer closeAt = raw.lastIndexOf('}');
        if (openAt < 0 || closeAt <= openAt) {
            return null;
        }
        try {
            return (Verdict) JSON.deserialize(raw.substring(openAt, closeAt + 1), Verdict.class);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, '판정 JSON 파싱 실패: ' + e.getMessage());
            return null;
        }
    }

    private static Decimal positiveOrNull(Decimal value) {
        return (value == null || value <= 0) ? null : value;
    }

    /** 템플릿이 돌려주는 판정 형식. 필드명은 템플릿 사양서와 1:1로 맞춰야 한다. */
    public class Verdict {
        public String productFamily;
        public String productName;
        public Decimal termDays;
        public Decimal feeRate;
        public String rationale;
    }

    @TestVisible
    private static String stubResponse;
}