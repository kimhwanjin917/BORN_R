/**
 * 리드 상품 제안서 — LWC(leadProposalGenerator) 용 컨트롤러.
 *
 * 흐름: getContext() 로 리드·재무·추천상품을 화면에 올리고, RM 이 상품과 수익률을 확정한 뒤
 * generate() 가 PDF 를 렌더링해 리드의 파일(ContentVersion)로 저장한다.
 *
 * 순서가 중요하다: LeadProposalPdfController.render() 는 getContentAsPDF() 를 부르는데 이것이 콜아웃
 * 취급이라, 같은 트랜잭션에서 DML 뒤에 부르면 "uncommitted work pending" 이 난다.
 * 따라서 반드시 (1) 렌더링 → (2) 파일 DML 순서를 지킨다.
 *
 * 수수료율은 고객용 PDF 에 싣지 않는다 — RP 는 약정수익률에 당사 마진이 이미 반영된 구조라
 * 수수료를 따로 적으면 이중 차감으로 읽힌다. 대신 화면(RM)에는 그대로 내려보낸다.
 *
 * 추천은 이 클래스가 판정하지 않는다. 에이전트가 판정해 Lead 에 저장한 값(Recommended_Product__c ·
 * Recommended_Term_Days__c · Recommended_Fee_Rate__c · Recommended_Product_Family__c ·
 * Recommended_Product_Rationale__c)을 그대로 읽는다. 미팅 준비 브리핑도 같은 값을 읽으므로 둘이 어긋나지 않는다.
 * 재무로 자체 판정하던 예전 방식은 걷어냈다 — 브리핑과 다른 답이 나오는 원인이었다.
 * 저장된 추천이 없으면 추천하지 않고 RM 이 직접 고르게 한다. 여기서 몰래 추정하면 다시 어긋난다.
 */
