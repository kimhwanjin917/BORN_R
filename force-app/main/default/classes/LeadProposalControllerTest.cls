/**
 * 팀 공용 TestDataFactory 는 건드리지 않고 이 클래스 안에서 @TestSetup 으로 데이터를 만든다.
 * Lead 에 Email_Required 검증 규칙이 걸려 있어 리드에는 반드시 Email 이 있어야 한다.
 */
@IsTest
private class LeadProposalControllerTest {

    private static final Decimal EOK = 100000000;

    @TestSetup
    static void setup() {
        insert new List<Product2>{
            product('RP 7일물', 'RP', 7, 7, 0.10),
            product('RP 30일물', 'RP', 30, 30, 0.15),
            product('RP 91일물', 'RP', 91, 91, 0.15),
            product('RP 180일물', 'RP', 180, 180, 0.18),
            product('RP 수시형 (약정기간 없음)', 'RP', 1, 3650, 0.10),
            product('회사채 - 삼성전자 3년물 (AAA)', '채권', 1095, 1095, 0.20),
            product('회사채 - 한화솔루션 2년물 (A+)', '채권', 730, 730, 0.35),
            emptyProduct('배송비 상품')
        };

        List<Lead> leads = new List<Lead>{
            lead('여유', '넉넉기업'), lead('빠듯', '차입기업'), lead('무자료', '자료없는기업')
        };
        insert leads;

        insert new List<CorporateFinancialStatement__c>{
            // 운용 가능 자금 1,500억 · 단기차입금 100억 → 기간형 + 회사채
            statement(leads[0].Id, 2026, '11012', 1200 * EOK, 300 * EOK, 100 * EOK),
            // 직전 분기(2026/03) — 최신 것만 쓰는지 확인하기 위한 미끼
            statement(leads[0].Id, 2026, '11013', 10 * EOK, 0, 0),
            // 단기차입금(200억) > 현금(100억) → 초단기
            statement(leads[1].Id, 2026, '11012', 100 * EOK, 0, 200 * EOK)
        };
    }

    // ─── getContext: 저장된 에이전트 추천을 읽는다 ──────────────────────

    private static void storeRecommendation(Id leadId, String family, String productName, Decimal termDays, Decimal feeRate, String rationale) {
        Product2 p = productName == null ? null : [SELECT Id FROM Product2 WHERE Name = :productName LIMIT 1];
        update new Lead(
            Id = leadId,
            Recommended_Product_Family__c = family,
            Recommended_Product__c = p == null ? null : p.Id,
            Recommended_Term_Days__c = termDays,
            Recommended_Fee_Rate__c = feeRate,
            Recommended_Product_Rationale__c = rationale
        );
    }

    @IsTest
    static void marksStoredProductAsRecommended() {
        Id leadId = leadIdByCompany('넉넉기업');
        storeRecommendation(leadId, 'RP', 'RP 91일물', 91, 0.15, '현금 1,500억 · 차입 부담 낮음');

        Test.startTest();
        LeadProposalController.Context ctx = LeadProposalController.getContext(leadId);
        Test.stopTest();

        System.Assert.isTrue(ctx.hasAgentRecommendation, '저장된 추천이 있으면 true');
        System.Assert.areEqual(new Set<String>{ 'RP 91일물' }, recommendedNames(ctx),
            '저장된 종목 하나만 체크돼야 한다: ' + recommendedNames(ctx));
        System.Assert.areEqual('현금 1,500억 · 차입 부담 낮음', ctx.rationale,
            '근거는 에이전트가 남긴 것을 그대로 보여준다');
        System.Assert.areEqual('RP', ctx.recommendedFamily);
    }

