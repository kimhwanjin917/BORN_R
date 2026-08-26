/**
 * 프롬프트 템플릿 "Meeting_Prep_Email_Draft"(Flex) 의 grounding 용 Apex.
 *
 * Prompt Builder 에서 리소스로 추가하면 템플릿 본문의 {!$Apex:MeetingPrepEmailProvider.Prompt} 자리에
 * 첫 접촉 이메일 초안의 근거(① 기업 브리핑 맥락 = 최신 연간 재무·최근 시그널, ② 추천 상품 카탈로그)가
 * 하나의 텍스트로 주입된다.
 *
 * [설계 - 배포 안정성]
 * MeetingPrepBriefingProvider / RPProposalCatalogProvider 와 같은 데이터를 근거로 쓰지만, 클래스 간 의존을
 * 만들지 않고 이 클래스가 자체 조회한다 (한 클래스만 배포해도 동작, 순환/컴파일 리스크 없음). grounding 패턴은
 * 세 provider 가 동일하다: WITH USER_MODE, flex(@InvocableMethod 에 CapabilityType 미지정), RelatedLead 입력.
 * 권한이 없거나 데이터가 없으면 예외 대신 안내 문구를 돌려줘 프롬프트는 항상 생성되게 한다.
 */
public with sharing class MeetingPrepEmailProvider {

    @TestVisible private static final String ANNUAL_PERIOD = '4분기';
    @TestVisible private static final String RP_FAMILY_KEYWORD = 'RP';
    @TestVisible private static final Integer MAX_SIGNALS = 3;
    @TestVisible private static final String NO_LEAD_MESSAGE =
        '(리드 정보가 전달되지 않았습니다. 제공된 정보 외의 근거를 만들어내지 마세요.)';
    @TestVisible private static final String NO_FINANCIAL_MESSAGE =
        '(이 리드에 연결된 재무제표·시그널 데이터가 없습니다. 재무 수치를 지어내지 말고 일반적인 첫 인사 메일로 작성하세요.)';
    @TestVisible private static final String NO_PRODUCT_MESSAGE =
        '(현재 제안 가능한 활성 상품이 조회되지 않았습니다. 특정 상품·수수료·기간을 만들어내지 말고 일반적인 자금운용 상담 제안만 하세요.)';
    @TestVisible private static final String NO_ACCESS_MESSAGE =
        '(근거 데이터 조회 권한이 없어 상세를 제공할 수 없습니다. 수치를 임의로 만들지 마세요.)';

    @InvocableMethod(
        label='미팅 준비 메일 초안: 브리핑·상품 grounding'
        description='주인공 리드의 재무·시그널 요약(브리핑 맥락)과 추천 상품 카탈로그를 텍스트로 묶어 Meeting_Prep_Email_Draft 프롬프트 템플릿에 주입합니다.'
    )
    public static List<Response> getEmailContext(List<Request> requests) {
        List<Response> responses = new List<Response>();
        if (requests == null || requests.isEmpty()) {
            return responses;
        }
        // 상품 카탈로그는 요청(Lead)과 무관하게 동일하므로 한 번만 만든다.
        String catalogText = buildCatalogText();
        for (Request request : requests) {
            Response response = new Response();
            response.Prompt = buildContextText(request == null ? null : request.RelatedLead, catalogText);
            responses.add(response);
        }
        return responses;
    }

    /** 브리핑 맥락(재무·시그널) + 상품 카탈로그를 하나의 텍스트로. */
    @TestVisible
    private static String buildContextText(Lead relatedLead, String catalogText) {
        if (relatedLead == null || relatedLead.Id == null) {
            return NO_LEAD_MESSAGE;
        }
        List<String> blocks = new List<String>();
        try {
            String briefingBlock = buildBriefingBlock(relatedLead.Id);
            blocks.add(briefingBlock == null ? NO_FINANCIAL_MESSAGE : briefingBlock);
        } catch (QueryException e) {
            blocks.add(NO_ACCESS_MESSAGE);
        }
        blocks.add(String.isBlank(catalogText) ? NO_PRODUCT_MESSAGE : catalogText);
        return String.join(blocks, '\n\n');
    }

    /** 최신 연간 재무 1건 + 최근 시그널 몇 건을 "브리핑 요약" 텍스트로. 둘 다 없으면 null. */
    private static String buildBriefingBlock(Id leadId) {
        List<String> lines = new List<String>();

        List<CorporateFinancialStatement__c> statements = [
            SELECT Fiscal_Year__c, Total_Assets__c, Total_Equity__c,
                   Cash_And_Equivalents__c, Short_Term_Financial_Instruments__c, Revenue__c
            FROM CorporateFinancialStatement__c
            WHERE Lead__c = :leadId AND Period_Type__c = :ANNUAL_PERIOD
            WITH USER_MODE
            ORDER BY Fiscal_Year__c DESC NULLS LAST
            LIMIT 1
        ];
        if (!statements.isEmpty()) {
            CorporateFinancialStatement__c cfs = statements[0];
            lines.add('[기업 브리핑 요약 - 최신 연간 재무]');
            String year = cfs.Fiscal_Year__c == null ? '' : ' (' + cfs.Fiscal_Year__c.intValue() + '년)';
            lines.add('- 재무' + year + ': 자산총계 ' + formatWon(cfs.Total_Assets__c)
                + ', 자본총계 ' + formatWon(cfs.Total_Equity__c)
                + ', 현금및현금성자산 ' + formatWon(cfs.Cash_And_Equivalents__c)
                + ', 단기금융상품 ' + formatWon(cfs.Short_Term_Financial_Instruments__c)
                + ', 매출액 ' + formatWon(cfs.Revenue__c));
        }

        List<ExternalSignal__c> signals = [
            SELECT Signal_Type__c, Signal_Date__c, Title__c
            FROM ExternalSignal__c
            WHERE Lead__c = :leadId
            WITH USER_MODE
            ORDER BY Signal_Date__c DESC NULLS LAST
            LIMIT :MAX_SIGNALS
        ];
        if (!signals.isEmpty()) {
            if (lines.isEmpty()) {
                lines.add('[기업 브리핑 요약]');
            }
            lines.add('- 최근 시그널:');
            for (ExternalSignal__c signal : signals) {
                String dateText = signal.Signal_Date__c == null ? '일자 미상' : String.valueOf(signal.Signal_Date__c);
                String typeText = String.isBlank(signal.Signal_Type__c) ? '기타' : signal.Signal_Type__c;
                String titleText = String.isBlank(signal.Title__c) ? '(제목 없음)' : signal.Title__c;
                lines.add('  · ' + dateText + ' [' + typeText + '] ' + titleText);
            }
        }

        return lines.isEmpty() ? null : String.join(lines, '\n');
    }

    /** 활성 상품 카탈로그를 프롬프트용 텍스트로. RP 상품을 맨 앞에. 권한/데이터 문제는 빈 문자열로 (호출부에서 안내). */
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
            return null;
        }

        List<Product2> catalogProducts = new List<Product2>();
        for (Product2 product : products) {
            if (hasCatalogInfo(product)) {
                catalogProducts.add(product);
            }
        }
        if (catalogProducts.isEmpty()) {
            return null;
        }

        List<String> blocks = new List<String>();
        blocks.add('[추천 상품 카탈로그 - 활성 상품만. 이 외의 상품·수수료·기간을 만들어내지 말 것]');
        for (Product2 product : catalogProducts) {
            if (isRpProduct(product)) {
                blocks.add(describeProduct(product, blocks.size()));
            }
        }
        for (Product2 product : catalogProducts) {
            if (!isRpProduct(product)) {
                blocks.add(describeProduct(product, blocks.size()));
            }
        }
        return String.join(blocks, '\n');
    }

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

    private static String formatWon(Decimal amount) {
        if (amount == null) {
            return '정보 없음';
        }
        Decimal inEok = (amount / 100000000L).setScale(1);
        return inEok.toPlainString().replaceAll('\\.0$', '') + '억 원';
    }

    /** 템플릿 입력과 동일한 이름/타입이어야 Prompt Builder 에서 이 클래스를 선택할 수 있다. */
    public class Request {
        @InvocableVariable(required=true label='RelatedLead' description='프롬프트 템플릿의 Lead 입력 (apiName: RelatedLead)')
        public Lead RelatedLead;
    }

    public class Response {
        @InvocableVariable(required=true label='Prompt' description='템플릿에 주입할 브리핑·상품 근거 텍스트')
        public String Prompt;
    }
}