/**
 * 프롬프트 템플릿 "Lead_Product_Recommendation" 의 grounding 용 Apex.
 *
 * 이 리드에 어떤 상품을 제안할지 LLM 이 판정하는 데 필요한 재료 — 재무 추이·최신 분기 잔고·외부
 * 시그널·활성 상품 카탈로그 — 를 하나의 텍스트로 묶어 템플릿에 주입한다.
 *
 * [왜 조회를 다시 짜지 않았나]
 * LeadProductRecommendationAction 이 에이전트에게 넘기는 재료와 **완전히 같은 것**이 필요하다.
 * 그 액션의 Response 에는 이미 financialText · signalText · candidateText 가 서식까지 갖춰
 * 들어 있으므로, 여기서는 gather() 를 호출해 이어 붙이기만 한다. 조회를 복제하면 에이전트와
 * 배치가 서로 다른 근거를 보게 되고, 그 순간 이 클래스의 존재 이유가 사라진다.
 *
 * [이 org 의 프롬프트 프로바이더 규약 — MeetingPrepBriefingProvider 와 동일]
 *  - @InvocableMethod 에 CapabilityType 을 지정하지 않는다 (flex 템플릿 타입은 컴파일 거부됨, 2026-08 확인).
 *  - Request 멤버 이름은 템플릿 입력 apiName(RelatedLead) 과 일치해야 Prompt Builder 가 노출한다.
 *  - 조회는 WITH USER_MODE. 권한이 없거나 데이터가 없으면 예외 대신 안내 문구를 돌려
 *    프롬프트는 항상 생성되게 한다.
 *
 * 판정은 하지 않는다. 상품군·종목을 고르는 것은 LLM 이고, 그 결과를 Lead 에 기록하는 것은
 * LeadRecommendationSaveAction 이다. 여기서 미리 고르면 에이전트와 답이 갈린다.
 */
