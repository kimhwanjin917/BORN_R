/**
 * RPProposalCatalogProvider 테스트.
 * 테스트 데이터는 @TestSetup 에서 직접 만든다 (팀 공용 TestDataFactory 는 동결 파일이라 사용하지 않음).
 */
@IsTest
private class RPProposalCatalogProviderTest {

    private static final String RP_PRODUCT_NAME = 'RP (환매조건부채권)';
    private static final String BOND_PRODUCT_NAME = '회사채';
    private static final String PENSION_PRODUCT_NAME = '퇴직연금';
    private static final String INACTIVE_PRODUCT_NAME = '단종상품';
    private static final String EMPTY_PRODUCT_NAME = '빈값상품';
    private static final String NO_INFO_PRODUCT_NAME = 'Shipping Charge Product';
    private static final String SETUP_MARKER = 'RPCatalogProviderTest';

    @TestSetup
    static void setupProducts() {
        insert new List<Product2>{
            new Product2(Name = BOND_PRODUCT_NAME, Family = '채권', IsActive = true, ProductCode = SETUP_MARKER + '-1',
                Eligibility_Rule__c = '신용등급 BBB 이상 법인', Default_Fee_Rate__c = 0.3,
                Min_Term_Days__c = 90, Max_Term_Days__c = 1095),
            new Product2(Name = RP_PRODUCT_NAME, Family = 'RP', IsActive = true, ProductCode = SETUP_MARKER + '-2',
                Eligibility_Rule__c = '법인 대상, 최소 예치금 1억원 이상', Default_Fee_Rate__c = 0.15,
                Min_Term_Days__c = 1, Max_Term_Days__c = 90),
            new Product2(Name = PENSION_PRODUCT_NAME, Family = '퇴직연금', IsActive = true, ProductCode = SETUP_MARKER + '-3',
                Eligibility_Rule__c = '상시근로자 1인 이상 법인', Default_Fee_Rate__c = 0.5,
                Min_Term_Days__c = 365, Max_Term_Days__c = 3650),
            new Product2(Name = INACTIVE_PRODUCT_NAME, Family = '채권', IsActive = false, ProductCode = SETUP_MARKER + '-4',
                Eligibility_Rule__c = '비활성', Default_Fee_Rate__c = 9, Min_Term_Days__c = 1, Max_Term_Days__c = 2),
            // 자격 요건만 있고 수수료·기간은 비어 있는 상품 → "정보 없음" 표기 검증용
            new Product2(Name = EMPTY_PRODUCT_NAME, IsActive = true, ProductCode = SETUP_MARKER + '-5',
                Eligibility_Rule__c = '자격만 있음'),
            // 카탈로그 필드가 전부 비어 있는 활성 상품(예: 샘플 배송비 상품) → 카탈로그에서 제외되어야 함
            new Product2(Name = NO_INFO_PRODUCT_NAME, IsActive = true, ProductCode = SETUP_MARKER + '-6')
        };
    }

