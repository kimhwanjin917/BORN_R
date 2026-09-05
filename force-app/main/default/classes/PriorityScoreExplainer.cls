/**
 * 우선순위 점수(Lead.Priority_Score__c)를 "왜 이 점수인지" 항목별로 분해해 설명 텍스트로 만든다.
 *
 * 점수 자체는 PriorityScoreBatch 가 확정한 값이고, 이 클래스는 그 점수를 재계산하지 않는 대신
 * 같은 규칙(동일 앵커·동일 상품 결정·동일 최신/직전 공시 선택)으로 "적합도 40 / 니즈 30 / 공시 30"
 * 3항목 분해와 근거 수치(현금자산비율·운용가능 자금·전년 동기比)를 산출한다.
 *
 * 결정성: 분해 합계는 PriorityScoreBatch.computeScore 와 동일한 순수 함수라 저장된 점수와 일치한다.
 * (PriorityScoreExplainerTest 가 배치 산정 점수 == 분해 합계 를 검증한다.)
 *
 * 배치 파일은 건드리지 않기 위해 채점 로직을 여기에 다시 구현한다 —
 * 앵커/공식이 바뀌면 PriorityScoreBatch 와 이 클래스를 함께 수정해야 한다(테스트가 불일치를 잡는다).
 */
public with sharing class PriorityScoreExplainer {

    private enum Product { RP, BOND }

    // ─── 항목별 최대 배점 (PriorityScoreBatch 와 동일) ───
    private static final Decimal NEED_MAX = 30;
    private static final Decimal NEED_PREMIUM = 3;

    private static final List<Decimal> CASH_FIT_X = new List<Decimal>{ 0, 0.06, 0.12, 0.30 };
    private static final List<Decimal> CASH_FIT_Y = new List<Decimal>{ 0, 7, 20, 40 };
    private static final List<Decimal> DEBT_FIT_X = new List<Decimal>{ 0, 0.12, 0.25, 0.50 };
    private static final List<Decimal> DEBT_FIT_Y = new List<Decimal>{ 0, 7, 20, 40 };

    private static final Decimal RP_NEED_FLOOR = 1000000000L;
    private static final Decimal RP_NEED_REF = 100000000000L;
    private static final Decimal BOND_NEED_FLOOR = 10000000000L;
    private static final Decimal BOND_NEED_REF = 1000000000000L;

    private static final List<Decimal> YOY_X = new List<Decimal>{ -0.10, 0.10, 0.30, 0.50 };
    private static final List<Decimal> YOY_Y = new List<Decimal>{ 0, 10, 22, 30 };
    private static final Decimal DISCLOSURE_NO_PRIOR = 10;

    private static final Integer SCORE_SCALE = 1;
    private static final String DISCLOSURE_SIGNAL = '공시';

    /** 점수 분해 결과. 값이 없거나 제외 대상이면 available=false. */
    public class Breakdown {
        public Boolean available = false;
        public Boolean isRp = true;          // true=RP, false=회사채
        public Decimal total;                // 세 항목 합 (= Lead.Priority_Score__c)
        public Decimal fitScore;             // 상품 적합도 (0~40)
        public Decimal needScore;            // 니즈 규모 (0~30)
        public Decimal disclosureScore;      // 최신 공시 (0~30)
        public Decimal fitRatio;             // 적합도 근거 비율(현금자산비율 또는 차입금의존도)
        public Decimal fund;                 // 운용/조달 가능 자금(원화)
        public Decimal yoyGrowth;            // 운용자금 전년 동기比 증가율(직전 없으면 null)
    }

    /**
     * 리드의 우선순위 점수 분해 근거 텍스트를 만든다. 데이터가 없거나 제외 대상이면 null.
     * MeetingPrepBriefingProvider 가 grounding 블록으로 이어 붙인다.
     */
    public static String buildGroundingText(Id leadId) {
        Breakdown b = explainLead(leadId);
        if (b == null || b.available != true) {
            return null;
        }
        String productLabel = b.isRp ? 'RP(단기 여유자금 운용)' : '회사채(자금 조달)';
        String fitLabel = b.isRp ? '현금자산비율' : '차입금의존도';
        String fundLabel = b.isRp ? '운용 가능 자금(현금및현금성자산+단기금융상품)' : '조달 관련 자금(단기차입금+장기차입금+사채)';

        List<String> lines = new List<String>();
        lines.add('[우선순위 점수 근거 - Apex 가 배치와 동일한 규칙으로 분해한 값이다. 이 항목별 점수와 수치만 인용하고 지어내지 말 것]');
        lines.add('- 우선순위 점수: ' + trimDecimal(b.total) + '점 (아래 세 항목의 합)');
        lines.add('- 상품 적합도: ' + trimDecimal(b.fitScore) + '점 / 40점 — '
            + fitLabel + ' ' + trimDecimal((b.fitRatio * 100).setScale(1, System.RoundingMode.HALF_UP)) + '%로 '
            + productLabel + ' 적합');
        lines.add('- 니즈 규모: ' + trimDecimal(b.needScore) + '점 / 30점 — '
            + fundLabel + ' ' + formatWon(b.fund));
        if (b.yoyGrowth == null) {
            lines.add('- 최신 공시: ' + trimDecimal(b.disclosureScore) + '점 / 30점 — 직전 동기 공시가 없어 중립 채점');
        } else {
            Decimal pct = (b.yoyGrowth * 100).setScale(1, System.RoundingMode.HALF_UP);
            lines.add('- 최신 공시: ' + trimDecimal(b.disclosureScore) + '점 / 30점 — 운용자금 전년 동기比 '
                + (pct >= 0 ? '+' : '') + trimDecimal(pct) + '%');
        }
        return String.join(lines, '\n');
    }

    /** 리드의 최신/직전 공시를 골라 점수를 분해한다. 배치의 선택 로직을 그대로 따른다. */
    public static Breakdown explainLead(Id leadId) {
        Breakdown b = new Breakdown();
        if (leadId == null) {
            return b;
        }
        List<CorporateFinancialStatement__c> stmts;
        try {
            stmts = [
                SELECT Fiscal_Year__c, Period_Type__c, External_Key__c,
                       Total_Assets__c, Total_Equity__c,
                       Cash_And_Equivalents__c, Short_Term_Financial_Instruments__c,
                       Short_Term_Borrowings__c, Long_Term_Borrowings__c, Bonds_Payable__c
                FROM CorporateFinancialStatement__c
                WHERE Lead__c = :leadId
                WITH USER_MODE
                ORDER BY Fiscal_Year__c DESC NULLS LAST, Id ASC
            ];
        } catch (QueryException e) {
            return b;
        }
        if (stmts.isEmpty()) {
            return b;
        }

        // 최신 = recencyKey 최대. 직전 = 같은 보고서 코드 & Fiscal_Year-1.
        CorporateFinancialStatement__c latest = null;
        Integer latestKey = null;
        for (CorporateFinancialStatement__c s : stmts) {
            Integer key = recencyKey(s);
            if (latest == null || key > latestKey) {
                latest = s;
                latestKey = key;
            }
        }
        CorporateFinancialStatement__c prior = null;
        String latestCode = reportCodeOf(latest);
        Integer priorYear = latest.Fiscal_Year__c == null ? null : latest.Fiscal_Year__c.intValue() - 1;
        if (priorYear != null) {
            for (CorporateFinancialStatement__c s : stmts) {
                Integer year = s.Fiscal_Year__c == null ? null : s.Fiscal_Year__c.intValue();
                if (year == priorYear && sameCode(reportCodeOf(s), latestCode)) {
                    prior = s;
                    break;
                }
            }
        }

        Integer latestDisclosureYear = loadLatestDisclosureYear(leadId);
        return computeBreakdown(latest, prior, latestDisclosureYear);
    }

    /** 최신/직전 공시와 최신 공시연도로 3항목을 분해한다. 제외/데이터 없음이면 available=false. */
    public static Breakdown computeBreakdown(
        CorporateFinancialStatement__c latest,
        CorporateFinancialStatement__c prior,
        Integer latestDisclosureYear
    ) {
        Breakdown b = new Breakdown();
        if (latest == null) {
            return b;
        }
        if (latest.Total_Equity__c == null || latest.Total_Equity__c <= 0) {
            return b; // 자본잠식 제외
        }
        Decimal totalAssets = latest.Total_Assets__c;
        if (totalAssets == null || totalAssets <= 0) {
            return b;
        }

        Decimal cashFund = sumFund(latest, Product.RP);
        Decimal bondFund = sumFund(latest, Product.BOND);
        Decimal cashRatio = cashFund / totalAssets;
        Decimal debtRatio = bondFund / totalAssets;
        Decimal cashFitScore = piecewise(cashRatio, CASH_FIT_X, CASH_FIT_Y);
        Decimal debtFitScore = piecewise(debtRatio, DEBT_FIT_X, DEBT_FIT_Y);

        Product productKind = debtFitScore > cashFitScore ? Product.BOND : Product.RP;
        Decimal fitScore = productKind == Product.BOND ? debtFitScore : cashFitScore;
        Decimal fund = productKind == Product.RP ? cashFund : bondFund;

        b.available = true;
        b.isRp = productKind == Product.RP;
        b.fitScore = fitScore;
        b.fitRatio = productKind == Product.RP ? cashRatio : debtRatio;
        b.fund = fund;
        b.needScore = scoreNeed(productKind, fund);
        b.yoyGrowth = computeYoy(latest, prior, productKind);
        b.disclosureScore = scoreDisclosure(latest, prior, latestDisclosureYear, productKind);
        b.total = (b.fitScore + b.needScore + b.disclosureScore).setScale(SCORE_SCALE, System.RoundingMode.HALF_UP);
        return b;
    }

    // ─── 채점 (PriorityScoreBatch 와 동일) ───

    private static Decimal scoreNeed(Product productKind, Decimal fund) {
        Decimal floorFund = productKind == Product.RP ? RP_NEED_FLOOR : BOND_NEED_FLOOR;
        Decimal refFund = productKind == Product.RP ? RP_NEED_REF : BOND_NEED_REF;
        if (fund == null || fund <= floorFund) {
            return 0;
        }
        Decimal baseMax = NEED_MAX - NEED_PREMIUM;
        if (fund <= refFund) {
            Double span = Math.log10(refFund.doubleValue()) - Math.log10(floorFund.doubleValue());
            Double pos = Math.log10(fund.doubleValue()) - Math.log10(floorFund.doubleValue());
            return baseMax * Decimal.valueOf(pos / span);
        }
        return baseMax + NEED_PREMIUM * (1 - refFund / fund);
    }

    /** 최신 공시 점수(30점). 배치와 동일. */
    private static Decimal scoreDisclosure(
        CorporateFinancialStatement__c latest,
        CorporateFinancialStatement__c prior,
        Integer latestDisclosureYear,
        Product productKind
    ) {
        Integer latestFiscalYear = latest.Fiscal_Year__c == null ? null : latest.Fiscal_Year__c.intValue();
        if (latestDisclosureYear != null && latestFiscalYear != null && latestDisclosureYear > latestFiscalYear) {
            return 0;
        }
        Decimal growth = computeYoy(latest, prior, productKind);
        if (growth == null) {
            return DISCLOSURE_NO_PRIOR;
        }
        return piecewise(growth, YOY_X, YOY_Y);
    }

    /** 운용자금 전년 동기比 증가율. 직전이 없거나 0 이하면 null(비교 불가). */
    private static Decimal computeYoy(
        CorporateFinancialStatement__c latest,
        CorporateFinancialStatement__c prior,
        Product productKind
    ) {
        if (prior == null) {
            return null;
        }
        Decimal priorFund = sumFund(prior, productKind);
        if (priorFund == null || priorFund <= 0) {
            return null;
        }
        Decimal latestFund = sumFund(latest, productKind);
        return (latestFund - priorFund) / priorFund;
    }

    private static Decimal sumFund(CorporateFinancialStatement__c statement, Product productKind) {
        if (productKind == Product.RP) {
            return zero(statement.Cash_And_Equivalents__c) + zero(statement.Short_Term_Financial_Instruments__c);
        }
        return zero(statement.Short_Term_Borrowings__c)
            + zero(statement.Long_Term_Borrowings__c)
            + zero(statement.Bonds_Payable__c);
    }

    private static Decimal zero(Decimal value) {
        return value == null ? 0 : value;
    }

    private static Decimal piecewise(Decimal x, List<Decimal> xs, List<Decimal> ys) {
        Integer n = xs.size();
        if (x <= xs[0]) {
            return ys[0];
        }
        if (x >= xs[n - 1]) {
            return ys[n - 1];
        }
        for (Integer i = 1; i < n; i++) {
            if (x <= xs[i]) {
                Decimal x0 = xs[i - 1];
                Decimal x1 = xs[i];
                Decimal y0 = ys[i - 1];
                Decimal y1 = ys[i];
                return y0 + (y1 - y0) * (x - x0) / (x1 - x0);
            }
        }
        return ys[n - 1];
    }

    // ─── 최신/직전 공시 선택 (PriorityScoreBatch 와 동일) ───

    private static Integer recencyKey(CorporateFinancialStatement__c statement) {
        Integer year = statement.Fiscal_Year__c == null ? 0 : statement.Fiscal_Year__c.intValue();
        return year * 10 + periodOrdinal(statement);
    }

    private static Integer periodOrdinal(CorporateFinancialStatement__c statement) {
        String code = reportCodeOf(statement);
        if ('11013'.equals(code)) { return 1; }
        if ('11012'.equals(code)) { return 2; }
        if ('11014'.equals(code)) { return 3; }
        if ('11011'.equals(code)) { return 4; }
        if ('4분기'.equals(statement.Period_Type__c)) { return 4; }
        if ('3분기'.equals(statement.Period_Type__c)) { return 3; }
        if ('2분기'.equals(statement.Period_Type__c)) { return 2; }
        if ('1분기'.equals(statement.Period_Type__c)) { return 1; }
        return 0;
    }

    private static String reportCodeOf(CorporateFinancialStatement__c statement) {
        if (String.isBlank(statement.External_Key__c)) {
            return null;
        }
        List<String> parts = statement.External_Key__c.split('_');
        return parts.size() >= 3 ? parts[parts.size() - 1] : null;
    }

    private static Boolean sameCode(String a, String b) {
        return a != null && a == b;
    }

    private static Integer loadLatestDisclosureYear(Id leadId) {
        Integer latestYear = null;
        for (ExternalSignal__c signal : [
            SELECT Signal_Date__c
            FROM ExternalSignal__c
            WHERE Lead__c = :leadId AND Signal_Type__c = :DISCLOSURE_SIGNAL AND Signal_Date__c != null
            WITH USER_MODE
        ]) {
            Integer y = signal.Signal_Date__c.year();
            if (latestYear == null || y > latestYear) {
                latestYear = y;
            }
        }
        return latestYear;
    }

    // ─── 표기 ───

    /** 소수 1자리로 보되 정수면 소수점 제거. 예: 32.0→"32", 74.2→"74.2". */
    private static String trimDecimal(Decimal value) {
        if (value == null) {
            return '0';
        }
        Decimal scaled = value.setScale(SCORE_SCALE, System.RoundingMode.HALF_UP);
        return scaled.toPlainString().replaceAll('\\.0$', '');
    }

    /** 원화 금액을 억 단위로. 값이 없으면 "정보 없음". */
    private static String formatWon(Decimal amount) {
        if (amount == null) {
            return '정보 없음';
        }
        Decimal inEok = (amount / 100000000L).setScale(1);
        return inEok.toPlainString().replaceAll('\\.0$', '') + '억 원';
    }
}