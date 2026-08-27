/**
 * Lead 단계 상품추천 결과를 Lead 에 기록하는 Invocable 액션.
 *
 * 기록하는 값 (이 다섯이 "에이전트 추천" 한 세트다):
 *   Recommended_Product_Family__c    RP / 회사채 — Convert 시 Opportunity RecordType 결정 근거 (ADR-0001)
 *   Recommended_Product_Rationale__c 근거
 *   Recommended_Product__c           대표 종목 (Product2)
 *   Recommended_Term_Days__c         운용기간(일)
 *   Recommended_Fee_Rate__c          수수료율
 *
 * 뒤의 셋은 미팅 준비 브리핑과 상품 제안서 PDF 가 같은 추천을 보여주게 하려고 더했다.
 * 둘이 각자 계산하면 LLM 특성상 절대 일치하지 않으므로, 한 번 판정해 여기 저장하고 양쪽이 읽는다.
 *
 * - with sharing + update as user: 실행 사용자에게 Lead 편집 권한과 위 필드 FLS 가 있어야 한다.
 * - 상품군 값은 피클리스트 값과 정확히 일치해야 하며, 아니면 기록하지 않고 실패 응답.
 * - 종목을 함께 주면 그 종목의 상품군이 선언한 상품군과 맞는지 확인한다. 어긋나면 기록하지 않는다.
 * - 종목 없이 상품군만 주면 종목·기간·요율은 지운다. 낡은 종목이 새 상품군과 모순되게 남는 것을 막는다.
 */
