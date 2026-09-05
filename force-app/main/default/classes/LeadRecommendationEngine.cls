/**
 * 리드 상품추천을 실제로 계산하고 Lead 에 저장하는 단일 지점.
 *
 * 왜 여기 있나: 미팅 준비 브리핑과 상품 제안서 PDF 가 같은 추천을 보여줘야 하는데, 각자 계산하면
 * 절대 일치하지 않는다. 그래서 계산은 이 클래스 하나만 하고, 결과를 Lead 의 다섯 필드에 저장해
 * 양쪽이 그 값을 읽는다.
 *
 * 에이전트(RM_Assistant)도 같은 필드에 쓴다. 에이전트가 더 많은 근거(연간 추이·시그널)를 보므로
 * 에이전트가 기록한 값이 있으면 그것을 존중하고 여기서 덮지 않는다.
 * 이 클래스는 "아직 아무 추천도 없는 리드"를 재무 기준으로 채우는 역할이다.
 */
public with sharing class LeadRecommendationEngine {

    private static final Decimal ONE_EOK = 100000000;
    @TestVisible private static final String FAMILY_RP = 'RP';
    @TestVisible private static final String FAMILY_BOND = '회사채';
    /** Lead 상품군 → Product2.Family (두 오브젝트가 다른 낱말을 쓴다) */
    private static final Map<String, String> PRODUCT_FAMILY = new Map<String, String>{
        FAMILY_RP => 'RP', FAMILY_BOND => '채권'
    };

    public class Result {
        public Boolean saved = false;
        public String family;
        public Id productId;
        public Decimal termDays;
        public Decimal feeRate;
        public String rationale;
        public String skipReason;
    }

    /**
     * 저장된 추천이 없으면 계산해 Lead 에 기록한다. 이미 있으면 건드리지 않는다.
     * 재무 자료가 없으면 추정하지 않고 그대로 둔다 — 근거 없는 추천은 안 하느니만 못하다.
     */
    public static Result ensureRecommendation(Id leadId) {
        Result r = new Result();
        List<Lead> leads = [
            SELECT Id, Industry, Recommended_Product_Family__c
            FROM Lead
            WHERE Id = :leadId
            WITH USER_MODE
            LIMIT 1
        ];
        if (leads.isEmpty()) {
            r.skipReason = '리드를 찾을 수 없습니다.';
            return r;
        }
        if (String.isNotBlank(leads[0].Recommended_Product_Family__c)) {
            r.skipReason = '이미 저장된 추천이 있어 그대로 둡니다.';
            return r;
        }

        List<CorporateFinancialStatement__c> fs = [
            SELECT Cash_And_Equivalents__c, Short_Term_Financial_Instruments__c,
                   Short_Term_Borrowings__c, Bonds_Payable__c, Long_Term_Borrowings__c,
                   Disclosure_Period_YM__c
            FROM CorporateFinancialStatement__c
            WHERE Lead__c = :leadId
            WITH USER_MODE
            ORDER BY Disclosure_Period_YM__c DESC NULLS LAST
            LIMIT 1
        ];
        if (fs.isEmpty() || fs[0].Cash_And_Equivalents__c == null) {
            r.skipReason = '연결된 공시 재무 자료가 없어 추천을 만들지 않았습니다.';
            return r;
        }

        Decimal cash = zero(fs[0].Cash_And_Equivalents__c);
        Decimal stfi = zero(fs[0].Short_Term_Financial_Instruments__c);
        Decimal shortDebt = zero(fs[0].Short_Term_Borrowings__c);
        Decimal raised = zero(fs[0].Bonds_Payable__c) + zero(fs[0].Long_Term_Borrowings__c);
        Decimal liquid = cash + stfi;

        // 조달 부채가 있거나 단기차입금이 현금을 넘으면 자금 조달 쪽(회사채), 아니면 여유자금 운용(RP).
        // 에이전트 지침과 같은 기준이다.
        // 단, 에이전트가 상품군만 정해둔 경우에는 그 판단을 존중하고 종목·기간·요율만 채운다.
        Boolean bondSide;
        if (String.isNotBlank(leads[0].Recommended_Product_Family__c)) {
            r.family = leads[0].Recommended_Product_Family__c;
            bondSide = FAMILY_BOND.equals(r.family);
        } else {
            bondSide = raised > 0 || shortDebt > cash;
            r.family = bondSide ? FAMILY_BOND : FAMILY_RP;
        }

        Product2 p = pickProduct(r.family);
        if (p == null) {
            r.skipReason = '해당 상품군의 활성 상품이 없습니다.';
            return r;
        }
        r.productId = p.Id;
        r.feeRate = p.Default_Fee_Rate__c;
        r.termDays = termFor(bondSide, liquid, p);
        r.rationale = buildRationale(bondSide, cash, stfi, shortDebt, raised, liquid, fs[0].Disclosure_Period_YM__c, p, r.termDays);

        try {
            Lead updateRecord = new Lead(Id = leadId);
            putIfUpdateable(updateRecord, 'Recommended_Product_Family__c', r.family);
            putIfUpdateable(updateRecord, 'Recommended_Product__c', r.productId);
            putIfUpdateable(updateRecord, 'Recommended_Term_Days__c', r.termDays);
            putIfUpdateable(updateRecord, 'Recommended_Fee_Rate__c', r.feeRate);
            putIfUpdateable(updateRecord, 'Recommended_Product_Rationale__c', r.rationale);
            update as user updateRecord;
            r.saved = true;
        } catch (Exception e) {
            r.skipReason = '추천 저장 실패: ' + e.getMessage();
        }
        return r;
    }

    /** 상품군의 대표 상품. 카탈로그가 유형 단위라 상품군당 하나로 좁혀진다. 외화 상품은 제외. */
    @TestVisible
    private static Product2 pickProduct(String leadFamily) {
        String family = PRODUCT_FAMILY.get(leadFamily);
        for (Product2 p : [
            SELECT Id, Name, Family, Min_Term_Days__c, Max_Term_Days__c, Default_Fee_Rate__c
            FROM Product2 WHERE IsActive = true AND Family = :family
            WITH USER_MODE ORDER BY Default_Fee_Rate__c NULLS LAST
        ]) {
            if (!p.Name.contains('외화')) {
                return p;
            }
        }
        return null;
    }

    /** 회사채는 3년 고정, RP 는 여유자금 규모로 기간을 잡는다. 상품 허용 범위를 벗어나지 않게 자른다. */
    @TestVisible
    private static Decimal termFor(Boolean bondSide, Decimal liquid, Product2 p) {
        Decimal days = bondSide ? 1095 : (liquid >= 500 * ONE_EOK ? 91 : 30);
        if (p.Min_Term_Days__c != null && days < p.Min_Term_Days__c) {
            days = p.Min_Term_Days__c;
        }
        if (p.Max_Term_Days__c != null && days > p.Max_Term_Days__c) {
            days = p.Max_Term_Days__c;
        }
        return days;
    }

    @TestVisible
    private static String buildRationale(Boolean bondSide, Decimal cash, Decimal stfi, Decimal shortDebt,
                                         Decimal raised, Decimal liquid, String periodYm, Product2 p, Decimal days) {
        String basis = String.isBlank(periodYm) ? '최근 공시' : periodYm + ' 공시';
        List<String> lines = new List<String>();
        lines.add(basis + ' 기준 현금및현금성자산 ' + eok(cash) + (stfi > 0 ? ', 단기금융상품 ' + eok(stfi) : '') + '.');
        if (bondSide) {
            lines.add(raised > 0
                ? '사채·장기차입금 ' + eok(raised) + ' 규모의 조달 부채가 있어 자금 조달 니즈가 있다고 보았습니다.'
                : '단기차입금 ' + eok(shortDebt) + ' 이 현금성자산을 넘어 자금 조달 쪽이 더 유력합니다.');
        } else {
            lines.add('운용 가능 자금이 ' + eok(liquid) + ' 규모이고 차입 부담이 낮아 여유자금 운용이 적합합니다.');
        }
        lines.add(p.Name + ' 을(를) ' + days.setScale(0) + '일 기준으로 제안합니다. 최종 조건은 미팅에서 확정합니다.');
        return String.join(lines, ' ');
    }

    private static String eok(Decimal v) {
        return v == null || v == 0 ? '0원' : (v / ONE_EOK).setScale(0, System.RoundingMode.HALF_UP).format() + '억원';
    }

    private static void putIfUpdateable(SObject record, String fieldApiName, Object value) {
        Schema.SObjectField fieldToken = Schema.SObjectType.Lead.fields.getMap().get(fieldApiName);
        if (fieldToken != null && fieldToken.getDescribe().isUpdateable()) {
            record.put(fieldApiName, value);
        }
    }

    private static Decimal zero(Decimal d) { return d == null ? 0 : d; }
}