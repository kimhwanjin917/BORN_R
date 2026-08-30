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
    private static final String MALFORMED_SELECTION =
        '선택한 상품 정보를 읽지 못했습니다. 화면을 새로 고친 뒤(Cmd+Shift+R) 다시 시도해 주세요.';
    @TestVisible
    private static final String NO_AGENT_RECOMMENDATION =
        '이 레코드에는 저장된 상품 추천이 없습니다. 지금은 제안할 상품을 직접 선택해 주세요.';
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
        // Id 타입으로 두면 LWC 로 내려갈 때 값이 유실된다(Selection.productId 와 같은 이유).
        @AuraEnabled public String productId;
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
        // Id 로 선언하면 LWC 가 보낸 JSON 을 역직렬화할 때 값이 버려져 null 이 된다(플랫폼 동작).
        // String 으로 받고 쓸 때 캐스팅한다.
        @AuraEnabled public String productId;
        @AuraEnabled public Decimal yieldRate;
    }

    public class GenerateResult {
        @AuraEnabled public String docNumber;
        @AuraEnabled public String fileName;
        @AuraEnabled public String contentDocumentId;
        @AuraEnabled public String contentVersionId;
    }

    /**
     * The action is available on both Lead and Opportunity. Keep the common
     * proposal inputs in one small view model so the PDF and catalog logic do
     * not need to know which record page launched the action.
     */
    private class ProposalData {
        Id recordId;
        Id leadId;
        Id accountId;
        String recordName;
        String company;
        String title;
        String department;
        String industry;
        String ownerName;
        String customerContactName;
        Id recommendedProductId;
        String recommendedProductName;
        String recommendedFamily;
        String recommendationRationale;
        Decimal recommendedTermDays;
        Decimal recommendedFeeRate;
    }

    // ─── 1. 화면 진입 ──────────────────────────────────────────────────

    @AuraEnabled(cacheable=false)
    public static Context getContext(Id recordId) {
        try {
            ProposalData data = queryProposalData(recordId);
            Context ctx = new Context();
            ctx.leadName = data.recordName;
            ctx.company = data.company;
            ctx.recipient = buildRecipient(data);
            ctx.ownerName = data.ownerName;
            ctx.industry = nz(data.industry);

            CorporateFinancialStatement__c fs = latestStatement(data);
            if (fs != null) {
                ctx.hasFinancials = true;
                ctx.finReportLabel = buildReportLabel(fs);
                ctx.finPeriodYm = disclosurePeriod(fs.Fiscal_Year__c, fs.External_Key__c, fs.Period_Type__c);
                ctx.cash = zero(fs.Cash_And_Equivalents__c);
                ctx.shortTermInstruments = zero(fs.Short_Term_Financial_Instruments__c);
                ctx.shortTermBorrowings = zero(fs.Short_Term_Borrowings__c);
                ctx.liquidTotal = ctx.cash + ctx.shortTermInstruments;
                ctx.liquidTotalText = approxText(ctx.liquidTotal);
            }

            ctx.catalog = buildCatalog();
            ctx.rationale = applyStoredRecommendation(ctx, data);
            return ctx;
        } catch (Exception e) {
            throw new AuraHandledException('제안서 화면을 여는 중 오류가 발생했습니다: ' + e.getMessage());
        }
    }

    // ─── 2. PDF 생성 ───────────────────────────────────────────────────

    /**
     * 화면 진입점. 선택 목록은 List<Selection> 이 아니라 **JSON 문자열**로 받는다.
     *
     * List<Selection> 으로 선언하면 Aura 의 복합 타입 파라미터 바인딩이 필드를 채우지 못해
     * productId·yieldRate 가 전부 null 인 Selection 이 들어온다. 화면에서는 값이 정상으로 실려
     * 나가고(LWC 가 보내기 전에 두 값을 검사한다) 서버에서만 비어 있어서, 원인을 찾기 어려웠다.
     * 문자열로 받아 JSON.deserialize 하면 그 바인딩 구간을 아예 타지 않는다.
     * 다시 List<Selection> 파라미터로 되돌리지 말 것.
     */
    @AuraEnabled(cacheable=false)
    public static GenerateResult generate(Id recordId, String selectionsJson, String backgroundMemo, Decimal assumedAmount) {
        return generateFor(recordId, parseSelections(selectionsJson), backgroundMemo, assumedAmount);
    }

    /**
     * LWC 가 보낸 JSON 문자열을 Selection 목록으로 되돌린다.
     * 값이 비어 있으면 여기서 걸러 낸다 — 뒤에서 (Id) 캐스팅이 터지면 원인을 알 수 없는 오류가 된다.
     */
    @TestVisible
    private static List<Selection> parseSelections(String selectionsJson) {
        if (String.isBlank(selectionsJson)) {
            throw new AuraHandledException('제안할 상품을 하나 이상 선택해 주세요.');
        }
        List<Selection> selections;
        try {
            selections = (List<Selection>) JSON.deserialize(selectionsJson, List<Selection>.class);
        } catch (Exception e) {
            throw new AuraHandledException(MALFORMED_SELECTION);
        }
        if (selections == null || selections.isEmpty()) {
            throw new AuraHandledException('제안할 상품을 하나 이상 선택해 주세요.');
        }
        for (Selection sel : selections) {
            if (String.isBlank(sel.productId)) {
                throw new AuraHandledException(MALFORMED_SELECTION);
            }
        }
        return selections;
    }

    @TestVisible
    private static GenerateResult generateFor(Id recordId, List<Selection> selections, String backgroundMemo, Decimal assumedAmount) {
        if (selections == null || selections.isEmpty()) {
            throw new AuraHandledException('제안할 상품을 하나 이상 선택해 주세요.');
        }
        try {
            ProposalData data = queryProposalData(recordId);
            CorporateFinancialStatement__c fs = latestStatement(data);
            String docNumber = nextDocNumber(recordId);

            Map<Id, Product2> products = new Map<Id, Product2>(queryProducts(selectionIds(selections)));
            LeadProposalPdfController.ProposalDoc doc =
                buildDoc(data, fs, selections, backgroundMemo, assumedAmount, docNumber, products);

            // (1) 렌더링 먼저 — DML 보다 앞이어야 한다
            Blob pdf = LeadProposalPdfController.render(doc);

            // (2) 파일 저장
            String fileName = docNumber + '_제안서_' + nz(data.company) + '.pdf';
            ContentVersion cv = new ContentVersion(
                Title = fileName.removeEnd('.pdf'),
                PathOnClient = fileName,
                VersionData = pdf,
                FirstPublishLocationId = recordId
            );
            insert as user cv;

            // 제안 내용을 리드에 남긴다. 지금까지는 PDF 본문에만 있어서 파일을 열지 않으면
            // "얼마로 제안했는지"를 알 수 없었고, 리드 여러 건을 놓고 집계할 수도 없었다.
            recordProposedTerms(data, selections, products);

            GenerateResult result = new GenerateResult();
            result.docNumber = docNumber;
            result.fileName = fileName;
            result.contentVersionId = String.valueOf(cv.Id);
            result.contentDocumentId = String.valueOf([
                SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id WITH USER_MODE LIMIT 1
            ].ContentDocumentId);
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
        return buildDoc(toProposalData(ld), fs, selections, backgroundMemo, assumedAmount, docNumber,
            new Map<Id, Product2>(queryProducts(selectionIds(selections))));
    }

    @TestVisible
    private static LeadProposalPdfController.ProposalDoc buildDoc(
        Opportunity opp, CorporateFinancialStatement__c fs, List<Selection> selections,
        String backgroundMemo, Decimal assumedAmount, String docNumber
    ) {
        return buildDoc(toProposalData(opp), fs, selections, backgroundMemo, assumedAmount, docNumber,
            new Map<Id, Product2>(queryProducts(selectionIds(selections))));
    }

    @TestVisible
    private static LeadProposalPdfController.ProposalDoc buildDoc(
        ProposalData data, CorporateFinancialStatement__c fs, List<Selection> selections,
        String backgroundMemo, Decimal assumedAmount, String docNumber, Map<Id, Product2> productById
    ) {
        LeadProposalPdfController.ProposalDoc doc = new LeadProposalPdfController.ProposalDoc();
        doc.docNumber = docNumber;
        doc.createdDateText = Datetime.now().format('yyyy년 M월 d일', 'Asia/Seoul');
        doc.companyName = nz(data.company);
        doc.industry = nz(data.industry);
        doc.recipient = buildRecipient(data);
        doc.ownerName = data.ownerName + ' (법인영업본부)';
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
            doc.finPeriodYm = disclosurePeriod(fs.Fiscal_Year__c, fs.External_Key__c, fs.Period_Type__c);
            doc.cashText = wonText(fs.Cash_And_Equivalents__c);
            doc.cashUnit = approxText(fs.Cash_And_Equivalents__c);
            if (fs.Short_Term_Financial_Instruments__c != null && fs.Short_Term_Financial_Instruments__c > 0) {
                doc.hasStfi = true;
                doc.stfiText = wonText(fs.Short_Term_Financial_Instruments__c);
                doc.stfiUnit = approxText(fs.Short_Term_Financial_Instruments__c);
            }
        }

        Boolean simulate = assumedAmount != null && assumedAmount > 0;
        if (simulate) {
            doc.assumedAmountText = approxText(assumedAmount).removeStart('약 ');
        }

        for (Selection sel : selections) {
            Product2 p = productById.get((Id) sel.productId);
            if (p == null) {
                // 조용히 건너뛰면 표가 빈 채로 나가고 원인을 알 수 없다.
                // 실제로 RM 에게 Product2 읽기 권한이 없어 행이 통째로 사라진 적이 있다.
                throw new AuraHandledException(
                    '선택한 상품을 조회할 수 없습니다. 상품 조회 권한을 확인해 주세요. (상품 Id: ' + sel.productId + ')');
            }
            Integer days = termDays(p);
            String termLabel = termText(p);
            // 에이전트가 이 종목에 기간을 따로 정해뒀으면 상품 기본값 대신 그 값을 쓴다
            if (p.Id == data.recommendedProductId && data.recommendedTermDays != null) {
                days = Integer.valueOf(data.recommendedTermDays);
                termLabel = dayText(days);
            }

            LeadProposalPdfController.ProductRow row = new LeadProposalPdfController.ProductRow();
            row.name = p.Name;
            row.family = productFamily(p);
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

    private static ProposalData queryProposalData(Id recordId) {
        if (recordId == null) {
            throw new AuraHandledException('레코드 Id가 필요합니다.');
        }
        String objectName = recordId.getSObjectType().getDescribe().getName();
        if (objectName == 'Lead') {
            // 저장된 추천이 없으면 여기서 계산해 채운다. 브리핑도 같은 필드를 읽으므로
            // 어느 쪽을 먼저 열든 같은 추천이 보인다. 에이전트가 이미 기록했으면 건드리지 않는다.
            LeadRecommendationEngine.ensureRecommendation(recordId);
            return toProposalData(queryLead(recordId));
        }
        if (objectName == 'Opportunity') {
            List<Opportunity> rows = [
                SELECT Id, Name, AccountId, ContactId, Account.Name, Account.Industry, Owner.Name,
                       Primary_Product__c, Primary_Product__r.Name, Product_Family__c, RP_Yield__c
                FROM Opportunity
                WHERE Id = :recordId
                WITH USER_MODE
                LIMIT 1
            ];
            if (rows.isEmpty()) {
                throw new AuraHandledException('영업기회를 찾을 수 없거나 조회 권한이 없습니다.');
            }
            ProposalData data = toProposalData(rows[0]);
            data.customerContactName = queryContactName(rows[0].ContactId);
            return data;
        }
        throw new AuraHandledException('상품 제안서는 Lead 또는 Opportunity에서만 열 수 있습니다.');
    }

    private static ProposalData toProposalData(Lead ld) {
        ProposalData data = new ProposalData();
        data.recordId = ld.Id;
        data.leadId = ld.Id;
        data.recordName = ld.Name;
        data.company = ld.Company;
        data.title = ld.Title;
        data.department = ld.Department__c;
        data.industry = ld.Industry;
        data.ownerName = ld.Owner.Name;
        data.recommendedProductId = ld.Recommended_Product__c;
        data.recommendedProductName = ld.Recommended_Product__r == null ? null : ld.Recommended_Product__r.Name;
        data.recommendedFamily = ld.Recommended_Product_Family__c;
        data.recommendationRationale = ld.Recommended_Product_Rationale__c;
        data.recommendedTermDays = ld.Recommended_Term_Days__c;
        data.recommendedFeeRate = ld.Recommended_Fee_Rate__c;
        return data;
    }

    private static ProposalData toProposalData(Opportunity opp) {
        ProposalData data = new ProposalData();
        data.recordId = opp.Id;
        data.accountId = opp.AccountId;
        data.recordName = opp.Name;
        data.company = opp.Account == null ? opp.Name : opp.Account.Name;
        data.industry = opp.Account == null ? null : opp.Account.Industry;
        data.ownerName = opp.Owner.Name;
        data.recommendedProductId = opp.Primary_Product__c;
        data.recommendedProductName = opp.Primary_Product__r == null ? null : opp.Primary_Product__r.Name;
        data.recommendedFamily = opp.Product_Family__c;
        data.recommendedTermDays = null;
        data.recommendedFeeRate = null;
        data.recommendationRationale = data.recommendedProductName == null
            ? null
            : '기회의 기준 상품 ' + data.recommendedProductName + '을(를) 기준으로 제안 상품을 준비합니다.';
        return data;
    }

    private static String queryContactName(Id contactId) {
        if (contactId == null) {
            return null;
        }
        List<Contact> contacts = [
            SELECT Id, Name
            FROM Contact
            WHERE Id = :contactId
            WITH USER_MODE
            LIMIT 1
        ];
        return contacts.isEmpty() ? null : contacts[0].Name;
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
            item.productId = String.valueOf(p.Id);
            item.name = p.Name;
            item.family = productFamily(p);
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
        return applyStoredRecommendation(ctx, toProposalData(ld));
    }

    private static String applyStoredRecommendation(Context ctx, ProposalData data) {
        ctx.recommendedFamily = data.recommendedFamily;
        ctx.recommendedTermDays = data.recommendedTermDays;
        ctx.recommendedFeeRate = data.recommendedFeeRate;

        if (data.recommendedProductId == null) {
            return String.isBlank(data.recommendationRationale)
                ? NO_AGENT_RECOMMENDATION
                : data.recommendationRationale + '\n\n(상품군까지만 정해져 있어 종목은 직접 선택해 주세요.)';
        }

        ctx.hasAgentRecommendation = true;
        for (CatalogItem item : ctx.catalog) {
            if (item.productId != String.valueOf(data.recommendedProductId)) {
                continue;
            }
            item.recommended = true;
            // 에이전트가 상품 기본값과 다른 기간·요율을 정했으면 그쪽을 보여준다
            if (data.recommendedTermDays != null) {
                item.termDays = Integer.valueOf(data.recommendedTermDays);
            }
            if (data.recommendedFeeRate != null) {
                item.feeRate = data.recommendedFeeRate;
            }
        }
        return String.isBlank(data.recommendationRationale)
            ? '기준 상품 ' + data.recommendedProductName + ' 을(를) 기준으로 추천합니다.'
            : data.recommendationRationale;
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

    private static CorporateFinancialStatement__c latestStatement(ProposalData data) {
        List<CorporateFinancialStatement__c> rows;
        if (data.leadId != null) {
            rows = [
                SELECT Id, Fiscal_Year__c, External_Key__c, Period_Type__c,
                       Cash_And_Equivalents__c, Short_Term_Financial_Instruments__c,
                       Short_Term_Borrowings__c, Bonds_Payable__c, Long_Term_Borrowings__c
                FROM CorporateFinancialStatement__c
                WHERE Lead__c = :data.leadId
                WITH USER_MODE
                ORDER BY Fiscal_Year__c DESC NULLS LAST, External_Key__c DESC NULLS LAST
                LIMIT 1
            ];
        } else if (data.accountId != null) {
            rows = [
                SELECT Id, Fiscal_Year__c, External_Key__c, Period_Type__c,
                       Cash_And_Equivalents__c, Short_Term_Financial_Instruments__c,
                       Short_Term_Borrowings__c, Bonds_Payable__c, Long_Term_Borrowings__c
                FROM CorporateFinancialStatement__c
                WHERE Account__c = :data.accountId
                WITH USER_MODE
                ORDER BY Fiscal_Year__c DESC NULLS LAST, External_Key__c DESC NULLS LAST
                LIMIT 1
            ];
        } else {
            return null;
        }
        return rows.isEmpty() ? null : rows[0];
    }

    /**
     * 제안서에 실은 대표 상품·기간·수익률을 리드에 기록한다.
     * 여러 상품을 담아 보낼 수 있지만 리드에는 대표 하나만 남긴다 — 에이전트 추천 상품이 선택에
     * 들어 있으면 그것을, 없으면 첫 번째 선택을 대표로 본다.
     * 기록 실패가 PDF 생성을 되돌리게 하지는 않는다. 파일은 이미 만들어졌고 그게 본 목적이다.
     */
    @TestVisible
    private static void recordProposedTerms(Lead ld, List<Selection> selections, Map<Id, Product2> productById) {
        recordProposedTerms(toProposalData(ld), selections, productById);
    }

    private static void recordProposedTerms(ProposalData data, List<Selection> selections, Map<Id, Product2> productById) {
        if (data.leadId == null) {
            // Opportunity has no matching Proposed_* field set in this org.
            // The generated file is already linked to the Opportunity, so do
            // not overwrite the deal's existing primary product or yield.
            return;
        }
        Selection chosen = null;
        for (Selection sel : selections) {
            if (String.isNotBlank(sel.productId) && ((Id) sel.productId) == data.recommendedProductId) {
                chosen = sel;
                break;
            }
        }
        if (chosen == null) {
            chosen = selections[0];
        }
        Product2 p = productById.get((Id) chosen.productId);
        if (p == null) {
            return;
        }
        Integer days = termDays(p);
        if (p.Id == data.recommendedProductId && data.recommendedTermDays != null) {
            days = Integer.valueOf(data.recommendedTermDays);
        }
        try {
            update as user new Lead(
                Id = data.leadId,
                Proposed_Product__c = p.Id,
                Proposed_Term_Days__c = days,
                Proposed_Yield_Rate__c = chosen.yieldRate
            );
        } catch (Exception e) {
            // 파일은 이미 저장됐다. 기록 실패로 전체를 실패시키면 RM 이 PDF 를 못 받는다.
            System.debug(LoggingLevel.WARN, '제안 조건 기록 실패 (PDF 는 정상 생성됨): ' + e.getMessage());
        }
    }

    private static List<Product2> queryProducts(Set<Id> productIds) {
        if (productIds == null) {
            return [
                SELECT Id, Name, Eligibility_Rule__c, Default_Fee_Rate__c, Min_Term_Days__c, Max_Term_Days__c
                FROM Product2 WHERE IsActive = true WITH USER_MODE ORDER BY Min_Term_Days__c, Name
            ];
        }
        return [
            SELECT Id, Name, Eligibility_Rule__c, Default_Fee_Rate__c, Min_Term_Days__c, Max_Term_Days__c
            FROM Product2 WHERE Id IN :productIds WITH USER_MODE
        ];
    }

    private static Set<Id> selectionIds(List<Selection> selections) {
        Set<Id> ids = new Set<Id>();
        for (Selection sel : selections) {
            if (String.isNotBlank(sel.productId)) {
                ids.add((Id) sel.productId);
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

    /** Product2.Family is not enabled in every target org; infer the display family from the product name. */
    @TestVisible
    private static String productFamily(Product2 p) {
        String name = nz(p.Name);
        if (name.contains('RP')) {
            return 'RP';
        }
        if (name.contains('회사채')) {
            return '채권';
        }
        if (name.contains('IPO')) {
            return 'IPO';
        }
        if (name.contains('퇴직연금')) {
            return '퇴직연금';
        }
        if (name.contains('자금운용') || name.contains('MMF') || name.contains('특정금전신탁') || name.contains('ELB')) {
            return '자금운용';
        }
        return '';
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
        String family = productFamily(p);
        if (family == '채권') {
            return '만기 보유 시 표면금리 수령';
        }
        if (isDemandType(p)) {
            return '수시 입출금';
        }
        if (family == 'RP') {
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
        String year = fs.Fiscal_Year__c == null ? '' : String.valueOf(fs.Fiscal_Year__c.intValue());
        String report = reportTypeLabel(fs.External_Key__c, fs.Period_Type__c);
        return String.isBlank(year) ? report : year + '년 ' + report;
    }

    /** Disclosure_Period_YM__c is a convenience formula; derive it from source fields. */
    @TestVisible
    private static String disclosurePeriod(Decimal fiscalYear, String externalKey, String periodType) {
        if (fiscalYear == null) {
            return '';
        }
        String reportCode = String.isBlank(externalKey) || externalKey.length() < 5
            ? null : externalKey.right(5);
        String month;
        if ('11013'.equals(reportCode) || '1분기'.equals(periodType)) {
            month = '03';
        } else if ('11012'.equals(reportCode) || '2분기'.equals(periodType)) {
            month = '06';
        } else if ('11014'.equals(reportCode) || '3분기'.equals(periodType)) {
            month = '09';
        } else if ('11011'.equals(reportCode) || '4분기'.equals(periodType) || '사업보고서'.equals(periodType)) {
            month = '12';
        } else {
            return String.valueOf(fiscalYear.intValue());
        }
        return String.valueOf(fiscalYear.intValue()) + '/' + month;
    }

    /**
     * Report_Type_Label__c is a convenience formula, not a source value.
     * Derive the same label from stable source fields so a missing optional
     * formula field cannot prevent the proposal screen from opening.
     */
    @TestVisible
    private static String reportTypeLabel(String externalKey, String periodType) {
        String reportCode = String.isBlank(externalKey) || externalKey.length() < 5
            ? null : externalKey.right(5);
        if ('11013'.equals(reportCode) || '1분기'.equals(periodType)) {
            return '1분기보고서';
        }
        if ('11012'.equals(reportCode) || '2분기'.equals(periodType)) {
            return '2분기보고서';
        }
        if ('11014'.equals(reportCode) || '3분기'.equals(periodType)) {
            return '3분기보고서';
        }
        if ('11011'.equals(reportCode) || '4분기'.equals(periodType)) {
            return '4분기보고서';
        }
        return '--';
    }

    private static String buildRecipient(Lead ld) {
        return buildRecipient(toProposalData(ld));
    }

    private static String buildRecipient(ProposalData data) {
        List<String> parts = new List<String>();
        if (String.isNotBlank(data.department)) {
            parts.add(data.department);
        }
        String person = String.isNotBlank(data.customerContactName)
            ? data.customerContactName
            : (String.isNotBlank(data.company) ? data.company : data.recordName);
        if (String.isNotBlank(data.title) && String.isBlank(data.customerContactName) && String.isBlank(data.company)) {
            person += ' ' + data.title;
        }
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