public with sharing class LeadProductRecommendationProvider {

    @TestVisible
    private static final String NO_LEAD_MESSAGE =
        '(리드 정보가 전달되지 않았습니다. 제공된 정보 외의 근거를 만들어내지 마세요.)';
    @TestVisible
    private static final String NO_ACCESS_MESSAGE =
        '(이 리드를 조회할 권한이 없습니다. 추천을 만들지 말고 그렇게 답하세요.)';
    /**
     * 카탈로그에는 활성 상품이 전부 실리지만, Lead 에 기록할 수 있는 상품군은
     * LeadRecommendationSaveAction.ALLOWED_FAMILIES 의 두 개(RP · 회사채)뿐이다.
     * 이 제약을 프롬프트에 적지 않으면 모델이 MMF·특정금전신탁 같은 자금운용 상품을 고르고,
     * 저장 단계에서 거부되어 조용히 규칙 엔진으로 떨어진다 — AI 추천이 거의 나오지 않게 된다.
     * 외화 상품 제외는 LeadRecommendationEngine.pickProduct 와 같은 기준이다.
     */
    @TestVisible
    private static final String SELECTION_RULES =
        '[판정 규칙]\n'
        + '- 상품군은 반드시 "RP" 또는 "회사채" 중 하나로만 답할 것. 다른 상품군은 기록할 수 없다.\n'
        + '- 종목은 그 상품군에 속한 것만 고를 것 (RP → Family가 RP인 상품, 회사채 → Family가 채권인 상품).\n'
        + '- 원화 거래가 기본이다. 외화 상품은 고객이 외화 자금을 다룬다는 근거가 있을 때만 고를 것.\n'
        + '- 운용기간은 그 종목의 허용 기간 범위 안에서 정할 것.\n'
        + '- 근거는 위에 제공된 수치만 인용할 것. 제공되지 않은 숫자를 지어내지 말 것.';

    @TestVisible
    private static final String NO_CANDIDATE_MESSAGE =
        '(제안 가능한 활성 상품이 없습니다. 추천을 만들지 말고 그렇게 답하세요.)';

    @InvocableMethod(
        label='Lead 상품추천 grounding'
        description='리드의 재무 추이·최신 분기 잔고·외부 시그널·활성 상품 카탈로그를 텍스트로 묶어 Lead_Product_Recommendation 프롬프트 템플릿에 주입합니다. 적합성 판단은 하지 않습니다.')
    public static List<Response> getRecommendationContext(List<Request> requests) {
        List<Response> responses = new List<Response>();
        if (requests == null || requests.isEmpty()) {
            return responses;
        }
        for (Request request : requests) {
            Response response = new Response();
            response.Prompt = buildContextText(request == null ? null : request.RelatedLead);
            responses.add(response);
        }
        return responses;
    }

    /**
     * 리드의 판정 재료를 텍스트로 만든다. 권한·데이터 문제는 예외 대신 안내 문구로 대체한다.
     * @param relatedLead 템플릿이 넘겨준 Lead (Id 만 사용)
     * @return 프롬프트에 주입할 근거 텍스트
     */
    @TestVisible
    private static String buildContextText(Lead relatedLead) {
        if (relatedLead == null || relatedLead.Id == null) {
            return NO_LEAD_MESSAGE;
        }

        LeadProductRecommendationAction.Response material = gatherFor(relatedLead.Id);
        if (material == null || material.isAccessible != true) {
            return NO_ACCESS_MESSAGE;
        }
        if (String.isBlank(material.candidateText)) {
            return NO_CANDIDATE_MESSAGE;
        }

        List<String> blocks = new List<String>();
        blocks.add(buildLeadBlock(material));
        if (String.isNotBlank(material.financialText)) {
            blocks.add('[공시 재무]\n' + material.financialText);
        }
        if (String.isNotBlank(material.signalText)) {
            blocks.add('[외부 시그널]\n' + material.signalText);
        }
        // 상품 카탈로그는 마지막에 둔다. 종목명을 여기 적힌 것과 정확히 일치시켜야 저장이 되므로,
        // 모델이 가장 최근에 읽은 블록이 되도록 배치한다.
        blocks.add('[제안 가능한 활성 상품 — 종목명은 아래 표기와 정확히 일치시킬 것]\n'
            + material.candidateText);
        blocks.add(SELECTION_RULES);
        return String.join(blocks, '\n\n');
    }

    /** 이미 기록된 추천이 있으면 그것도 함께 알린다 — 모델이 뒤집을지 유지할지 판단할 근거가 된다. */
    @TestVisible
    private static String buildLeadBlock(LeadProductRecommendationAction.Response m) {
        List<String> lines = new List<String>();
        lines.add('[고객사]');
        lines.add('- 회사명: ' + textOrUnknown(m.company));
        lines.add('- 업종: ' + textOrUnknown(m.industry));
        lines.add('- 리드 상태: ' + textOrUnknown(m.status));
        if (m.priorityScore != null) {
            lines.add('- 우선순위 점수: ' + m.priorityScore.setScale(1));
        }
        if (String.isNotBlank(m.priorityRationale)) {
            lines.add('- 우선순위 사유: ' + m.priorityRationale);
        }
        lines.add('- 기존 추천 상품군: ' + (String.isBlank(m.currentProductFamily) ? '없음' : m.currentProductFamily));
        if (String.isNotBlank(m.currentRationale)) {
            lines.add('- 기존 추천 근거: ' + m.currentRationale);
        }
        return String.join(lines, '\n');
    }

    /**
     * 재료 조회. 에이전트가 쓰는 액션을 그대로 호출해 같은 근거를 얻는다.
     * @param leadId 대상 Lead Id
     * @return 재료 Response, 조회 실패 시 null
     */
    @TestVisible
    private static LeadProductRecommendationAction.Response gatherFor(Id leadId) {
        LeadProductRecommendationAction.Request req = new LeadProductRecommendationAction.Request();
        req.leadId = leadId;
        List<LeadProductRecommendationAction.Response> out =
            LeadProductRecommendationAction.gather(
                new List<LeadProductRecommendationAction.Request>{ req });
        return (out == null || out.isEmpty()) ? null : out[0];
    }

    private static String textOrUnknown(String value) {
        return String.isBlank(value) ? '정보 없음' : value;
    }

    public class Request {
        @InvocableVariable(required=true label='RelatedLead' description='프롬프트 템플릿의 Lead 입력 (apiName: RelatedLead)')
        public Lead RelatedLead;
    }

    public class Response {
        @InvocableVariable(required=true label='Prompt' description='템플릿에 주입할 상품추천 근거 텍스트')
        public String Prompt;
    }
}