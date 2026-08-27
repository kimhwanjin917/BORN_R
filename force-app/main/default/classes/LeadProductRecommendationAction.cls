/**
 * Lead 단계 상품추천 — 미팅 메모 없이 Lead 필드 + DART 재무(CorporateFinancialStatement__c)
 * + 외부시그널(ExternalSignal__c) + 활성 상품 후보를 에이전트가 해석할 재료로 돌려주는 Invocable 액션.
 *
 * 설계 원칙 (ProductRecommendationAction 과 동일):
 *  - 서버는 적합성 판정을 하지 않는다. 상품 Eligibility_Rule__c 와 Lead 컨텍스트를 그대로 넘기고
 *    에이전트가 상품군(RP / 회사채 등)을 고른다.
 *  - with sharing + USER_MODE. 접근 불가 Lead 면 빈 응답 (예외 없음).
 *  - 진승혜 ProductRecommendationAction 은 수정하지 않는다 (docs/50, Round 4 결정).
 *
 * 추천 결과 기록은 LeadRecommendationSaveAction 이 담당한다.
 */
public with sharing class LeadProductRecommendationAction {

    @TestVisible
    private static final Integer MAX_PRODUCTS = 2000;
    /** 연간(사업보고서) 재무를 몇 개년 넘길지. 추세를 보려면 최소 3개년이 필요하다. */
    @TestVisible
    private static final Integer MAX_FINANCIALS = 3;
    /**
     * 연간만 보면 최신 잔고를 놓친다 — 사업보고서는 12월 결산이라 반년 넘게 묵은 숫자가 된다.
     * 자금운용 제안은 "지금 굴릴 수 있는 돈"이 핵심이므로 최신 분기를 따로 하나 더 얹는다.
     * 추세는 연간으로, 잔고는 최신 분기로 본다. (미팅 준비 브리핑도 같은 축을 본다)
     */
    @TestVisible
    private static final String ANNUAL_PERIOD = '4분기';
    @TestVisible
    private static final Integer MAX_LATEST_QUARTERS = 1;
    @TestVisible
    private static final Integer MAX_SIGNALS = 10;

    // ─── Invocable ────────────────────────────────────────────────────────

    @InvocableMethod(
        label='Lead 단계 상품추천 재료 조회'
        description='Lead 의 기본 정보·우선순위 근거·DART 재무(최근 3개 기간)·외부시그널(최근 10건)·활성 상품 후보를 실행 사용자 권한으로 조회해 돌려줍니다. 적합성 판단은 하지 않으며, 에이전트가 상품군(RP/회사채)을 고르는 데 씁니다.'
        category='근본증권 RM')
    public static List<Response> gather(List<Request> requests) {
        List<Response> responses = new List<Response>();
        if (requests == null || requests.isEmpty()) {
            return responses;
        }

        Set<Id> leadIds = new Set<Id>();
        for (Request req : requests) {
            if (req != null && req.leadId != null) {
                leadIds.add(req.leadId);
            }
        }

        Map<Id, Lead> leadsById = queryLeads(leadIds);
        Map<Id, List<Financial>> financialsByLeadId = queryFinancials(leadsById.keySet());
        Map<Id, List<Signal>> signalsByLeadId = querySignals(leadsById.keySet());
        List<ProductCandidate> products = queryActiveProducts();

        for (Request req : requests) {
            responses.add(buildResponse(req, leadsById, financialsByLeadId, signalsByLeadId, products));
        }
        return responses;
    }

    // ─── Queries (user mode) ──────────────────────────────────────────────

    private static Map<Id, Lead> queryLeads(Set<Id> leadIds) {
        if (leadIds.isEmpty()) {
            return new Map<Id, Lead>();
        }
        try {
            return new Map<Id, Lead>([
                SELECT Id, Company, name_new__c, Industry, AnnualRevenue, NumberOfEmployees,
                       Status, Priority_Score__c, Priority_Rationale_Summary__c, Priority_Rationale_Detail__c,
                       Recommended_Product_Family__c, Recommended_Product_Rationale__c
                FROM Lead
                WHERE Id IN :leadIds AND IsConverted = false
                WITH USER_MODE
            ]);
        } catch (QueryException e) {
            return new Map<Id, Lead>();
        }
    }

    private static Map<Id, List<Financial>> queryFinancials(Set<Id> leadIds) {
        Map<Id, List<Financial>> byLeadId = new Map<Id, List<Financial>>();
        if (leadIds.isEmpty()) {
            return byLeadId;
        }
        List<CorporateFinancialStatement__c> rows;
        try {
            rows = [
                SELECT Id, Lead__c, Fiscal_Year__c, Period_Type__c, Revenue__c, Operating_Income__c,
                       Total_Assets__c, Total_Debt__c, Total_Equity__c, Cash_And_Equivalents__c,
                       Short_Term_Financial_Instruments__c, Bonds_Payable__c, Cash_Asset_Ratio__c,
                       Disclosure_Period_YM__c
                FROM CorporateFinancialStatement__c
                WHERE Lead__c IN :leadIds
                WITH USER_MODE
                ORDER BY Fiscal_Year__c DESC NULLS LAST, Disclosure_Period_YM__c DESC NULLS LAST, CreatedDate DESC
            ];
        } catch (QueryException e) {
            return byLeadId;
        }
        // 연간과 분기를 따로 센다. 연간 3개년(추세) + 최신 분기 1건(잔고).
        Map<Id, Integer> annualCount = new Map<Id, Integer>();
        Map<Id, Integer> quarterCount = new Map<Id, Integer>();
        for (CorporateFinancialStatement__c row : rows) {
            if (!byLeadId.containsKey(row.Lead__c)) {
                byLeadId.put(row.Lead__c, new List<Financial>());
                annualCount.put(row.Lead__c, 0);
                quarterCount.put(row.Lead__c, 0);
            }
            List<Financial> bucket = byLeadId.get(row.Lead__c);
            Boolean isAnnual = ANNUAL_PERIOD.equals(row.Period_Type__c);
            if (isAnnual) {
                if (annualCount.get(row.Lead__c) >= MAX_FINANCIALS) {
                    continue;
                }
                annualCount.put(row.Lead__c, annualCount.get(row.Lead__c) + 1);
            } else {
                if (quarterCount.get(row.Lead__c) >= MAX_LATEST_QUARTERS) {
                    continue;
                }
                quarterCount.put(row.Lead__c, quarterCount.get(row.Lead__c) + 1);
            }
            Financial f = new Financial();
            f.fiscalYear = row.Fiscal_Year__c == null ? null : Integer.valueOf(row.Fiscal_Year__c);
            f.periodType = row.Period_Type__c;
            f.disclosurePeriod = row.Disclosure_Period_YM__c;
            f.isAnnual = isAnnual;
            f.revenue = row.Revenue__c;
            f.operatingIncome = row.Operating_Income__c;
            f.totalAssets = row.Total_Assets__c;
            f.totalDebt = row.Total_Debt__c;
            f.totalEquity = row.Total_Equity__c;
            f.cashAndEquivalents = row.Cash_And_Equivalents__c;
            f.shortTermFinancialInstruments = row.Short_Term_Financial_Instruments__c;
            f.bondsPayable = row.Bonds_Payable__c;
            f.cashAssetRatio = row.Cash_Asset_Ratio__c;
            bucket.add(f);
        }
        return byLeadId;
    }

    private static Map<Id, List<Signal>> querySignals(Set<Id> leadIds) {
        Map<Id, List<Signal>> byLeadId = new Map<Id, List<Signal>>();
        if (leadIds.isEmpty()) {
            return byLeadId;
        }
        List<ExternalSignal__c> rows;
        try {
            rows = [
                SELECT Id, Lead__c, Signal_Type__c, Title__c, Summary__c, Signal_Date__c,
                       Amount__c, Maturity_Date__c, Relevance_Score__c
                FROM ExternalSignal__c
                WHERE Lead__c IN :leadIds
                WITH USER_MODE
                ORDER BY Signal_Date__c DESC NULLS LAST, Relevance_Score__c DESC NULLS LAST
            ];
        } catch (QueryException e) {
            return byLeadId;
        }
        for (ExternalSignal__c row : rows) {
            if (!byLeadId.containsKey(row.Lead__c)) {
                byLeadId.put(row.Lead__c, new List<Signal>());
            }
            List<Signal> bucket = byLeadId.get(row.Lead__c);
            if (bucket.size() >= MAX_SIGNALS) {
                continue;
            }
            Signal s = new Signal();
            s.signalType = row.Signal_Type__c;
            s.title = row.Title__c;
            s.summary = row.Summary__c;
            s.signalDate = row.Signal_Date__c;
            s.amount = row.Amount__c;
            s.maturityDate = row.Maturity_Date__c;
            s.relevanceScore = row.Relevance_Score__c;
            bucket.add(s);
        }
        return byLeadId;
    }

    private static List<ProductCandidate> queryActiveProducts() {
        List<ProductCandidate> candidates = new List<ProductCandidate>();
        List<Product2> products;
        try {
            products = [
                SELECT Id, Name, Family, Eligibility_Rule__c, Default_Fee_Rate__c,
                       Min_Term_Days__c, Max_Term_Days__c
                FROM Product2
                WHERE IsActive = true AND Family != null
                WITH USER_MODE
                ORDER BY Name
                LIMIT :MAX_PRODUCTS
            ];
        } catch (QueryException e) {
            return candidates;
        }
        for (Product2 p : products) {
            ProductCandidate c = new ProductCandidate();
            c.productName = p.Name;
            c.productFamily = p.Family;
            c.eligibilityBasis = p.Eligibility_Rule__c;
            c.feeRate = p.Default_Fee_Rate__c;
            c.minTermDays = p.Min_Term_Days__c == null ? null : Integer.valueOf(p.Min_Term_Days__c);
            c.maxTermDays = p.Max_Term_Days__c == null ? null : Integer.valueOf(p.Max_Term_Days__c);
            candidates.add(c);
        }
        return candidates;
    }

    // ─── Response assembly ────────────────────────────────────────────────

    private static Response buildResponse(
        Request req,
        Map<Id, Lead> leadsById,
        Map<Id, List<Financial>> financialsByLeadId,
        Map<Id, List<Signal>> signalsByLeadId,
        List<ProductCandidate> products
    ) {
        Response res = new Response();
        res.financials = new List<Financial>();
        res.signals = new List<Signal>();
        res.candidates = new List<ProductCandidate>();

        Lead ld = (req == null || req.leadId == null) ? null : leadsById.get(req.leadId);
        if (ld == null) {
            res.isAccessible = false;
            res.message = 'Lead 를 찾지 못했거나 접근 권한이 없거나 이미 전환되었습니다.';
            return res;
        }

        res.isAccessible = true;
        res.leadId = ld.Id;
        res.company = ld.Company;
        res.contactName = ld.name_new__c;
        res.industry = ld.Industry;
        res.annualRevenue = ld.AnnualRevenue;
        res.numberOfEmployees = ld.NumberOfEmployees;
        res.status = ld.Status;
        res.priorityScore = ld.Priority_Score__c;
        res.priorityRationale = ld.Priority_Rationale_Summary__c;
        res.currentProductFamily = ld.Recommended_Product_Family__c;
        res.currentRationale = ld.Recommended_Product_Rationale__c;

        if (financialsByLeadId.containsKey(ld.Id)) {
            res.financials = financialsByLeadId.get(ld.Id);
        }
        if (signalsByLeadId.containsKey(ld.Id)) {
            res.signals = signalsByLeadId.get(ld.Id);
        }
        res.candidates = products;

        res.financialText = describeFinancials(res.financials);
        res.signalText = describeSignals(res.signals);
        res.candidateText = describeCandidates(products);
        res.message = ld.Company + ' — 재무 ' + res.financials.size() + '건, 외부시그널 '
            + res.signals.size() + '건, 상품 후보 ' + products.size() + '건.';
        return res;
    }

    private static String describeFinancials(List<Financial> items) {
        if (items.isEmpty()) {
            return 'DART 재무 데이터 없음';
        }
        List<String> lines = new List<String>();
        for (Financial f : items) {
            List<String> parts = new List<String>();
            parts.add(String.valueOf(f.fiscalYear) + (String.isBlank(f.periodType) ? '' : ' ' + f.periodType));
            if (f.revenue != null) { parts.add('매출 ' + fmt(f.revenue)); }
            if (f.operatingIncome != null) { parts.add('영업이익 ' + fmt(f.operatingIncome)); }
            if (f.totalAssets != null) { parts.add('총자산 ' + fmt(f.totalAssets)); }
            if (f.totalDebt != null) { parts.add('총부채 ' + fmt(f.totalDebt)); }
            if (f.cashAndEquivalents != null) { parts.add('현금성자산 ' + fmt(f.cashAndEquivalents)); }
            if (f.shortTermFinancialInstruments != null) { parts.add('단기금융상품 ' + fmt(f.shortTermFinancialInstruments)); }
            if (f.bondsPayable != null) { parts.add('사채 ' + fmt(f.bondsPayable)); }
            if (f.cashAssetRatio != null) { parts.add('현금자산비율 ' + fmt(f.cashAssetRatio) + '%'); }
            lines.add('- ' + String.join(parts, ', '));
        }
        return String.join(lines, '\n');
    }

    private static String describeSignals(List<Signal> items) {
        if (items.isEmpty()) {
            return '외부시그널 없음';
        }
        List<String> lines = new List<String>();
        for (Signal s : items) {
            List<String> parts = new List<String>();
            if (s.signalDate != null) { parts.add(String.valueOf(s.signalDate)); }
            if (!String.isBlank(s.signalType)) { parts.add('[' + s.signalType + ']'); }
            if (!String.isBlank(s.title)) { parts.add(s.title); }
            if (!String.isBlank(s.summary)) { parts.add(s.summary); }
            if (s.amount != null) { parts.add('금액 ' + fmt(s.amount)); }
            if (s.maturityDate != null) { parts.add('만기 ' + String.valueOf(s.maturityDate)); }
            lines.add('- ' + String.join(parts, ' '));
        }
        return String.join(lines, '\n');
    }

    private static String describeCandidates(List<ProductCandidate> items) {
        if (items.isEmpty()) {
            return '활성 상품 없음';
        }
        List<String> lines = new List<String>();
        for (ProductCandidate c : items) {
            String line = '- ' + c.productName + ' (상품군: ' + c.productFamily + ')';
            if (!String.isBlank(c.eligibilityBasis)) { line += ' 적격: ' + c.eligibilityBasis; }
            if (c.feeRate != null) { line += ', 수수료 ' + fmt(c.feeRate) + '%'; }
            lines.add(line);
        }
        return String.join(lines, '\n');
    }

    private static String fmt(Decimal d) {
        return d == null ? '' : d.setScale(0, RoundingMode.HALF_UP).format();
    }

    // ─── DTOs ─────────────────────────────────────────────────────────────

    public class Request {
        @InvocableVariable(label='Lead Id' description='추천 재료를 조회할 미전환 Lead 의 Id' required=true)
        public Id leadId;
    }

    public class Response {
        @InvocableVariable(label='접근 가능' description='false 면 Lead 를 찾지 못했거나 권한 없음/전환됨')
        public Boolean isAccessible;
        @InvocableVariable(label='Lead Id')
        public Id leadId;
        @InvocableVariable(label='회사명')
        public String company;
        @InvocableVariable(label='담당자 이름')
        public String contactName;
        @InvocableVariable(label='산업군')
        public String industry;
        @InvocableVariable(label='연매출' description='Lead.AnnualRevenue')
        public Decimal annualRevenue;
        @InvocableVariable(label='직원 수')
        public Integer numberOfEmployees;
        @InvocableVariable(label='상태')
        public String status;
        @InvocableVariable(label='우선순위 점수')
        public Decimal priorityScore;
        @InvocableVariable(label='우선순위 근거 요약' description='03번 우선순위 산정 근거')
        public String priorityRationale;
        @InvocableVariable(label='현재 추천 상품군' description='이미 기록된 값(RP/회사채). 비어 있으면 미정')
        public String currentProductFamily;
        @InvocableVariable(label='현재 추천 근거')
        public String currentRationale;
        @InvocableVariable(label='DART 재무' description='최근 3개 기간')
        public List<Financial> financials;
        @InvocableVariable(label='DART 재무 요약 텍스트')
        public String financialText;
        @InvocableVariable(label='외부시그널' description='최근 10건')
        public List<Signal> signals;
        @InvocableVariable(label='외부시그널 요약 텍스트')
        public String signalText;
        @InvocableVariable(label='상품 후보' description='활성 상품과 적격 조건. 서버가 순위를 매기지 않음')
        public List<ProductCandidate> candidates;
        @InvocableVariable(label='상품 후보 요약 텍스트')
        public String candidateText;
        @InvocableVariable(label='메시지')
        public String message;
    }

    public class Financial {
        @InvocableVariable(label='회계연도') public Integer fiscalYear;
        @InvocableVariable(label='기간 구분') public String periodType;
        @InvocableVariable(label='공시기준(년/월)') public String disclosurePeriod;
        @InvocableVariable(label='연간 여부' description='true 면 사업보고서(연간, 추세용), false 면 최신 분기(잔고용)') public Boolean isAnnual;
        @InvocableVariable(label='매출') public Decimal revenue;
        @InvocableVariable(label='영업이익') public Decimal operatingIncome;
        @InvocableVariable(label='총자산') public Decimal totalAssets;
        @InvocableVariable(label='총부채') public Decimal totalDebt;
        @InvocableVariable(label='총자본') public Decimal totalEquity;
        @InvocableVariable(label='현금및현금성자산') public Decimal cashAndEquivalents;
        @InvocableVariable(label='단기금융상품') public Decimal shortTermFinancialInstruments;
        @InvocableVariable(label='사채') public Decimal bondsPayable;
        @InvocableVariable(label='현금자산비율(%)') public Decimal cashAssetRatio;
    }

    public class Signal {
        @InvocableVariable(label='유형') public String signalType;
        @InvocableVariable(label='제목') public String title;
        @InvocableVariable(label='요약') public String summary;
        @InvocableVariable(label='시그널 일자') public Date signalDate;
        @InvocableVariable(label='금액') public Decimal amount;
        @InvocableVariable(label='만기일') public Date maturityDate;
        @InvocableVariable(label='관련도') public Decimal relevanceScore;
    }

    public class ProductCandidate {
        @InvocableVariable(label='상품명') public String productName;
        @InvocableVariable(label='상품군' description='Product2.Family (RP, 채권 등)') public String productFamily;
        @InvocableVariable(label='적격 조건') public String eligibilityBasis;
        @InvocableVariable(label='수수료율') public Decimal feeRate;
        @InvocableVariable(label='최소 기간(일)') public Integer minTermDays;
        @InvocableVariable(label='최대 기간(일)') public Integer maxTermDays;
    }
}