    @IsTest
    static void doesNotJudgeWhenNothingStored() {
        Id leadId = leadIdByCompany('넉넉기업');

        Test.startTest();
        LeadProposalController.Context ctx = LeadProposalController.getContext(leadId);
        Test.stopTest();

        // 재무 자료는 넉넉하지만(현금 1,200억) 저장된 추천이 없으므로 스스로 판정하면 안 된다
        System.Assert.isTrue(ctx.hasFinancials, '사전 조건: 재무 자료는 있다');
        System.Assert.isFalse(ctx.hasAgentRecommendation);
        System.Assert.areEqual(0, recommendedNames(ctx).size(),
            '재무가 넉넉해도 스스로 추천하면 브리핑과 어긋난다: ' + recommendedNames(ctx));
        System.Assert.isTrue(ctx.rationale.contains('직접 선택'), ctx.rationale);
    }

    @IsTest
    static void asksForProductWhenOnlyFamilyStored() {
        Id leadId = leadIdByCompany('넉넉기업');
        storeRecommendation(leadId, '회사채', null, null, null, '중기 운용 여력 있음');

        Test.startTest();
        LeadProposalController.Context ctx = LeadProposalController.getContext(leadId);
        Test.stopTest();

        System.Assert.isFalse(ctx.hasAgentRecommendation, '종목이 없으면 완전한 추천이 아니다');
        System.Assert.areEqual(0, recommendedNames(ctx).size());
        System.Assert.areEqual('회사채', ctx.recommendedFamily, '상품군은 화면에 내려준다');
        System.Assert.isTrue(ctx.rationale.contains('중기 운용 여력 있음'), '근거는 살려둔다');
        System.Assert.isTrue(ctx.rationale.contains('직접 선택'), '종목은 직접 고르라고 안내한다');
    }

    @IsTest
    static void agentTermAndFeeOverrideProductDefaults() {
        Id leadId = leadIdByCompany('넉넉기업');
        // 상품 기본값은 91일 / 0.15% 인데 에이전트가 45일 / 0.12% 로 정한 경우
        storeRecommendation(leadId, 'RP', 'RP 91일물', 45, 0.12, '자금 소요 일정에 맞춤');

        Test.startTest();
        LeadProposalController.Context ctx = LeadProposalController.getContext(leadId);
        Test.stopTest();

        for (LeadProposalController.CatalogItem item : ctx.catalog) {
            if (item.name == 'RP 91일물') {
                System.Assert.areEqual(45, item.termDays, '에이전트가 정한 기간이 상품 기본값을 이긴다');
                System.Assert.areEqual(0.12, item.feeRate, '에이전트가 정한 요율이 상품 기본값을 이긴다');
            }
        }
        System.Assert.areEqual(45, ctx.recommendedTermDays);
        System.Assert.areEqual(0.12, ctx.recommendedFeeRate);
    }

    @IsTest
    static void catalogExcludesProductsWithNoBasis() {
        Test.startTest();
        LeadProposalController.Context ctx = LeadProposalController.getContext(leadIdByCompany('넉넉기업'));
        Test.stopTest();

        for (LeadProposalController.CatalogItem item : ctx.catalog) {
            System.Assert.areNotEqual('배송비 상품', item.name,
                '자격·수수료·기간이 모두 빈 상품은 제안 근거가 없어 빼야 한다');
        }
    }

    // ─── generate ──────────────────────────────────────────────────────

    @IsTest
    static void generateSavesFileOnLead() {
        Id leadId = leadIdByCompany('넉넉기업');
        List<LeadProposalController.Selection> selections = selectionsFor(
            new Map<String, Decimal>{ 'RP 91일물' => 3.20, 'RP 30일물' => 3.05 });

        Test.startTest();
        LeadProposalController.GenerateResult result =
            LeadProposalController.generate(leadId, selections, '지난주 통화 내용 반영', 100 * EOK);
        Test.stopTest();

        System.Assert.isNotNull(result.contentDocumentId, 'ContentDocument 가 만들어져야 한다');
        System.Assert.isTrue(result.docNumber.startsWith('BS-PRP-'), '문서번호 접두어: ' + result.docNumber);
        System.Assert.isTrue(result.fileName.endsWith('.pdf'), '파일명: ' + result.fileName);
        System.Assert.isTrue(result.fileName.contains('넉넉기업'), '파일명에 고객사가 들어가야 한다: ' + result.fileName);

        List<ContentDocumentLink> links = [
            SELECT LinkedEntityId FROM ContentDocumentLink WHERE ContentDocumentId = :result.contentDocumentId
        ];
        Set<Id> linked = new Set<Id>();
        for (ContentDocumentLink link : links) {
            linked.add(link.LinkedEntityId);
        }
        System.Assert.isTrue(linked.contains(leadId), '파일이 리드에 연결돼야 한다');
    }

