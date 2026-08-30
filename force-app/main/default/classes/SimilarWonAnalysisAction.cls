/**
 * 백로그 21 — 유사 Won 집계 Apex 액션 (Agentforce / Flow 공용 Invocable).
 *
 * "감이 아니라 데이터로": 같은 산업군(Account.Industry)과 (선택) 같은 상품 유형의
 * 종결된 Opportunity를 Aggregate SOQL로 집계해 전체 종결 건수·Won 건수·Won 비율(%)을 돌려준다.
 * 숫자는 이 클래스가 실계산하고, 에이전트는 해석만 한다 (AI 이원화 원칙 — 확률을 지어내지 않음).
 *
 * - with sharing: 실행 사용자가 볼 수 있는 Opportunity만 집계된다.
 * - 레코드 목록은 반환하지 않고 집계 수치만 반환한다.
 * - 모수가 0이면 insufficientData = true, wonRate = 0 (0으로 나누지 않음, 수치를 만들어내지 않음).
 * - productType 매칭 기준: Opportunity.Product_Family__c 또는 기준 상품(Product2) 이름과 일치한다.
 */
public with sharing class SimilarWonAnalysisAction {

    private static final String MSG_NO_INDUSTRY = '산업군(industry)이 비어 있어 유사 기회를 찾을 수 없습니다.';
    private static final String MSG_INSUFFICIENT = '조건에 맞는 종결된 유사 기회가 없어 데이터가 부족합니다. 확률을 추정하지 마세요.';

    /** Input criteria for one similar-opportunity aggregation request. */
    public class Request {
        @InvocableVariable(
            label='산업군 (Account.Industry)'
            description='비교할 고객사의 산업군. Account.Industry 값과 정확히 일치해야 합니다. 예: Manufacturing, 제조업'
            required=true)
        public String industry;

        @InvocableVariable(
            label='상품 유형 (선택)'
            description='선택. Opportunity.Product_Family__c 상품군 또는 기준 상품명(예: RP, 회사채)을 지정하면 해당 상품이 주력 상품인 기회만 집계합니다.')
        public String productType;
    }

    /** Aggregated result returned to Agentforce or Flow. */
    public class Result {
        @InvocableVariable(label='전체 종결 건수' description='조건에 맞는 종결(Closed Won + Closed Lost) Opportunity 수')
        public Integer totalCount;

        @InvocableVariable(label='Won 건수' description='그중 Closed Won 건수')
        public Integer wonCount;

        @InvocableVariable(label='Won 비율(%)' description='wonCount / totalCount x 100, 소수 첫째 자리 반올림. 데이터 부족 시 0')
        public Decimal wonRate;

        @InvocableVariable(label='데이터 부족 여부' description='true면 유사 건이 없어(모수 0) 확률을 말할 수 없음. 이 경우 수치를 추정하지 말 것')
        public Boolean insufficientData;

        @InvocableVariable(label='적용된 산업군' description='집계에 사용한 산업군 값')
        public String industry;

        @InvocableVariable(label='적용된 상품 유형' description='집계에 사용한 상품 유형 (미지정 시 빈 값)')
        public String productType;

        @InvocableVariable(label='메시지' description='사람이 읽을 수 있는 집계 요약 또는 데이터 부족 안내')
        public String message;
    }

    /**
     * Aggregates closed opportunities by industry and optional product criteria.
     * @param requests Requests to process.
     * @return One result per request, in input order.
     */
    @InvocableMethod(
        label='유사 기회 Won 비율 집계'
        description='같은 산업군(선택: 같은 상품 유형)의 종결된 Opportunity를 집계해 전체 종결 건수, Won 건수, Won 비율(%)을 실계산으로 반환합니다. 모수가 0이면 insufficientData=true. 레코드가 아닌 집계 수치만 반환합니다.'
        category='근본증권 RM')
    public static List<Result> analyze(List<Request> requests) {
        List<Result> results = new List<Result>();
        if (requests == null) {
            return results;
        }
        for (Request req : requests) {
            results.add(analyzeOne(req));
        }
        return results;
    }

    private static Result analyzeOne(Request req) {
        Result res = new Result();
        res.totalCount = 0;
        res.wonCount = 0;
        res.wonRate = 0;
        res.insufficientData = true;

        String industry = req == null ? null : trimToNull(req.industry);
        String productType = req == null ? null : trimToNull(req.productType);
        res.industry = industry == null ? '' : industry;
        res.productType = productType == null ? '' : productType;

        if (industry == null) {
            res.message = MSG_NO_INDUSTRY;
            return res;
        }

        List<AggregateResult> rows;
        if (productType == null) {
            rows = [
                SELECT IsWon won, COUNT(Id) cnt
                FROM Opportunity
                WHERE IsClosed = true
                  AND Account.Industry = :industry
                WITH USER_MODE
                GROUP BY IsWon
            ];
        } else {
            rows = [
                SELECT IsWon won, COUNT(Id) cnt
                FROM Opportunity
                WHERE IsClosed = true
                  AND Account.Industry = :industry
                  AND (Product_Family__c = :productType OR Primary_Product__r.Name = :productType)
                WITH USER_MODE
                GROUP BY IsWon
            ];
        }

        Integer total = 0;
        Integer won = 0;
        for (AggregateResult ar : rows) {
            Integer cnt = (Integer) ar.get('cnt');
            total += cnt;
            if (ar.get('won') == true) {
                won += cnt;
            }
        }

        res.totalCount = total;
        res.wonCount = won;

        if (total == 0) {
            res.wonRate = 0;
            res.insufficientData = true;
            res.message = MSG_INSUFFICIENT;
            return res;
        }

        res.wonRate = (Decimal.valueOf(won) * 100 / Decimal.valueOf(total)).setScale(1, RoundingMode.HALF_UP);
        res.insufficientData = false;
        res.message = buildSummary(industry, productType, total, won, res.wonRate);
        return res;
    }

    private static String buildSummary(String industry, String productType, Integer total, Integer won, Decimal rate) {
        String scope = '산업군 "' + industry + '"';
        if (productType != null) {
            scope += ', 상품 유형 "' + productType + '"';
        }
        return scope + ' 기준 종결 기회 ' + total + '건 중 ' + won + '건 성사 (Won 비율 ' + rate + '%).';
    }

    private static String trimToNull(String value) {
        if (value == null) {
            return null;
        }
        String trimmed = value.trim();
        return trimmed.length() == 0 ? null : trimmed;
    }
}