public with sharing class LeadRecommendationSaveAction {

    @TestVisible
    private static final Set<String> ALLOWED_FAMILIES = new Set<String>{ 'RP', '회사채' };

    /** Lead 의 상품군 피클리스트 값 → Product2.Family 값. 두 오브젝트가 서로 다른 낱말을 쓴다. */
    @TestVisible
    private static final Map<String, String> PRODUCT_FAMILY_BY_LEAD_FAMILY = new Map<String, String>{
        'RP' => 'RP',
        '회사채' => '채권'
    };

    public class Request {
        @InvocableVariable(label='Lead Id' description='기록할 미전환 Lead 의 Id' required=true)
        public Id leadId;
        @InvocableVariable(label='추천 상품군' description='RP 또는 회사채 (정확히 이 값)' required=true)
        public String productFamily;
        @InvocableVariable(label='추천 근거' description='상품군을 고른 이유 요약 (2000자 이내)' required=false)
        public String rationale;
        @InvocableVariable(label='추천 종목명' description='활성 상품(Product2)의 상품명과 정확히 일치해야 합니다. 예: RP 91일물' required=false)
        public String productName;
        @InvocableVariable(label='추천 운용기간(일)' description='비우면 종목의 최소 기간을 씁니다. 예: 91' required=false)
        public Decimal termDays;
        @InvocableVariable(label='추천 수수료율(%)' description='비우면 종목의 기본 요율을 씁니다. 예: 0.15' required=false)
        public Decimal feeRate;
    }

    public class Response {
        @InvocableVariable(label='성공 여부')
        public Boolean isSuccess;
        @InvocableVariable(label='메시지')
        public String message;
    }

    @InvocableMethod(
        label='Lead 추천 상품군 기록'
        description='Lead 단계 상품추천 결과(상품군 RP/회사채 + 근거)를 Lead 에 저장합니다. 저장된 상품군은 Convert 시 Opportunity 레코드 타입을 결정합니다.'
        category='근본증권 RM')
    public static List<Response> save(List<Request> requests) {
        List<Response> responses = new List<Response>();
        if (requests == null || requests.isEmpty()) {
            return responses;
        }

        Map<String, Product2> productsByName = queryProducts(requests);

        List<Lead> updates = new List<Lead>();
        List<Integer> updateIndexes = new List<Integer>();
        for (Integer i = 0; i < requests.size(); i++) {
            Request req = requests[i];
            Response res = new Response();
            responses.add(res);
            String family = req == null || req.productFamily == null ? '' : req.productFamily.trim();
            if (req == null || req.leadId == null) {
                res.isSuccess = false;
                res.message = 'Lead Id 가 비어 있습니다.';
                continue;
            }
            if (!ALLOWED_FAMILIES.contains(family)) {
                res.isSuccess = false;
                res.message = '추천 상품군은 RP 또는 회사채여야 합니다: "' + family + '"';
                continue;
            }
            String rationale = req.rationale == null ? null : req.rationale.trim();
            if (rationale != null && rationale.length() > 2000) {
                rationale = rationale.substring(0, 2000);
            }
            Lead toUpdate = new Lead(
                Id = req.leadId,
                Recommended_Product_Family__c = family,
                Recommended_Product_Rationale__c = rationale,
                // 종목이 안 오면 지운다 — 낡은 종목이 새 상품군과 모순되게 남지 않도록
                Recommended_Product__c = null,
                Recommended_Term_Days__c = null,
                Recommended_Fee_Rate__c = null
            );

            String productName = req.productName == null ? '' : req.productName.trim();
            if (String.isNotBlank(productName)) {
                Product2 product = productsByName.get(productName);
                if (product == null) {
                    res.isSuccess = false;
                    res.message = '활성 상품에서 종목을 찾지 못했습니다: "' + productName + '"';
                    continue;
                }
                String expectedFamily = PRODUCT_FAMILY_BY_LEAD_FAMILY.get(family);
                if (product.Family != expectedFamily) {
                    res.isSuccess = false;
                    res.message = '추천 상품군("' + family + '")과 종목의 상품군("'
                        + product.Family + '")이 맞지 않습니다: "' + productName + '"';
                    continue;
                }
                toUpdate.Recommended_Product__c = product.Id;
                toUpdate.Recommended_Term_Days__c =
                    req.termDays != null ? req.termDays : product.Min_Term_Days__c;
                toUpdate.Recommended_Fee_Rate__c =
                    req.feeRate != null ? req.feeRate : product.Default_Fee_Rate__c;
            }

            updates.add(toUpdate);
            updateIndexes.add(i);
        }

        if (updates.isEmpty()) {
            return responses;
        }

        List<Database.SaveResult> results = Database.update(updates, false, AccessLevel.USER_MODE);
        for (Integer u = 0; u < results.size(); u++) {
            Response res = responses[updateIndexes[u]];
            if (results[u].isSuccess()) {
                res.isSuccess = true;
                res.message = updates[u].Recommended_Product__c == null
                    ? '추천 상품군 "' + updates[u].Recommended_Product_Family__c + '" 을(를) 기록했습니다.'
                    : '추천 상품군 "' + updates[u].Recommended_Product_Family__c + '" 과 종목을 기록했습니다.';
            } else {
                res.isSuccess = false;
                List<String> msgs = new List<String>();
                for (Database.Error err : results[u].getErrors()) {
                    msgs.add(err.getMessage());
                }
                res.message = '기록 실패: ' + String.join(msgs, '; ');
            }
        }
        return responses;
    }

    /** 요청에 실린 종목명을 한 번에 조회한다. 벌크 호출에서도 SOQL 은 한 번이다. */
    private static Map<String, Product2> queryProducts(List<Request> requests) {
        Set<String> names = new Set<String>();
        for (Request req : requests) {
            if (req != null && String.isNotBlank(req.productName)) {
                names.add(req.productName.trim());
            }
        }
        Map<String, Product2> byName = new Map<String, Product2>();
        if (names.isEmpty()) {
            return byName;
        }
        for (Product2 product : [
            SELECT Id, Name, Family, Min_Term_Days__c, Default_Fee_Rate__c
            FROM Product2
            WHERE Name IN :names AND IsActive = true
            WITH USER_MODE
        ]) {
            byName.put(product.Name, product);
        }
        return byName;
    }
}