    @IsTest
    static void reissueOnSameDayGetsSuffix() {
        Id leadId = leadIdByCompany('넉넉기업');
        List<LeadProposalController.Selection> selections =
            selectionsFor(new Map<String, Decimal>{ 'RP 91일물' => 3.20 });

        Test.startTest();
        LeadProposalController.GenerateResult first =
            LeadProposalController.generate(leadId, selections, null, null);
        LeadProposalController.GenerateResult second =
            LeadProposalController.generate(leadId, selections, null, null);
        Test.stopTest();

        System.Assert.isFalse(first.docNumber.contains('-R'), '첫 발행에는 접미가 없다: ' + first.docNumber);
        System.Assert.areEqual(first.docNumber + '-R2', second.docNumber,
            '재발행은 -R2 가 붙어야 한다: ' + second.docNumber);
    }

    @IsTest
    static void generateRejectsEmptySelection() {
        Id leadId = leadIdByCompany('넉넉기업');
        Boolean thrown = false;

        Test.startTest();
        try {
            LeadProposalController.generate(leadId, new List<LeadProposalController.Selection>(), null, null);
        } catch (AuraHandledException e) {
            thrown = true;
        }
        Test.stopTest();

        System.Assert.isTrue(thrown, '상품 없이 생성되면 안 된다');
    }

    @IsTest
    static void leadTokenIsStablePerLeadAndUnique() {
        Id a = leadIdByCompany('넉넉기업');
        Id b = leadIdByCompany('차입기업');

        String tokenA = LeadProposalController.leadToken(a);
        String tokenB = LeadProposalController.leadToken(b);

        System.Assert.areEqual(4, tokenA.length(), '식별자는 4자다: ' + tokenA);
        System.Assert.areEqual(tokenA, LeadProposalController.leadToken(a), '같은 리드면 항상 같아야 한다');
        System.Assert.areNotEqual(tokenA, tokenB, '리드가 다르면 달라야 한다');
        System.Assert.isFalse(tokenA.contains('0') || tokenA.contains('1')
            || tokenA.contains('I') || tokenA.contains('O'), '혼동되는 문자는 빼야 한다: ' + tokenA);
    }

    // ─── 문서 조립 ─────────────────────────────────────────────────────

    @IsTest
    static void simulationComputesGrossTaxAndNet() {
        Product2 p = [SELECT Id, Name, Family, Min_Term_Days__c, Max_Term_Days__c FROM Product2 WHERE Name = 'RP 91일물'];

        LeadProposalPdfController.SimRow sim =
            LeadProposalController.buildSimulation(p, 3.20, 91, 100 * EOK, '91일');

        // 100억 × 3.20% × 91/365 = 79,780,822 원, 원천징수 14% = 11,169,315 원
        System.Assert.areEqual('79,780,822', sim.grossText, '세전 예상수익');
        System.Assert.areEqual('-11,169,315', sim.taxText, '원천징수는 차감 표기한다');
        System.Assert.areEqual('68,611,507', sim.netText, '세후 수령액');
    }

    @IsTest
    static void demandTypeSimulatesOnBaselineDays() {
        Product2 p = [
            SELECT Id, Name, Family, Min_Term_Days__c, Max_Term_Days__c
            FROM Product2 WHERE Name = 'RP 수시형 (약정기간 없음)'
        ];

        LeadProposalPdfController.SimRow sim =
            LeadProposalController.buildSimulation(p, 2.60, 1, 100 * EOK, '수시');

        System.Assert.areEqual('30일 기준', sim.term, '약정기간이 없으므로 기준일수를 밝혀야 한다');
        System.Assert.areEqual('21,369,863', sim.grossText, '1일이 아니라 30일 기준으로 계산해야 한다');
    }