public with sharing class LeadProposalController {

    private static final String DOC_PREFIX = 'BS-PRP';
    /** 문서번호 식별자용 32진 문자. 혼동되는 0·1·I·O 는 뺐다. */
    private static final String ID_ALPHABET = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
    private static final String HEX_DIGITS = '0123456789abcdef';
    /** 법인 이자소득 원천징수세율. 변경 시 PDF 유의사항 문구도 함께 고쳐야 한다. */
    private static final Decimal WITHHOLDING_RATE = 0.14;
    /** 약정기간이 없는 상품의 수익 시뮬레이션 기준일수. */
    private static final Integer DEMAND_SIM_DAYS = 30;
    @TestVisible
    private static final String NO_AGENT_RECOMMENDATION =
        '이 리드에는 저장된 에이전트 추천이 없습니다. 미팅 준비 브리핑에서 상품 추천을 먼저 받으면 같은 종목이 여기에도 표시됩니다. 지금은 제안할 상품을 직접 선택해 주세요.';
    private static final Decimal ONE_EOK = 100000000;
    private static final Decimal ONE_JO = 1000000000000L;
    /** 준법감시인 심의필 표기. 심의 완료 후 실제 번호로 교체한다. */
    private static final String COMPLIANCE_REVIEW_TEXT = '준법감시인 심의필 제0000-0000호 (심의 전 초안)';

    // ─── 화면에 내려보내는 형태 ────────────────────────────────────────

    public class Context {
        @AuraEnabled public String leadName;
        @AuraEnabled public String company;
        @AuraEnabled public String recipient;
        @AuraEnabled public String ownerName;
        @AuraEnabled public String industry;

        @AuraEnabled public Boolean hasFinancials = false;
        @AuraEnabled public String finReportLabel;
        @AuraEnabled public String finPeriodYm;
        @AuraEnabled public Decimal cash;
        @AuraEnabled public Decimal shortTermInstruments;
        @AuraEnabled public Decimal shortTermBorrowings;
        @AuraEnabled public Decimal liquidTotal;
        @AuraEnabled public String liquidTotalText;

        /** 에이전트가 저장한 추천이 있는지. 없으면 화면에서 직접 고르라고 안내한다. */
        @AuraEnabled public Boolean hasAgentRecommendation = false;
        @AuraEnabled public String recommendedFamily;
        @AuraEnabled public Decimal recommendedTermDays;
        @AuraEnabled public Decimal recommendedFeeRate;

        /** 에이전트가 남긴 추천 근거 — 화면에만 보이고 PDF 에는 들어가지 않는다. */
        @AuraEnabled public String rationale;
        @AuraEnabled public List<CatalogItem> catalog = new List<CatalogItem>();
    }

    public class CatalogItem {
        @AuraEnabled public Id productId;
        @AuraEnabled public String name;
        @AuraEnabled public String family;
        @AuraEnabled public String termText;
        @AuraEnabled public Integer termDays;
        @AuraEnabled public Decimal feeRate;
        @AuraEnabled public String eligibility;
        @AuraEnabled public String note;
        @AuraEnabled public Boolean recommended = false;
    }

    public class Selection {
        @AuraEnabled public Id productId;
        @AuraEnabled public Decimal yieldRate;
    }

    public class GenerateResult {
        @AuraEnabled public String docNumber;
        @AuraEnabled public String fileName;
        @AuraEnabled public Id contentDocumentId;
        @AuraEnabled public Id contentVersionId;
    }

    // ─── 1. 화면 진입 ──────────────────────────────────────────────────

    @AuraEnabled(cacheable=false)
    public static Context getContext(Id leadId) {
        try {
            Lead ld = queryLead(leadId);
            Context ctx = new Context();
            ctx.leadName = ld.Name;
            ctx.company = ld.Company;
            ctx.recipient = buildRecipient(ld);
            ctx.ownerName = ld.Owner.Name;
            ctx.industry = nz(ld.Industry);

            CorporateFinancialStatement__c fs = latestStatement(leadId);
            if (fs != null) {
                ctx.hasFinancials = true;
                ctx.finReportLabel = buildReportLabel(fs);
                ctx.finPeriodYm = nz(fs.Disclosure_Period_YM__c);
                ctx.cash = zero(fs.Cash_And_Equivalents__c);
                ctx.shortTermInstruments = zero(fs.Short_Term_Financial_Instruments__c);
                ctx.shortTermBorrowings = zero(fs.Short_Term_Borrowings__c);
                ctx.liquidTotal = ctx.cash + ctx.shortTermInstruments;
                ctx.liquidTotalText = approxText(ctx.liquidTotal);
            }

            ctx.catalog = buildCatalog();
            ctx.rationale = applyStoredRecommendation(ctx, ld);
            return ctx;
        } catch (Exception e) {
            throw new AuraHandledException('제안서 화면을 여는 중 오류가 발생했습니다: ' + e.getMessage());
        }
    }

    // ─── 2. PDF 생성 ───────────────────────────────────────────────────

    @AuraEnabled(cacheable=false)
    public static GenerateResult generate(Id leadId, List<Selection> selections, String backgroundMemo, Decimal assumedAmount) {
        if (selections == null || selections.isEmpty()) {
            throw new AuraHandledException('제안할 상품을 하나 이상 선택해 주세요.');
        }
        try {
            Lead ld = queryLead(leadId);
            CorporateFinancialStatement__c fs = latestStatement(leadId);
            String docNumber = nextDocNumber(leadId);

            LeadProposalPdfController.ProposalDoc doc =
                buildDoc(ld, fs, selections, backgroundMemo, assumedAmount, docNumber);

            // (1) 렌더링 먼저 — DML 보다 앞이어야 한다
            Blob pdf = LeadProposalPdfController.render(doc);

            // (2) 파일 저장
            String fileName = docNumber + '_제안서_' + nz(ld.Company) + '.pdf';
            ContentVersion cv = new ContentVersion(
                Title = fileName.removeEnd('.pdf'),
                PathOnClient = fileName,
                VersionData = pdf,
                FirstPublishLocationId = leadId
            );
            insert as user cv;

            GenerateResult result = new GenerateResult();
            result.docNumber = docNumber;
            result.fileName = fileName;
            result.contentVersionId = cv.Id;
            result.contentDocumentId = [
                SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id WITH USER_MODE LIMIT 1
            ].ContentDocumentId;
            return result;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('제안서 생성 중 오류가 발생했습니다: ' + e.getMessage());
        }
    }

    // ─── 문서 조립 ─────────────────────────────────────────────────────

    @TestVisible
    private static LeadProposalPdfController.ProposalDoc buildDoc(
        Lead ld, CorporateFinancialStatement__c fs, List<Selection> selections,
        String backgroundMemo, Decimal assumedAmount, String docNumber
    ) {
        LeadProposalPdfController.ProposalDoc doc = new LeadProposalPdfController.ProposalDoc();
        doc.docNumber = docNumber;
        doc.createdDateText = Datetime.now().format('yyyy년 M월 d일', 'Asia/Seoul');
        doc.companyName = nz(ld.Company);
        doc.industry = nz(ld.Industry);
        doc.recipient = buildRecipient(ld);
        doc.ownerName = ld.Owner.Name + ' (법인영업본부)';
        doc.complianceReviewText = COMPLIANCE_REVIEW_TEXT;

        // 제안 배경 — 비어 있으면 블록째 감춘다 (빈 상자가 찍히면 성의 없어 보인다)
        if (String.isNotBlank(backgroundMemo)) {
            doc.hasMemo = true;
            doc.backgroundMemo = backgroundMemo.trim().abbreviate(1500);
        }

        // 공시 재무 — 원문 인용만 한다. 합산 여유자금 같은 파생 추정치는 넣지 않는다
        if (fs != null && fs.Cash_And_Equivalents__c != null) {
            doc.hasFinancials = true;
            doc.finReportLabel = buildReportLabel(fs);
            doc.finPeriodYm = nz(fs.Disclosure_Period_YM__c);
            doc.cashText = wonText(fs.Cash_And_Equivalents__c);
            doc.cashUnit = approxText(fs.Cash_And_Equivalents__c);
            if (fs.Short_Term_Financial_Instruments__c != null && fs.Short_Term_Financial_Instruments__c > 0) {
                doc.hasStfi = true;
                doc.stfiText = wonText(fs.Short_Term_Financial_Instruments__c);
                doc.stfiUnit = approxText(fs.Short_Term_Financial_Instruments__c);
            }
        }

        Map<Id, Product2> productById = new Map<Id, Product2>(queryProducts(selectionIds(selections)));
        Boolean simulate = assumedAmount != null && assumedAmount > 0;
        if (simulate) {
            doc.assumedAmountText = approxText(assumedAmount).removeStart('약 ');
        }

        for (Selection sel : selections) {
            Product2 p = productById.get(sel.productId);
            if (p == null) {
                continue;
            }
            Integer days = termDays(p);
            String termLabel = termText(p);
            // 에이전트가 이 종목에 기간을 따로 정해뒀으면 상품 기본값 대신 그 값을 쓴다
            if (p.Id == ld.Recommended_Product__c && ld.Recommended_Term_Days__c != null) {
                days = Integer.valueOf(ld.Recommended_Term_Days__c);
                termLabel = dayText(days);
            }

            LeadProposalPdfController.ProductRow row = new LeadProposalPdfController.ProductRow();
            row.name = p.Name;
            row.family = nz(p.Family);
            row.term = termLabel;
            row.yieldText = sel.yieldRate == null ? '미정' : pct(sel.yieldRate);
            row.note = noteFor(p, days);
            doc.products.add(row);

            if (simulate && sel.yieldRate != null && days != null) {
                doc.simulations.add(buildSimulation(p, sel.yieldRate, days, assumedAmount, termLabel));
            }
        }
        doc.hasSimulation = !doc.simulations.isEmpty();
        return doc;
    }

    @TestVisible
    private static LeadProposalPdfController.SimRow buildSimulation(
        Product2 p, Decimal yieldRate, Integer days, Decimal amount, String termLabel
    ) {
        Integer simDays = isDemandType(p) ? DEMAND_SIM_DAYS : days;
        Decimal gross = (amount * (yieldRate / 100) * simDays / 365).setScale(0, System.RoundingMode.HALF_UP);
        Decimal tax = (gross * WITHHOLDING_RATE).setScale(0, System.RoundingMode.HALF_UP);

        LeadProposalPdfController.SimRow sim = new LeadProposalPdfController.SimRow();
        sim.name = p.Name;
        sim.term = isDemandType(p) ? DEMAND_SIM_DAYS + '일 기준' : termLabel;
        sim.grossText = gross.format();
        sim.taxText = '-' + tax.format();
        sim.netText = (gross - tax).format();
        return sim;
    }

    // ─── 상품 카탈로그와 추천 ──────────────────────────────────────────

    @TestVisible
    private static List<CatalogItem> buildCatalog() {
        List<CatalogItem> items = new List<CatalogItem>();
        for (Product2 p : queryProducts(null)) {
            // 자격·수수료·기간이 전부 비어 있는 상품(배송비 상품 등)은 제안 근거가 없으므로 제외한다
            if (p.Eligibility_Rule__c == null && p.Default_Fee_Rate__c == null && p.Min_Term_Days__c == null) {
                continue;
            }
            CatalogItem item = new CatalogItem();
            item.productId = p.Id;
            item.name = p.Name;
            item.family = nz(p.Family);
            item.termDays = termDays(p);
            item.termText = termText(p);
            item.feeRate = p.Default_Fee_Rate__c;
            item.eligibility = nz(p.Eligibility_Rule__c);
            item.note = noteFor(p, item.termDays);
            items.add(item);
        }
        return items;
    }

    /**
     * 에이전트가 Lead 에 저장한 추천을 그대로 읽어 카탈로그에 표시한다. 판정은 하지 않는다.
     * 미팅 준비 브리핑도 같은 필드를 읽으므로 두 화면의 추천이 어긋날 수 없다.
     * 저장된 추천이 없으면 아무것도 고르지 않고 안내 문구만 돌려준다.
     */
    @TestVisible
    private static String applyStoredRecommendation(Context ctx, Lead ld) {
        ctx.recommendedFamily = ld.Recommended_Product_Family__c;
        ctx.recommendedTermDays = ld.Recommended_Term_Days__c;
        ctx.recommendedFeeRate = ld.Recommended_Fee_Rate__c;

        if (ld.Recommended_Product__c == null) {
            return String.isBlank(ld.Recommended_Product_Rationale__c)
                ? NO_AGENT_RECOMMENDATION
                : ld.Recommended_Product_Rationale__c + '\n\n(상품군까지만 정해져 있어 종목은 직접 선택해 주세요.)';
        }

        ctx.hasAgentRecommendation = true;
        for (CatalogItem item : ctx.catalog) {
            if (item.productId != ld.Recommended_Product__c) {
                continue;
            }
            item.recommended = true;
            // 에이전트가 상품 기본값과 다른 기간·요율을 정했으면 그쪽을 보여준다
            if (ld.Recommended_Term_Days__c != null) {
                item.termDays = Integer.valueOf(ld.Recommended_Term_Days__c);
            }
            if (ld.Recommended_Fee_Rate__c != null) {
                item.feeRate = ld.Recommended_Fee_Rate__c;
            }
        }
        return String.isBlank(ld.Recommended_Product_Rationale__c)
            ? '에이전트가 ' + ld.Recommended_Product__r.Name + ' 을(를) 추천했습니다.'
            : ld.Recommended_Product_Rationale__c;
    }

    // ─── 문서번호 ──────────────────────────────────────────────────────

    /**
     * BS-PRP-{yyyyMMdd}-{리드 식별자 4자}. 식별자는 리드 Id 에서 결정적으로 만들기 때문에
     * 채번 테이블이 없어도 동시 생성 시 충돌하지 않는다. 같은 리드에 같은 날 다시 뽑으면 -R2, -R3 이 붙는다.
     */
    @TestVisible
    private static String nextDocNumber(Id leadId) {
        String base = DOC_PREFIX + '-' + Datetime.now().format('yyyyMMdd', 'Asia/Seoul') + '-' + leadToken(leadId);
        String pattern = base + '%';
        Integer issued = [SELECT COUNT() FROM ContentVersion WHERE Title LIKE :pattern AND IsLatest = true WITH USER_MODE];
        return issued == 0 ? base : base + '-R' + String.valueOf(issued + 1);
    }

    @TestVisible
    private static String leadToken(Id leadId) {
        Blob digest = Crypto.generateDigest('SHA-256', Blob.valueOf(String.valueOf(leadId)));
        String hex = EncodingUtil.convertToHex(digest);
        String token = '';
        for (Integer i = 0; i < 4; i++) {
            // Apex 의 Integer.valueOf 는 진법 인자를 받지 않아 16진수를 직접 푼다
            Integer high = HEX_DIGITS.indexOf(hex.substring(i * 2, i * 2 + 1));
            Integer low = HEX_DIGITS.indexOf(hex.substring(i * 2 + 1, i * 2 + 2));
            Integer slot = Math.mod(high * 16 + low, 32);
            token += ID_ALPHABET.substring(slot, slot + 1);
        }
        return token;
    }

    // ─── 조회 ──────────────────────────────────────────────────────────

    private static Lead queryLead(Id leadId) {
        List<Lead> rows = [
            SELECT Id, Name, Company, Title, Department__c, Industry, Owner.Name,
                   Recommended_Product_Family__c, Recommended_Product_Rationale__c,
                   Recommended_Product__c, Recommended_Product__r.Name,
                   Recommended_Term_Days__c, Recommended_Fee_Rate__c
            FROM Lead WHERE Id = :leadId WITH USER_MODE LIMIT 1
        ];
        if (rows.isEmpty()) {
            throw new AuraHandledException('리드를 찾을 수 없거나 조회 권한이 없습니다.');
        }
        return rows[0];
    }

    private static CorporateFinancialStatement__c latestStatement(Id leadId) {
        List<CorporateFinancialStatement__c> rows = [
            SELECT Id, Report_Type_Label__c, Fiscal_Year_Text__c, Disclosure_Period_YM__c, Period_Type__c,
                   Cash_And_Equivalents__c, Short_Term_Financial_Instruments__c,
                   Short_Term_Borrowings__c, Bonds_Payable__c, Long_Term_Borrowings__c
            FROM CorporateFinancialStatement__c
            WHERE Lead__c = :leadId
            WITH USER_MODE
            ORDER BY Disclosure_Period_YM__c DESC NULLS LAST
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    private static List<Product2> queryProducts(Set<Id> productIds) {
        if (productIds == null) {
            return [
                SELECT Id, Name, Family, Eligibility_Rule__c, Default_Fee_Rate__c, Min_Term_Days__c, Max_Term_Days__c
                FROM Product2 WHERE IsActive = true WITH USER_MODE ORDER BY Family, Min_Term_Days__c, Name
            ];
        }
        return [
            SELECT Id, Name, Family, Eligibility_Rule__c, Default_Fee_Rate__c, Min_Term_Days__c, Max_Term_Days__c
            FROM Product2 WHERE Id IN :productIds WITH USER_MODE
        ];
    }

    private static Set<Id> selectionIds(List<Selection> selections) {
        Set<Id> ids = new Set<Id>();
        for (Selection sel : selections) {
            if (sel.productId != null) {
                ids.add(sel.productId);
            }
        }
        return ids;
    }

    // ─── 서식 ──────────────────────────────────────────────────────────

    /** 약정기간이 사실상 없는 상품 (수시형). 최대 기간이 10년으로 잡혀 있는 것이 이 카탈로그의 표기 방식이다. */
    @TestVisible
    private static Boolean isDemandType(Product2 p) {
        return p.Max_Term_Days__c != null && p.Max_Term_Days__c >= 3650;
    }

    @TestVisible
    private static Integer termDays(Product2 p) {
        if (p.Min_Term_Days__c == null) {
            return null;
        }
        return Integer.valueOf(p.Min_Term_Days__c);
    }

    /** 730일보다 '2년'이 읽기 쉽다. 연 단위로 딱 떨어지면 연으로 바꾼다. */
    @TestVisible
    private static String termText(Product2 p) {
        if (isDemandType(p)) {
            return '수시';
        }
        if (p.Min_Term_Days__c == null) {
            return '-';
        }
        Integer minDays = Integer.valueOf(p.Min_Term_Days__c);
        Integer maxDays = p.Max_Term_Days__c == null ? minDays : Integer.valueOf(p.Max_Term_Days__c);
        return minDays == maxDays ? dayText(minDays) : dayText(minDays) + '~' + dayText(maxDays);
    }

    @TestVisible
    private static String dayText(Integer days) {
        return days >= 365 && Math.mod(days, 365) == 0 ? (days / 365) + '년' : days + '일';
    }

    /** 비고란. 상품에 따로 저장된 문구가 없으므로 상품군과 기간에서 만든다. */
    @TestVisible
    private static String noteFor(Product2 p, Integer days) {
        if (p.Family == '채권') {
            return '만기 보유 시 표면금리 수령';
        }
        if (isDemandType(p)) {
            return '수시 입출금';
        }
        if (p.Family == 'RP') {
            return days != null && days >= 90 ? '만기 자동 재예치 가능' : '단기 회전 운용';
        }
        return '';
    }

    private static String wonText(Decimal amount) {
        return amount.setScale(0, System.RoundingMode.HALF_UP).format() + ' 원';
    }

    /** 1,191억 · 2.2조 처럼 읽기 쉬운 단위로 병기한다. 단위 환산일 뿐 추정치가 아니다. */
    @TestVisible
    private static String approxText(Decimal amount) {
        if (amount == null || amount == 0) {
            return '';
        }
        if (amount >= ONE_JO) {
            return '약 ' + (amount / ONE_JO).setScale(1, System.RoundingMode.HALF_UP) + '조원';
        }
        return '약 ' + (amount / ONE_EOK).setScale(0, System.RoundingMode.HALF_UP).format() + '억원';
    }

    private static String buildReportLabel(CorporateFinancialStatement__c fs) {
        String year = nz(fs.Fiscal_Year_Text__c);
        String report = nz(fs.Report_Type_Label__c);
        return String.isBlank(year) ? report : year + '년 ' + report;
    }

    private static String buildRecipient(Lead ld) {
        List<String> parts = new List<String>();
        if (String.isNotBlank(ld.Department__c)) {
            parts.add(ld.Department__c);
        }
        String person = ld.Name + (String.isBlank(ld.Title) ? '' : ' ' + ld.Title);
        parts.add(person + '님');
        return String.join(parts, ' ');
    }

    /** 금융 문서라 3.2% 보다 3.20% 가 맞다. 소수점 두 자리를 항상 유지한다. */
    @TestVisible
    private static String pct(Decimal d) {
        return d.setScale(2, System.RoundingMode.HALF_UP).toPlainString() + '%';
    }

    private static Decimal zero(Decimal d) { return d == null ? 0 : d; }
    private static String nz(String s) { return s == null ? '' : s; }
}