    @IsTest
    static void shouldReturnCatalogWithRpFirst_AndOnlyActiveProducts() {
        // Given
        RPProposalCatalogProvider.Request request = new RPProposalCatalogProvider.Request();
        request.RelatedLead = new Lead(LastName = '고객', Company = '테스트법인');

        // When
        Test.startTest();
        List<RPProposalCatalogProvider.Response> responses =
            RPProposalCatalogProvider.getCatalog(new List<RPProposalCatalogProvider.Request>{ request });
        Test.stopTest();

        // Then
        Assert.areEqual(1, responses.size(), '요청 1건당 응답 1건');
        String prompt = responses[0].Prompt;
        Assert.isTrue(prompt.contains(RP_PRODUCT_NAME), 'RP 상품 포함');
        Assert.isTrue(prompt.contains(BOND_PRODUCT_NAME), '회사채 포함');
        Assert.isTrue(prompt.contains(PENSION_PRODUCT_NAME), '퇴직연금 포함');
        Assert.isFalse(prompt.contains(INACTIVE_PRODUCT_NAME), '비활성 상품 제외');
        Assert.isFalse(prompt.contains(NO_INFO_PRODUCT_NAME), '카탈로그 필드가 전부 빈 상품 제외. 실제: ' + prompt);
        Assert.isTrue(prompt.startsWith('[상품 1] ' + RP_PRODUCT_NAME), 'RP 상품이 맨 앞. 실제: ' + prompt.substringBefore('\n'));
        Assert.isTrue(prompt.contains('- 기본 수수료율: 0.15%'), '수수료율 포맷(불필요한 0 제거). 실제: ' + prompt);
        Assert.isTrue(prompt.contains('- 운용/가입 기간: 최소 1일 ~ 최대 90일'), '기간 포맷. 실제: ' + prompt);
        Assert.isTrue(prompt.contains('- 가입 자격 요건: 법인 대상, 최소 예치금 1억원 이상'), '자격 요건 포함');
    }

    @IsTest
    static void shouldMarkMissingValuesAsUnknown_WhenProductFieldsAreEmpty() {
        // When
        String prompt = RPProposalCatalogProvider.buildCatalogText();

        // Then
        Integer emptyBlockStart = prompt.indexOf('] ' + EMPTY_PRODUCT_NAME);
        Assert.isTrue(emptyBlockStart > -1, '빈값 상품 블록 존재');
        String emptyBlock = prompt.substring(emptyBlockStart).substringBefore('\n\n');
        Assert.isTrue(emptyBlock.contains('- 가입 자격 요건: 자격만 있음'), '자격요건은 값 표시. 실제: ' + emptyBlock);
        Assert.isTrue(emptyBlock.contains('- 기본 수수료율: 정보 없음'), '빈 수수료율은 정보 없음. 실제: ' + emptyBlock);
        Assert.isTrue(emptyBlock.contains('- 운용/가입 기간: 정보 없음'), '빈 기간은 정보 없음. 실제: ' + emptyBlock);
    }

    @IsTest
    static void shouldReturnOneResponsePerRequest_WhenBulkRequests() {
        // Given
        List<RPProposalCatalogProvider.Request> requests = new List<RPProposalCatalogProvider.Request>();
        for (Integer i = 0; i < 5; i++) {
            RPProposalCatalogProvider.Request request = new RPProposalCatalogProvider.Request();
            request.RelatedLead = new Lead(LastName = '고객' + i, Company = '법인' + i);
            requests.add(request);
        }

        // When
        List<RPProposalCatalogProvider.Response> responses = RPProposalCatalogProvider.getCatalog(requests);

        // Then
        Assert.areEqual(5, responses.size(), '요청 수만큼 응답');
        Assert.areEqual(responses[0].Prompt, responses[4].Prompt, '카탈로그는 요청과 무관하게 동일');
    }

    @IsTest
    static void shouldReturnEmptyList_WhenNoRequests() {
        Assert.isTrue(RPProposalCatalogProvider.getCatalog(null).isEmpty(), 'null 요청 → 빈 응답');
        Assert.isTrue(RPProposalCatalogProvider.getCatalog(new List<RPProposalCatalogProvider.Request>()).isEmpty(), '빈 요청 → 빈 응답');
    }

    @IsTest
    static void shouldReturnNoProductMessage_WhenNoActiveProducts() {
        // Given: 이 테스트에서 만든 상품을 전부 비활성화 (org 기존 상품은 테스트 격리로 보이지 않음)
        List<Product2> products = [SELECT Id FROM Product2 WHERE IsActive = true];
        for (Product2 product : products) {
            product.IsActive = false;
        }
        update products;

        // When
        String prompt = RPProposalCatalogProvider.buildCatalogText();

        // Then
        Assert.areEqual(RPProposalCatalogProvider.NO_PRODUCT_MESSAGE, prompt, '활성 상품 없음 안내');
    }
}