    @IsTest
    static void omitsSimulationWhenNoAmount() {
        Lead ld = leadByCompany('넉넉기업');
        List<LeadProposalController.Selection> selections =
            selectionsFor(new Map<String, Decimal>{ 'RP 91일물' => 3.20 });

        LeadProposalPdfController.ProposalDoc doc =
            LeadProposalController.buildDoc(ld, null, selections, null, null, 'BS-PRP-20260827-TEST');

        System.Assert.isFalse(doc.hasSimulation, '예치 금액이 없으면 비교표를 빼야 한다');
        System.Assert.isFalse(doc.hasMemo, '제안 배경이 없으면 블록을 빼야 한다');
        System.Assert.isFalse(doc.hasFinancials, '재무 자료가 없으면 블록을 빼야 한다');
        System.Assert.areEqual(1, doc.products.size(), '상품 표는 남아 있어야 한다');
        System.Assert.areEqual('3.20%', doc.products[0].yieldText, '수익률은 소수점 두 자리로 적는다');
    }

    @IsTest
    static void omitsShortTermInstrumentsWhenZero() {
        Lead ld = leadByCompany('차입기업');
        CorporateFinancialStatement__c fs = [
            SELECT Id, Report_Type_Label__c, Fiscal_Year_Text__c, Disclosure_Period_YM__c,
                   Cash_And_Equivalents__c, Short_Term_Financial_Instruments__c, Short_Term_Borrowings__c
            FROM CorporateFinancialStatement__c WHERE Lead__c = :ld.Id LIMIT 1
        ];

        LeadProposalPdfController.ProposalDoc doc = LeadProposalController.buildDoc(
            ld, fs, selectionsFor(new Map<String, Decimal>{ 'RP 7일물' => 2.90 }), null, null, 'BS-PRP-20260827-TEST');

        System.Assert.isTrue(doc.hasFinancials, '현금은 있으니 재무 블록은 나온다');
        System.Assert.isFalse(doc.hasStfi, '값이 0 이면 그 줄은 빼야 한다');
        System.Assert.areEqual('약 100억원', doc.cashUnit, '억 단위를 병기한다');
    }

    // ─── 서식 ──────────────────────────────────────────────────────────

    @IsTest
    static void termTextUsesYearsWhenDivisible() {
        Product2 threeYear = [SELECT Id, Name, Family, Min_Term_Days__c, Max_Term_Days__c FROM Product2 WHERE Name = '회사채 - 삼성전자 3년물 (AAA)'];
        Product2 ninetyOne = [SELECT Id, Name, Family, Min_Term_Days__c, Max_Term_Days__c FROM Product2 WHERE Name = 'RP 91일물'];
        Product2 demand = [SELECT Id, Name, Family, Min_Term_Days__c, Max_Term_Days__c FROM Product2 WHERE Name = 'RP 수시형 (약정기간 없음)'];

        System.Assert.areEqual('3년', LeadProposalController.termText(threeYear), '1095일보다 3년이 읽기 쉽다');
        System.Assert.areEqual('91일', LeadProposalController.termText(ninetyOne), '연으로 안 떨어지면 일로 적는다');
        System.Assert.areEqual('수시', LeadProposalController.termText(demand), '약정기간이 없으면 수시다');
    }

    @IsTest
    static void approxTextUsesJoForLargeAmounts() {
        System.Assert.areEqual('약 1,192억원', LeadProposalController.approxText(119174190760L), '억 단위 반올림');
        System.Assert.areEqual('약 2.2조원', LeadProposalController.approxText(2178342331935L), '1조를 넘으면 조 단위');
        System.Assert.areEqual('', LeadProposalController.approxText(0), '0 은 병기하지 않는다');
    }

