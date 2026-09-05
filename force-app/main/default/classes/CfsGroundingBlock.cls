/**
 * 우선순위 점수 근거용 재무 grounding 텍스트 생성기.
 *
 * LeadPriorityRationaleProvider·AccountPriorityRationaleProvider 가 공통으로 쓰는
 * "최신 공시 재무제표 + 전년 동기 대비 증감" 블록을 한 곳에서 만든다.
 * 최신/전년 동기 선택 규칙은 PriorityScoreBatch·PriorityScoreExplainer 와 동일하다
 * (최신 = recencyKey 최대, 전년 = 동일 보고서 코드·Fiscal_Year-1). 이렇게 해야
 * LLM 이 인용하는 근거 수치가 실제 점수를 만든 공시와 어긋나지 않는다.
 *
 * 점수를 재계산하지 않는다(AI 이원화 원칙) — 사실 수치만 텍스트로 제공한다.
 */
public with sharing class CfsGroundingBlock {

    /**
     * 한 대상의 재무제표 목록(정렬 무관)에서 최신 공시와 전년 동기를 골라
     * 근거 텍스트 블록을 만든다. 목록이 비면 null.
     * @param statements 대상에 연결된 CorporateFinancialStatement__c 목록
     * @return 근거 텍스트(최신 공시 수치 + 전년 동기比) 또는 null
     */
    public static String render(List<CorporateFinancialStatement__c> statements) {
        if (statements == null || statements.isEmpty()) {
            return null;
        }

        // 최신 = recencyKey 최대. 전년 동기 = 동일 보고서 코드 & Fiscal_Year-1.
        CorporateFinancialStatement__c latest = null;
        Integer latestKey = null;
        for (CorporateFinancialStatement__c s : statements) {
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
            for (CorporateFinancialStatement__c s : statements) {
                Integer year = s.Fiscal_Year__c == null ? null : s.Fiscal_Year__c.intValue();
                if (year == priorYear && sameCode(reportCodeOf(s), latestCode)) {
                    prior = s;
                    break;
                }
            }
        }

        List<String> lines = new List<String>();
        lines.add('[최신 공시 재무제표' + periodLabel(latest) + ']');
        lines.add('- 자산총계: ' + formatWon(latest.Total_Assets__c));
        lines.add('- 자본총계: ' + formatWon(latest.Total_Equity__c));
        lines.add('- 현금및현금성자산: ' + formatWon(latest.Cash_And_Equivalents__c));
        lines.add('- 단기금융상품: ' + formatWon(latest.Short_Term_Financial_Instruments__c));
        lines.add('- 단기차입금: ' + formatWon(latest.Short_Term_Borrowings__c));
        lines.add('- 장기차입금: ' + formatWon(latest.Long_Term_Borrowings__c));
        lines.add('- 사채: ' + formatWon(latest.Bonds_Payable__c));

        // 최신 공시 축(YoY): 상품 자금의 전년 동기 대비 증감. 점수의 '최신 공시 30점' 항목과 동일 정의.
        lines.add('');
        if (prior == null) {
            lines.add('[전년 동기 대비] 전년 동기 공시가 없어 비교 불가 (최신 공시 점수는 중립 채점)');
        } else {
            lines.add('[전년 동기 대비' + periodLabel(prior) + ']');
            lines.add('- 운용 가능 자금(현금및현금성자산+단기금융상품): '
                + yoyText(rpFund(prior), rpFund(latest)));
            lines.add('- 조달 관련 자금(단기차입금+장기차입금+사채): '
                + yoyText(bondFund(prior), bondFund(latest)));
        }
        return String.join(lines, '\n');
    }

    // ─── 최신/전년 선택 (PriorityScoreBatch 와 동일) ───

    private static Integer recencyKey(CorporateFinancialStatement__c s) {
        Integer year = s.Fiscal_Year__c == null ? 0 : s.Fiscal_Year__c.intValue();
        return year * 10 + periodOrdinal(s);
    }

    private static Integer periodOrdinal(CorporateFinancialStatement__c s) {
        String code = reportCodeOf(s);
        if ('11013'.equals(code)) { return 1; }
        if ('11012'.equals(code)) { return 2; }
        if ('11014'.equals(code)) { return 3; }
        if ('11011'.equals(code)) { return 4; }
        if ('4분기'.equals(s.Period_Type__c)) { return 4; }
        if ('3분기'.equals(s.Period_Type__c)) { return 3; }
        if ('2분기'.equals(s.Period_Type__c)) { return 2; }
        if ('1분기'.equals(s.Period_Type__c)) { return 1; }
        return 0;
    }

    private static String reportCodeOf(CorporateFinancialStatement__c s) {
        if (String.isBlank(s.External_Key__c)) {
            return null;
        }
        List<String> parts = s.External_Key__c.split('_');
        return parts.size() >= 3 ? parts[parts.size() - 1] : null;
    }

    private static Boolean sameCode(String a, String b) {
        return a != null && a == b;
    }

    // ─── 표기 ───

    private static String periodLabel(CorporateFinancialStatement__c s) {
        String year = s.Fiscal_Year__c == null ? null : String.valueOf(s.Fiscal_Year__c.intValue());
        String period = String.isBlank(s.Period_Type__c) ? null : s.Period_Type__c;
        if (year != null && period != null) { return ' (' + year + '년 ' + period + ')'; }
        if (year != null) { return ' (' + year + '년)'; }
        if (period != null) { return ' (' + period + ')'; }
        return '';
    }

    private static String yoyText(Decimal priorFund, Decimal latestFund) {
        String base = formatWon(priorFund) + ' → ' + formatWon(latestFund);
        if (priorFund == null || priorFund <= 0) {
            return base + ' (전년 동기比 산정 불가)';
        }
        Decimal pct = ((latestFund - priorFund) / priorFund * 100).setScale(1, System.RoundingMode.HALF_UP);
        return base + ' (전년 동기比 ' + (pct >= 0 ? '+' : '') + trimDecimal(pct) + '%)';
    }

    private static Decimal rpFund(CorporateFinancialStatement__c s) {
        return zero(s.Cash_And_Equivalents__c) + zero(s.Short_Term_Financial_Instruments__c);
    }

    private static Decimal bondFund(CorporateFinancialStatement__c s) {
        return zero(s.Short_Term_Borrowings__c) + zero(s.Long_Term_Borrowings__c) + zero(s.Bonds_Payable__c);
    }

    private static Decimal zero(Decimal v) {
        return v == null ? 0 : v;
    }

    /** 소수 1자리로 보되 정수면 소수점 제거. 예: 50.0→"50", 12.3→"12.3". */
    private static String trimDecimal(Decimal value) {
        if (value == null) {
            return '0';
        }
        return value.setScale(1, System.RoundingMode.HALF_UP).toPlainString().replaceAll('\\.0$', '');
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