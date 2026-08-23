/**
 * 프롬프트 템플릿 "RP_Proposal_Message"(Flex) 의 grounding 용 Apex.
 *
 * Prompt Builder 에서 리소스로 추가하면 템플릿 본문의 {!$Apex:RPProposalCatalogProvider.Prompt} 자리에
 * 활성 상품(Product2, IsActive = true) 카탈로그가 텍스트로 주입된다.
 * 상품별로 상품명·패밀리·가입 자격 요건·기본 수수료율·기간(일) 을 한 블록씩 나열하고
 * RP(환매조건부채권) 상품을 맨 앞에 둔다 (15번 작업: RP 중심 제안).
 *
 * Flex 템플릿용 Apex 는 @InvocableMethod 에 CapabilityType 을 지정하지 않는다 (이 org 에서 FlexTemplate:// /
 * PromptTemplateType://einstein_gpt__flex 모두 "isn't available" 로 컴파일 거부됨 — 2026-08 확인).
 * Prompt Builder 는 Request 의 멤버 이름이 템플릿 입력(apiName) 과 일치하는 Invocable 클래스를 Apex 리소스로 노출한다.
 *   - 템플릿 입력: RelatedLead (Object: Lead)
 * 조회는 실행 사용자 권한(WITH USER_MODE) 으로 하며, 권한이 없거나 상품이 없으면
 * 예외 대신 안내 문구를 돌려줘서 프롬프트 자체는 항상 생성되게 한다.
 */
public with sharing class RPProposalCatalogProvider {

    @TestVisible private static final String RP_FAMILY_KEYWORD = 'RP';
    @TestVisible private static final String NO_PRODUCT_MESSAGE =
        '(현재 제안 가능한 활성 상품이 조회되지 않았습니다. 일반적인 법인 자금운용 상담 안내만 제공하세요.)';
    @TestVisible private static final String NO_ACCESS_MESSAGE =
        '(상품 카탈로그 조회 권한이 없어 상품 상세를 제공할 수 없습니다. 상품명·수수료·기간을 임의로 만들지 마세요.)';

    @InvocableMethod(
        label='RP 제안 프롬프트: 상품 카탈로그 grounding'
        description='활성 Product2 상품(가입 자격·수수료율·기간)을 텍스트로 묶어 RP_Proposal_Message 프롬프트 템플릿에 주입합니다.'
    )
    public static List<Response> getCatalog(List<Request> requests) {
        List<Response> responses = new List<Response>();
        if (requests == null || requests.isEmpty()) {
            return responses;
        }
        // 카탈로그는 요청(Lead)과 무관하게 동일하므로 한 번만 만든다.
        String catalogText = buildCatalogText();
        for (Request request : requests) {
            Response response = new Response();
            response.Prompt = catalogText;
            responses.add(response);
        }
        return responses;
    }

    /** 활성 상품을 조회해 프롬프트용 텍스트로 만든다. 권한 문제는 안내 문구로 대체. */
    @TestVisible
    private static String buildCatalogText() {
        List<Product2> products;
        try {
            products = [
                SELECT Id, Name, Family, Eligibility_Rule__c, Default_Fee_Rate__c,
                       Min_Term_Days__c, Max_Term_Days__c
                FROM Product2
                WHERE IsActive = true
                WITH USER_MODE
                ORDER BY Name
            ];
        } catch (QueryException e) {
            return NO_ACCESS_MESSAGE;
        }

        // 카탈로그 필드(자격·수수료·기간)가 전부 비어 있는 상품(샘플/배송비 상품 등)은 제안 근거가 없으므로 제외
        List<Product2> catalogProducts = new List<Product2>();
        for (Product2 product : products) {
            if (hasCatalogInfo(product)) {
                catalogProducts.add(product);
            }
        }
        products = catalogProducts;

        if (products.isEmpty()) {
            return NO_PRODUCT_MESSAGE;
        }

        List<String> blocks = new List<String>();
        // RP 상품을 맨 앞으로
        for (Product2 product : products) {
            if (isRpProduct(product)) {
                blocks.add(describeProduct(product, blocks.size() + 1));
            }
        }
        for (Product2 product : products) {
            if (!isRpProduct(product)) {
                blocks.add(describeProduct(product, blocks.size() + 1));
            }
        }
        return String.join(blocks, '\n\n');
    }

    /** 자격 요건·수수료율·기간 중 하나라도 있어야 카탈로그에 올린다. */
    private static Boolean hasCatalogInfo(Product2 product) {
        return String.isNotBlank(product.Eligibility_Rule__c)
            || product.Default_Fee_Rate__c != null
            || product.Min_Term_Days__c != null
            || product.Max_Term_Days__c != null;
    }

    private static Boolean isRpProduct(Product2 product) {
        String family = (product.Family ?? '').toUpperCase();
        String name = (product.Name ?? '').toUpperCase();
        return family.contains(RP_FAMILY_KEYWORD) || name.startsWith(RP_FAMILY_KEYWORD);
    }

    /** 상품 1건 → 여러 줄 텍스트. 값이 비어 있는 항목은 "정보 없음" 으로 명시해 LLM 이 지어내지 않게 한다. */
    private static String describeProduct(Product2 product, Integer index) {
        List<String> lines = new List<String>();
        lines.add('[상품 ' + index + '] ' + product.Name
            + (String.isNotBlank(product.Family) ? ' (분류: ' + product.Family + ')' : ''));
        lines.add('- 가입 자격 요건: ' + (String.isNotBlank(product.Eligibility_Rule__c) ? product.Eligibility_Rule__c : '정보 없음'));
        lines.add('- 기본 수수료율: ' + formatPercent(product.Default_Fee_Rate__c));
        lines.add('- 운용/가입 기간: ' + formatTerm(product.Min_Term_Days__c, product.Max_Term_Days__c));
        return String.join(lines, '\n');
    }

    private static String formatPercent(Decimal rate) {
        if (rate == null) {
            return '정보 없음';
        }
        return rate.setScale(2).toPlainString().replaceAll('\\.?0+$', '') + '%';
    }

    private static String formatTerm(Decimal minDays, Decimal maxDays) {
        if (minDays == null && maxDays == null) {
            return '정보 없음';
        }
        String minText = minDays == null ? '제한 없음' : minDays.intValue() + '일';
        String maxText = maxDays == null ? '제한 없음' : maxDays.intValue() + '일';
        return '최소 ' + minText + ' ~ 최대 ' + maxText;
    }

    /** 템플릿 입력과 동일한 이름/타입이어야 Prompt Builder 에서 이 클래스를 선택할 수 있다. */
    public class Request {
        @InvocableVariable(required=true label='RelatedLead' description='프롬프트 템플릿의 Lead 입력 (apiName: RelatedLead)')
        public Lead RelatedLead;
    }

    public class Response {
        @InvocableVariable(required=true label='Prompt' description='템플릿에 주입할 상품 카탈로그 텍스트')
        public String Prompt;
    }
}