    @IsTest
    static void noteIsDerivedFromFamilyAndTerm() {
        Product2 bond = [SELECT Id, Name, Family, Min_Term_Days__c, Max_Term_Days__c FROM Product2 WHERE Name = '회사채 - 삼성전자 3년물 (AAA)'];
        Product2 longRp = [SELECT Id, Name, Family, Min_Term_Days__c, Max_Term_Days__c FROM Product2 WHERE Name = 'RP 91일물'];
        Product2 shortRp = [SELECT Id, Name, Family, Min_Term_Days__c, Max_Term_Days__c FROM Product2 WHERE Name = 'RP 7일물'];

        System.Assert.areEqual('만기 보유 시 표면금리 수령', LeadProposalController.noteFor(bond, 1095));
        System.Assert.areEqual('만기 자동 재예치 가능', LeadProposalController.noteFor(longRp, 91));
        System.Assert.areEqual('단기 회전 운용', LeadProposalController.noteFor(shortRp, 7));
    }

    // ─── 도우미 ────────────────────────────────────────────────────────

    private static Set<String> recommendedNames(LeadProposalController.Context ctx) {
        Set<String> names = new Set<String>();
        for (LeadProposalController.CatalogItem item : ctx.catalog) {
            if (item.recommended) {
                names.add(item.name);
            }
        }
        return names;
    }

    private static List<LeadProposalController.Selection> selectionsFor(Map<String, Decimal> yieldByName) {
        List<LeadProposalController.Selection> selections = new List<LeadProposalController.Selection>();
        for (Product2 p : [SELECT Id, Name FROM Product2 WHERE Name IN :yieldByName.keySet()]) {
            LeadProposalController.Selection sel = new LeadProposalController.Selection();
            sel.productId = p.Id;
            sel.yieldRate = yieldByName.get(p.Name);
            selections.add(sel);
        }
        return selections;
    }

    private static Lead leadByCompany(String company) {
        return [
            SELECT Id, Name, Company, Title, Department__c, Industry, Owner.Name,
                   Recommended_Product_Family__c, Recommended_Product_Rationale__c,
                   Recommended_Product__c, Recommended_Product__r.Name,
                   Recommended_Term_Days__c, Recommended_Fee_Rate__c
            FROM Lead WHERE Company = :company LIMIT 1
        ];
    }

    private static Id leadIdByCompany(String company) {
        return leadByCompany(company).Id;
    }

    private static Product2 product(String name, String family, Integer minDays, Integer maxDays, Decimal fee) {
        return new Product2(
            Name = name, Family = family, IsActive = true,
            Min_Term_Days__c = minDays, Max_Term_Days__c = maxDays,
            Default_Fee_Rate__c = fee, Eligibility_Rule__c = '법인 대상'
        );
    }

    private static Product2 emptyProduct(String name) {
        return new Product2(Name = name, IsActive = true);
    }

    private static Lead lead(String lastName, String company) {
        // name_new__c 는 이 org 에서 필수다 (Lead_Sync_LastName 플로우가 쓰는 이름 필드)
        return new Lead(
            LastName = lastName, name_new__c = lastName, Company = company, Email = 'proposal.test@example.com',
            Title = '과장', Department__c = '경영관리팀', Industry = '제조업', Status = '신규'
        );
    }

    /**
     * Disclosure_Period_YM__c · Report_Type_Label__c · Fiscal_Year_Text__c 는 전부 수식 필드다.
     * 직접 넣을 수 없으므로 회계연도와 External_Key__c 의 DART 보고서 코드(뒤 5자리)로 유도시킨다.
     * 11013=1분기 · 11012=2분기 · 11014=3분기 · 11011=사업보고서
     */
    private static CorporateFinancialStatement__c statement(
        Id leadId, Decimal fiscalYear, String reportCode, Decimal cash, Decimal stfi, Decimal shortDebt
    ) {
        return new CorporateFinancialStatement__c(
            Lead__c = leadId,
            Fiscal_Year__c = fiscalYear,
            External_Key__c = 'TEST-' + leadId + '-' + reportCode,
            Cash_And_Equivalents__c = cash,
            Short_Term_Financial_Instruments__c = stfi,
            Short_Term_Borrowings__c = shortDebt
        );
    }
}