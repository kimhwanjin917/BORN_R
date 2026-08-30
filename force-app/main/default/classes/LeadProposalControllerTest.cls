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

        Product2 opportunityProduct = [SELECT Id FROM Product2 WHERE Name = 'RP 91일물' LIMIT 1];
        Account opportunityAccount = new Account(
            Name = '기회기업', Industry = '제조업', Business_Registration_Number__c = '1234567890'
        );
        insert opportunityAccount;
        Contact opportunityContact = new Contact(
            LastName = '담당자', AccountId = opportunityAccount.Id,
            Email = 'contact@example.com', name_new__c = '담당자'
        );
        insert opportunityContact;
        insert new Opportunity(
            Name = '기회기업 - RP', AccountId = opportunityAccount.Id,
            StageName = '미팅', CloseDate = Date.today().addDays(30),
            Primary_Product__c = opportunityProduct.Id, ContactId = opportunityContact.Id
        );

        insert new List<CorporateFinancialStatement__c>{
            // 운용 가능 자금 1,500억 · 단기차입금 100억 → 기간형 + 회사채
            statement(leads[0].Id, 2026, '11012', 1200 * EOK, 300 * EOK, 100 * EOK),
            // 직전 분기(2026/03) — 최신 것만 쓰는지 확인하기 위한 미끼
            statement(leads[0].Id, 2026, '11013', 10 * EOK, 0, 0),
            // 단기차입금(200억) > 현금(100억) → 초단기
            statement(leads[1].Id, 2026, '11012', 100 * EOK, 0, 200 * EOK),
            statementForAccount(opportunityAccount.Id, 2026, '11012', 800 * EOK, 100 * EOK, 0)
        };
    }

    @IsTest
    static void opportunityContextUsesAccountAndPrimaryProduct() {
        Opportunity opp = opportunityByName('기회기업 - RP');

        Test.startTest();
        LeadProposalController.Context ctx = LeadProposalController.getContext(opp.Id);
        Test.stopTest();

        System.Assert.areEqual('기회기업', ctx.company, 'Opportunity 계정명이 제안서 고객사로 보여야 한다');
        System.Assert.areEqual('제조업', ctx.industry, 'Opportunity 계정 업종을 사용해야 한다');
        System.Assert.areEqual('담당자님', ctx.recipient, 'Opportunity 제목이 아니라 고객사 담당자명이 수신인으로 보여야 한다');
        System.Assert.isTrue(ctx.hasFinancials, 'Opportunity 계정의 재무자료를 읽어야 한다');
        System.Assert.areEqual(new Set<String>{ 'RP 91일물' }, recommendedNames(ctx),
            'Opportunity 기준 상품이 추천 상품으로 표시돼야 한다');
    }

    @IsTest
    static void generateSavesFileOnOpportunity() {
        Opportunity opp = opportunityByName('기회기업 - RP');
        List<LeadProposalController.Selection> selections = selectionsFor(
            new Map<String, Decimal>{ 'RP 91일물' => 3.20 });

        Test.startTest();
        LeadProposalController.GenerateResult result =
            LeadProposalController.generateFor(opp.Id, selections, '기회 기준 제안', 100 * EOK);
        Test.stopTest();

        System.Assert.isNotNull(result.contentDocumentId, 'Opportunity에도 제안서 파일이 만들어져야 한다');
        System.Assert.isTrue(
            [SELECT COUNT() FROM ContentDocumentLink
             WHERE ContentDocumentId = :result.contentDocumentId AND LinkedEntityId = :opp.Id] > 0,
            '생성 파일이 Opportunity에 연결돼야 한다'
        );
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
    static void enginePopulatesWhenNothingStored() {
        Id leadId = leadIdByCompany('넉넉기업');

        Test.startTest();
        LeadProposalController.Context ctx = LeadProposalController.getContext(leadId);
        Test.stopTest();

        // 저장된 추천이 없으면 엔진이 재무 기준으로 계산해 채운다. 브리핑도 같은 필드를 읽으므로
        // 어느 화면을 먼저 열든 같은 추천이 보인다.
        System.Assert.isTrue(ctx.hasFinancials, '사전 조건: 재무 자료는 있다');
        System.Assert.isTrue(ctx.hasAgentRecommendation, '엔진이 채워야 한다');
        System.Assert.areEqual(1, recommendedNames(ctx).size(),
            '대표 종목 하나가 체크돼야 한다: ' + recommendedNames(ctx));
        System.Assert.isTrue(ctx.rationale.contains('억원'), ctx.rationale);
    }

    @IsTest
    static void fillsProductWhenOnlyFamilyStored() {
        Id leadId = leadIdByCompany('넉넉기업');
        storeRecommendation(leadId, '회사채', null, null, null, '중기 운용 여력 있음');

        Test.startTest();
        LeadProposalController.Context ctx = LeadProposalController.getContext(leadId);
        Test.stopTest();

        // 상품군만 정해져 있으면 엔진이 그 상품군을 존중하고 종목·기간·요율만 채운다
        System.Assert.isTrue(ctx.hasAgentRecommendation, '종목이 채워져야 한다');
        System.Assert.areEqual('회사채', ctx.recommendedFamily, '에이전트가 정한 상품군을 바꾸지 않는다');
        System.Assert.areEqual(1, recommendedNames(ctx).size());
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
            LeadProposalController.generateFor(leadId, selections, '지난주 통화 내용 반영', 100 * EOK);
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
            LeadProposalController.generateFor(leadId, selections, null, null);
        LeadProposalController.GenerateResult second =
            LeadProposalController.generateFor(leadId, selections, null, null);
        Test.stopTest();

        System.Assert.isFalse(first.docNumber.contains('-R'), '첫 발행에는 접미가 없다: ' + first.docNumber);
        System.Assert.areEqual(first.docNumber + '-R2', second.docNumber,
            '재발행은 -R2 가 붙어야 한다: ' + second.docNumber);
    }

    @IsTest
    static void generateRejectsEmptySelection() {
        Id leadId = leadIdByCompany('넉넉기업');
        Boolean thrownForList = false;
        Boolean thrownForEmptyJson = false;
        Boolean thrownForBlankJson = false;

        Test.startTest();
        try {
            LeadProposalController.generateFor(leadId, new List<LeadProposalController.Selection>(), null, null);
        } catch (AuraHandledException e) {
            thrownForList = true;
        }
        try {
            LeadProposalController.generate(leadId, '[]', null, null);
        } catch (AuraHandledException e) {
            thrownForEmptyJson = true;
        }
        try {
            LeadProposalController.generate(leadId, null, null, null);
        } catch (AuraHandledException e) {
            thrownForBlankJson = true;
        }
        Test.stopTest();

        System.Assert.isTrue(thrownForList, '상품 없이 생성되면 안 된다');
        System.Assert.isTrue(thrownForEmptyJson, '빈 배열 JSON 도 거부해야 한다');
        System.Assert.isTrue(thrownForBlankJson, 'selectionsJson 이 비면 거부해야 한다');
    }

    // ─── 화면(LWC) → Apex payload 회귀 테스트 ───────────────────────────
    //
    // 여기가 실제로 깨졌던 구간이다. Selection 을 Apex 안에서 new 해서 넘기는 테스트는
    // 이 경로를 타지 않아, 화면에서만 productId·yieldRate 가 null 로 도착하는 버그를 못 잡았다.
    // 아래 JSON 은 leadProposalGenerator.js 의 handleGenerate() 가 보내는 형태 그대로다.

    @IsTest
    static void generateReadsSelectionsSentByTheScreen() {
        Id leadId = leadIdByCompany('넉넉기업');
        Product2 p = [SELECT Id, Name FROM Product2 WHERE Name = 'RP 91일물' LIMIT 1];
        String payload = JSON.serialize(new List<Map<String, Object>>{
            new Map<String, Object>{ 'productId' => String.valueOf(p.Id), 'yieldRate' => 3.20 }
        });

        Test.startTest();
        LeadProposalController.GenerateResult result =
            LeadProposalController.generate(leadId, payload, '화면에서 보낸 그대로', 100 * EOK);
        Test.stopTest();

        System.Assert.isNotNull(result.contentDocumentId, '화면이 보낸 형태로도 PDF 가 만들어져야 한다');

        Lead saved = [
            SELECT Proposed_Product__r.Name, Proposed_Yield_Rate__c FROM Lead WHERE Id = :leadId
        ];
        System.Assert.areEqual('RP 91일물', saved.Proposed_Product__r.Name,
            'productId 가 유실되면 안 된다 — 이것이 원래 버그다');
        System.Assert.areEqual(3.20, saved.Proposed_Yield_Rate__c,
            'yieldRate 가 유실되면 안 된다 — 이것이 원래 버그다');
    }

    @IsTest
    static void generateRejectsSelectionWithoutProductId() {
        Id leadId = leadIdByCompany('넉넉기업');
        // 값이 빠진 채로 도착하는 상황(원래 버그의 증상)에서는 파일을 만들지 않고 막아야 한다
        Boolean thrown = false;

        Test.startTest();
        try {
            LeadProposalController.generate(leadId, '[{"productId":null,"yieldRate":null}]', null, null);
        } catch (AuraHandledException e) {
            thrown = true;
        }
        Test.stopTest();

        System.Assert.isTrue(thrown, 'productId 가 비면 막아야 한다');
        System.Assert.areEqual(0, filesOn(leadId), '막힌 요청은 파일을 남기지 않아야 한다');
        System.Assert.isFalse(LeadProposalController.MALFORMED_SELECTION.contains('진단'),
            '사용자에게 나가는 문구에 내부 진단 표식이 남아 있으면 안 된다');
    }

    @IsTest
    static void generateRejectsMalformedJson() {
        Id leadId = leadIdByCompany('넉넉기업');
        Boolean thrown = false;

        Test.startTest();
        try {
            LeadProposalController.generate(leadId, '이건 JSON 이 아니다', null, null);
        } catch (AuraHandledException e) {
            thrown = true;
        }
        Test.stopTest();

        System.Assert.isTrue(thrown, '깨진 payload 는 막아야 한다');
        System.Assert.areEqual(0, filesOn(leadId), '막힌 요청은 파일을 남기지 않아야 한다');
    }

    private static Integer filesOn(Id leadId) {
        return [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :leadId];
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
        Product2 p = [SELECT Id, Name, Min_Term_Days__c, Max_Term_Days__c FROM Product2 WHERE Name = 'RP 91일물'];

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
            SELECT Id, Name, Min_Term_Days__c, Max_Term_Days__c
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
            SELECT Id, Fiscal_Year__c, External_Key__c, Period_Type__c,
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
        Product2 threeYear = [SELECT Id, Name, Min_Term_Days__c, Max_Term_Days__c FROM Product2 WHERE Name = '회사채 - 삼성전자 3년물 (AAA)'];
        Product2 ninetyOne = [SELECT Id, Name, Min_Term_Days__c, Max_Term_Days__c FROM Product2 WHERE Name = 'RP 91일물'];
        Product2 demand = [SELECT Id, Name, Min_Term_Days__c, Max_Term_Days__c FROM Product2 WHERE Name = 'RP 수시형 (약정기간 없음)'];

        System.Assert.areEqual('3년', LeadProposalController.termText(threeYear), '1095일보다 3년이 읽기 쉽다');
        System.Assert.areEqual('91일', LeadProposalController.termText(ninetyOne), '연으로 안 떨어지면 일로 적는다');
        System.Assert.areEqual('수시', LeadProposalController.termText(demand), '약정기간이 없으면 수시다');
    }

    @IsTest
    static void reportTypeLabelUsesStableSourceFields() {
        System.Assert.areEqual('1분기보고서', LeadProposalController.reportTypeLabel('DART-11013', null),
            'DART 보고서 코드로 분기 보고서를 계산해야 한다');
        System.Assert.areEqual('2분기보고서', LeadProposalController.reportTypeLabel(null, '2분기'),
            '보고서 코드가 없으면 기간 구분으로 계산해야 한다');
        System.Assert.areEqual('--', LeadProposalController.reportTypeLabel(null, null),
            '원천 필드가 없으면 알 수 없음 표기를 반환해야 한다');
    }

    @IsTest
    static void disclosurePeriodUsesStableSourceFields() {
        System.Assert.areEqual('2026/06', LeadProposalController.disclosurePeriod(2026, 'DART-11012', null),
            '2분기 공시 기간을 원천 코드로 계산해야 한다');
        System.Assert.areEqual('2026/09', LeadProposalController.disclosurePeriod(2026, null, '3분기'),
            '보고서 코드가 없으면 기간 구분으로 계산해야 한다');
        System.Assert.areEqual('2026', LeadProposalController.disclosurePeriod(2026, null, null),
            '월을 알 수 없으면 회계연도만 반환해야 한다');
    }

    @IsTest
    static void approxTextUsesJoForLargeAmounts() {
        System.Assert.areEqual('약 1,192억원', LeadProposalController.approxText(119174190760L), '억 단위 반올림');
        System.Assert.areEqual('약 2.2조원', LeadProposalController.approxText(2178342331935L), '1조를 넘으면 조 단위');
        System.Assert.areEqual('', LeadProposalController.approxText(0), '0 은 병기하지 않는다');
    }

    @IsTest
    static void noteIsDerivedFromFamilyAndTerm() {
        Product2 bond = [SELECT Id, Name, Min_Term_Days__c, Max_Term_Days__c FROM Product2 WHERE Name = '회사채 - 삼성전자 3년물 (AAA)'];
        Product2 longRp = [SELECT Id, Name, Min_Term_Days__c, Max_Term_Days__c FROM Product2 WHERE Name = 'RP 91일물'];
        Product2 shortRp = [SELECT Id, Name, Min_Term_Days__c, Max_Term_Days__c FROM Product2 WHERE Name = 'RP 7일물'];

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

    private static Opportunity opportunityByName(String name) {
        return [
            SELECT Id, Name, AccountId, Account.Name, Account.Industry, Owner.Name,
                   Primary_Product__c, Primary_Product__r.Name, Product_Family__c, RP_Yield__c
            FROM Opportunity WHERE Name = :name LIMIT 1
        ];
    }

    private static Product2 product(String name, String family, Integer minDays, Integer maxDays, Decimal fee) {
        return new Product2(
            Name = name, IsActive = true,
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

    private static CorporateFinancialStatement__c statementForAccount(
        Id accountId, Decimal fiscalYear, String reportCode, Decimal cash, Decimal stfi, Decimal shortDebt
    ) {
        return new CorporateFinancialStatement__c(
            Account__c = accountId,
            Fiscal_Year__c = fiscalYear,
            External_Key__c = 'TEST-ACCOUNT-' + accountId + '-' + reportCode,
            Cash_And_Equivalents__c = cash,
            Short_Term_Financial_Instruments__c = stfi,
            Short_Term_Borrowings__c = shortDebt
        );
    }

    // ─── 제안 조건이 리드에 남는가 ──────────────────────────────────────

    @IsTest
    static void generateRecordsProposedTermsOnLead() {
        Id leadId = leadIdByCompany('넉넉기업');
        storeRecommendation(leadId, 'RP', 'RP 91일물', 91, 0.15, '단기 여유자금');

        Test.startTest();
        LeadProposalController.generateFor(
            leadId, selectionsFor(new Map<String, Decimal>{ 'RP 91일물' => 3.20 }), null, 100 * EOK);
        Test.stopTest();

        Lead saved = [
            SELECT Proposed_Product__r.Name, Proposed_Term_Days__c, Proposed_Yield_Rate__c
            FROM Lead WHERE Id = :leadId
        ];
        System.Assert.areEqual('RP 91일물', saved.Proposed_Product__r.Name, '제안한 상품이 남아야 한다');
        System.Assert.areEqual(91, saved.Proposed_Term_Days__c, '제안한 기간이 남아야 한다');
        System.Assert.areEqual(3.20, saved.Proposed_Yield_Rate__c,
            '지금까지 PDF 안에만 있던 수익률이 필드로 남아야 한다');
    }

    @IsTest
    static void recordsAgentProductWhenRmAddsMore() {
        Id leadId = leadIdByCompany('넉넉기업');
        storeRecommendation(leadId, 'RP', 'RP 91일물', 91, 0.15, '단기 여유자금');

        // RM 이 추천 외 상품을 더 담아도 대표는 에이전트 추천 상품이어야 한다
        Test.startTest();
        LeadProposalController.generateFor(
            leadId,
            selectionsFor(new Map<String, Decimal>{ 'RP 30일물' => 3.05, 'RP 91일물' => 3.20 }),
            null, null);
        Test.stopTest();

        Lead saved = [SELECT Proposed_Product__r.Name, Proposed_Yield_Rate__c FROM Lead WHERE Id = :leadId];
        System.Assert.areEqual('RP 91일물', saved.Proposed_Product__r.Name,
            '선택 순서와 무관하게 에이전트 추천 상품이 대표다');
        System.Assert.areEqual(3.20, saved.Proposed_Yield_Rate__c);
    }

    @IsTest
    static void recordsFirstSelectionWhenNoAgentRecommendation() {
        Id leadId = leadIdByCompany('넉넉기업');

        Test.startTest();
        LeadProposalController.generateFor(
            leadId, selectionsFor(new Map<String, Decimal>{ 'RP 30일물' => 3.05 }), null, null);
        Test.stopTest();

        Lead saved = [SELECT Proposed_Product__r.Name, Proposed_Yield_Rate__c FROM Lead WHERE Id = :leadId];
        System.Assert.areEqual('RP 30일물', saved.Proposed_Product__r.Name,
            '추천이 없으면 RM 이 고른 것을 그대로 남긴다');
        System.Assert.areEqual(3.05, saved.Proposed_Yield_Rate__c);
    }
}