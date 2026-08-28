/**
 * 기업 영업 우선순위 점수(Priority_Score__c, 0~100 · 소수 1자리)를 결정적으로 재계산하는 배치.
 *
 * 대상: 발굴 Lead(IsConverted=false, Status='신규') 와 Account. 스케줄러가 두 대상을 각각 기동한다.
 *
 * 채점(총 100점, 소수 1자리) — 각 항목은 계단식이 아니라 실제 값에 비례하는 "연속" 점수라
 * 기업마다 서로 다른 점수가 나오고, 만점 기준을 높여 100.0 은 세 항목을 동시에 최상단으로
 * 채운 사실상 1개 기업에서만 나온다:
 *   1) 상품 적합도 40점 — 현금자산비율(RP)·차입금의존도(회사채)를 각각 연속 채점해 높은 쪽을 상품으로 정한다.
 *        RP:   6%→7 · 12%→20 · 30%→40 (구간 선형보간).
 *        회사채: 12%→7 · 25%→20 · 50%→40 (구간 선형보간).
 *   2) 니즈 규모 30점 — 정해진 상품의 운용 가능 자금을 로그 보간(0~27) 후 규모 프리미엄(27→30 점근)으로 채점.
 *        RP:   10억→0 · 100억→13.5 · 1,000억→27 · 이후 규모 클수록 30 근접(1조≈29.7).
 *        회사채: 100억→0 · 1,000억→13.5 · 1조→27 · 이후 30 근접.
 *        (같은 REF 초과 대형 기업끼리 자금 규모로 점수가 갈려 최상단 만점 동점이 사라진다.)
 *   3) 최신 공시 30점 — 정해진 상품 자금의 전년 동기 대비 증가율(YoY)을 연속 채점.
 *        -10%→0 · +10%→10 · +30%→22 · +50%→30 (구간 선형보간).
 *
 * 제외(점수 null 로 저장 → 목록에서 빠짐):
 *   - 자본잠식(Total_Equity__c <= 0)
 *   - 비율 산정 불가(Total_Assets__c <= 0)
 * 이미 영업 진행 중(Lead 비신규 상태·Account 열린 Opportunity)이어도 제외하지 않는다.
 * 기존 거래처도 다른 상품을 추가로 판매할 여지가 있어 우선순위 목록에 남긴다.
 * 적합도가 낮은 기업은 제외가 아니라 낮은 점수로 남겨 최하위로 깔린다.
 *
 * 결정성: 최신은 연간·반기·분기 전체에서 (Fiscal_Year__c, 보고서 서수)가 가장 최근인 공시를 고르고,
 * 직전은 그 전년 동기(동일 보고서 코드, Fiscal_Year__c-1)로 잡는다. 보고서 코드는 External_Key__c 에서 파싱한다.
 * 모든 계산이 필드 값의 순수 함수라 재실행 시 동일 결과를 보장한다.
 * 정렬(동점 시 자금 큰 순)은 리포트/리스트뷰의 몫이며 배치는 정수 점수만 저장한다.
 *
 * @example
 * PriorityScoreBatch.runAll();
 * Database.executeBatch(new PriorityScoreBatch(PriorityScoreBatch.Target.LEAD), 200);
 */
// 스케줄 소유자의 FLS 에 배치 성공이 좌우되지 않도록 시스템 모드로 조회·갱신한다(레코드 공유는 with sharing 유지).
public with sharing class PriorityScoreBatch implements Database.Batchable<SObject>, Schedulable {

    /** 점수를 매길 대상 SObject. 관계 필드와 쿼리를 결정한다. */
    public enum Target { LEAD, ACCOUNT }

    /** 기업에 정해지는 금융 상품. */
    private enum Product { RP, BOND }

    // ─── 항목별 최대 배점 ────────────────────────────────────────────────────
    private static final Decimal NEED_MAX = 30;
    // 니즈 상단 동점을 절대 규모로 갈라내는 "규모 프리미엄" 상한. REF 초과분에서 (NEED_MAX-PREMIUM)→NEED_MAX 에 점근.
    private static final Decimal NEED_PREMIUM = 3;

    // ─── 적합도(연속) 구간 보간 앵커 — (비율, 점수). 오름차순. ─────────────────
    //  RP 현금자산비율:   6%→7 · 12%→20 · 30%→40 (30% 이상 40점 클램프)
    private static final List<Decimal> CASH_FIT_X = new List<Decimal>{ 0, 0.06, 0.12, 0.30 };
    private static final List<Decimal> CASH_FIT_Y = new List<Decimal>{ 0, 7, 20, 40 };
    //  회사채 차입금의존도: 12%→7 · 25%→20 · 50%→40 (50% 이상 40점 클램프)
    private static final List<Decimal> DEBT_FIT_X = new List<Decimal>{ 0, 0.12, 0.25, 0.50 };
    private static final List<Decimal> DEBT_FIT_Y = new List<Decimal>{ 0, 7, 20, 40 };

    // ─── 니즈(로그 보간+규모 프리미엄) 경계 — 원화. FLOOR→0점, REF→27점, 이후 규모 클수록 30 점근. ──
    private static final Decimal RP_NEED_FLOOR = 1000000000L;    // RP 10억 → 0
    private static final Decimal RP_NEED_REF = 100000000000L;    // RP 1,000억 → 27(이후 규모 클수록 30 근접)
    private static final Decimal BOND_NEED_FLOOR = 10000000000L; // 회사채 100억 → 0
    private static final Decimal BOND_NEED_REF = 1000000000000L; // 회사채 1조 → 27(이후 30 근접)

    // ─── 최신 공시(YoY 증가율, 연속) 구간 보간 앵커 — (증가율, 점수). 오름차순. ──
    //  -10%→0 · +10%→10 · +30%→22 · +50%→30 (-10% 이하 0, +50% 이상 30 클램프)
    private static final List<Decimal> YOY_X = new List<Decimal>{ -0.10, 0.10, 0.30, 0.50 };
    private static final List<Decimal> YOY_Y = new List<Decimal>{ 0, 10, 22, 30 };
    // 직전 공시가 없어 YoY 비교가 불가할 때의 중립 점수.
    private static final Decimal DISCLOSURE_NO_PRIOR = 10;

    // 저장 소수 자리수(필드 scale 과 일치). 재실행 결정성을 위해 반올림 후 비교·저장한다.
    private static final Integer SCORE_SCALE = 1;

    private static final String DISCLOSURE_SIGNAL = '공시';
    private static final Integer DEFAULT_BATCH_SIZE = 200;

    private final Target targetKind;

    /**
     * @param targetKind 점수를 매길 대상(LEAD 또는 ACCOUNT)
     */
    public PriorityScoreBatch(Target targetKind) {
        if (targetKind == null) {
            throw new IllegalArgumentException('target 은 필수입니다.');
        }
        this.targetKind = targetKind;
    }

    // ─── Schedulable ─────────────────────────────────────────────────────

    /**
     * 스케줄 실행 진입점. Lead 와 Account 배치를 각각 기동한다.
     * @param context 스케줄 컨텍스트
     */
    public void execute(SchedulableContext context) {
        runAll();
    }

    // ─── Batchable ───────────────────────────────────────────────────────

    /**
     * 점수 산정 후보 레코드를 조회한다.
     * Lead 는 미전환 전체, Account 는 전체를 조회한다(영업 진행 여부로 제외하지 않는다).
     * @param context 배치 컨텍스트
     * @return 대상 레코드 QueryLocator
     */
    public Database.QueryLocator start(Database.BatchableContext context) {
        if (targetKind == Target.LEAD) {
            return Database.getQueryLocator([
                SELECT Id, Priority_Score__c
                FROM Lead
                WHERE IsConverted = false
            ]);
        }
        return Database.getQueryLocator([
            SELECT Id, Priority_Score__c
            FROM Account
        ]);
    }

    /**
     * 각 청크의 대상에 대해 최신/직전 연간 재무제표와 공시 시그널을 모아 점수를 계산하고,
     * 값이 바뀐 레코드만 부분 성공 DML 로 갱신한다.
     * @param context 배치 컨텍스트
     * @param scope 현재 청크의 대상 레코드
     */
    public void execute(Database.BatchableContext context, List<SObject> scope) {
        Set<Id> targetIds = new Map<Id, SObject>(scope).keySet();

        Map<Id, CorporateFinancialStatement__c> latestByTarget = new Map<Id, CorporateFinancialStatement__c>();
        Map<Id, CorporateFinancialStatement__c> priorByTarget = new Map<Id, CorporateFinancialStatement__c>();
        loadRecentStatements(targetIds, latestByTarget, priorByTarget);

        Map<Id, Integer> latestDisclosureYearByTarget = loadLatestDisclosureYears(targetIds);

        List<SObject> recordsToUpdate = new List<SObject>();
        for (SObject record : scope) {
            Id targetId = record.Id;
            CorporateFinancialStatement__c latest = latestByTarget.get(targetId);
            Decimal newScore = computeScore(
                latest,
                priorByTarget.get(targetId),
                latestDisclosureYearByTarget.get(targetId)
            );
            Object currentRaw = record.get('Priority_Score__c');
            Decimal current = currentRaw == null
                ? null
                : ((Decimal) currentRaw).setScale(SCORE_SCALE, System.RoundingMode.HALF_UP);
            if (newScore != current) {
                record.put('Priority_Score__c', newScore);
                recordsToUpdate.add(record);
            }
        }

        if (!recordsToUpdate.isEmpty()) {
            Database.update(recordsToUpdate, false);
        }
    }

    /**
     * 후처리 없음. 각 청크가 부분 성공 DML 로 격리 처리되므로 별도 마무리가 불필요하다.
     * @param context 배치 컨텍스트
     */
    public void finish(Database.BatchableContext context) {
        return;
    }

    // ─── 점수 계산 ───────────────────────────────────────────────────────

    /**
     * 최신/직전 연간 재무제표와 공시 상태로 총점(0~100)을 계산한다.
     * 제외 대상(자본잠식·비율 산정 불가)이거나 최신 재무가 없으면 null 을 반환한다.
     * @param latest 최신 연간 재무제표(없으면 null)
     * @param prior 직전 연간 재무제표(없으면 null)
     * @param latestDisclosureYear 최신 공시 시그널의 연도(없으면 null)
     * @return 0~100(소수 1자리) 점수 또는 null(제외/데이터 없음)
     */
    private Decimal computeScore(
        CorporateFinancialStatement__c latest,
        CorporateFinancialStatement__c prior,
        Integer latestDisclosureYear
    ) {
        if (latest == null) {
            return null;
        }
        if (latest.Total_Equity__c == null || latest.Total_Equity__c <= 0) {
            return null; // 자본잠식 제외
        }
        Decimal totalAssets = latest.Total_Assets__c;
        if (totalAssets == null || totalAssets <= 0) {
            return null; // 비율 산정 불가 → 제외
        }

        Decimal cashFund = sumFund(latest, Product.RP);
        Decimal bondFund = sumFund(latest, Product.BOND);
        Decimal cashFitScore = scoreCashFit(cashFund / totalAssets);
        Decimal debtFitScore = scoreDebtFit(bondFund / totalAssets);

        // 상품 결정: 적합도 점수가 높은 쪽. 동점이면 RP 우선.
        Product productKind = debtFitScore > cashFitScore ? Product.BOND : Product.RP;
        Decimal fitScore = productKind == Product.BOND ? debtFitScore : cashFitScore;

        Decimal fund = productKind == Product.RP ? cashFund : bondFund;
        Decimal needScore = scoreNeed(productKind, fund);
        Decimal disclosureScore = scoreDisclosure(latest, prior, latestDisclosureYear, productKind);

        Decimal total = fitScore + needScore + disclosureScore;
        return total.setScale(SCORE_SCALE, System.RoundingMode.HALF_UP);
    }

    // 현금자산비율을 앵커 구간(6%→7·12%→20·30%→40)으로 선형보간한다.
    private Decimal scoreCashFit(Decimal cashRatio) {
        return piecewise(cashRatio, CASH_FIT_X, CASH_FIT_Y);
    }

    // 차입금의존도를 앵커 구간(12%→7·25%→20·50%→40)으로 선형보간한다.
    private Decimal scoreDebtFit(Decimal debtRatio) {
        return piecewise(debtRatio, DEBT_FIT_X, DEBT_FIT_Y);
    }

    /**
     * 니즈 규모(30점). 두 구간으로 채점한다.
     *  1) FLOOR~REF: 자금을 로그 스케일로 0 ~ (NEED_MAX-PREMIUM=27) 점 보간(금액이 수십~수백 배 벌어져 로그).
     *  2) REF 초과: 절대 규모가 클수록 27→30 에 점근하는 규모 프리미엄 PREMIUM*(1 - REF/fund) 가산.
     * 덕분에 REF 를 넘긴 대형 기업끼리도 자금 규모로 점수가 갈려 최상단 동점(만점 몰림)이 사라진다.
     */
    private Decimal scoreNeed(Product productKind, Decimal fund) {
        Decimal floorFund = productKind == Product.RP ? RP_NEED_FLOOR : BOND_NEED_FLOOR;
        Decimal refFund = productKind == Product.RP ? RP_NEED_REF : BOND_NEED_REF;
        if (fund == null || fund <= floorFund) {
            return 0;
        }
        Decimal baseMax = NEED_MAX - NEED_PREMIUM; // REF 에서의 기본 점수(27)
        if (fund <= refFund) {
            Double span = Math.log10(refFund.doubleValue()) - Math.log10(floorFund.doubleValue());
            Double pos = Math.log10(fund.doubleValue()) - Math.log10(floorFund.doubleValue());
            return baseMax * Decimal.valueOf(pos / span);
        }
        // REF 초과분: 규모가 클수록 0→PREMIUM 에 점근(fund=REF→0, fund=10·REF→0.9·PREMIUM …).
        return baseMax + NEED_PREMIUM * (1 - refFund / fund);
    }

    /**
     * 최신 공시 점수(30점). 상품 자금의 전년 동기 대비 증가율(YoY)을 앵커 구간
     * (-10%→0·+10%→10·+30%→22·+50%→30)으로 선형보간한다. 단,
     * 최신 CFS 보다 미래 연도의 공시 시그널이 있으면(=새 공시는 떴으나 재무 미수집) 0점,
     * 전년 동기가 없어 비교 불가하면 중립 점수(10점).
     */
    private Decimal scoreDisclosure(
        CorporateFinancialStatement__c latest,
        CorporateFinancialStatement__c prior,
        Integer latestDisclosureYear,
        Product productKind
    ) {
        Integer latestFiscalYear = latest.Fiscal_Year__c == null ? null : latest.Fiscal_Year__c.intValue();
        if (latestDisclosureYear != null && latestFiscalYear != null && latestDisclosureYear > latestFiscalYear) {
            return 0; // 새 공시 게시됐으나 재무 데이터 미수집
        }
        if (prior == null) {
            return DISCLOSURE_NO_PRIOR; // 비교할 직전 공시 없음 → 중립
        }
        Decimal priorFund = sumFund(prior, productKind);
        if (priorFund == null || priorFund <= 0) {
            return DISCLOSURE_NO_PRIOR;
        }
        Decimal latestFund = sumFund(latest, productKind);
        Decimal growth = (latestFund - priorFund) / priorFund;
        return piecewise(growth, YOY_X, YOY_Y);
    }

    /**
     * 상품별 운용 가능 자금(원화)을 합산한다.
     * RP = 현금및현금성자산 + 단기금융상품, 회사채 = 단기차입금 + 장기차입금 + 사채.
     */
    private Decimal sumFund(CorporateFinancialStatement__c statement, Product productKind) {
        if (productKind == Product.RP) {
            return zero(statement.Cash_And_Equivalents__c) + zero(statement.Short_Term_Financial_Instruments__c);
        }
        return zero(statement.Short_Term_Borrowings__c)
            + zero(statement.Long_Term_Borrowings__c)
            + zero(statement.Bonds_Payable__c);
    }

    private Decimal zero(Decimal value) {
        return value == null ? 0 : value;
    }

    /**
     * 오름차순 앵커 (xs[i], ys[i]) 사이를 선형보간한다. x 가 범위를 벗어나면 양 끝 y 로 클램프한다.
     * 계단식 대신 실제 값에 비례한 연속 점수를 만들어 기업별 점수 다양성을 확보한다.
     * @param x 채점 입력값(비율·증가율 등)
     * @param xs 오름차순 경계값
     * @param ys 각 경계의 점수
     * @return 보간된 점수
     */
    private Decimal piecewise(Decimal x, List<Decimal> xs, List<Decimal> ys) {
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

    // ─── 관련 레코드 로딩 ─────────────────────────────────────────────────

    /**
     * 대상별 '가장 최근 공시' 재무제표와 그 전년 동기 재무제표를 채운다.
     * 최신은 연간·반기·분기 전체에서 recencyKey(Fiscal_Year*10 + 보고서 서수)가 가장 큰 것으로 결정한다.
     * 전년 동기(prior)는 최신과 동일 보고서 코드의 Fiscal_Year__c-1 레코드로, YoY 를 동일 분기끼리 비교한다.
     * (분기 잔액 기반 적합도·니즈는 연간과 동일 스케일이라 임계값을 그대로 쓴다.)
     * @param targetIds 대상 Id 집합
     * @param latestByTarget (출력) 대상 Id → 최신 공시
     * @param priorByTarget (출력) 대상 Id → 전년 동기
     */
    private void loadRecentStatements(
        Set<Id> targetIds,
        Map<Id, CorporateFinancialStatement__c> latestByTarget,
        Map<Id, CorporateFinancialStatement__c> priorByTarget
    ) {
        if (targetIds.isEmpty()) {
            return;
        }
        String relationship = relationshipField();
        List<CorporateFinancialStatement__c> statements = targetKind == Target.LEAD
            ? [
                SELECT Id, Lead__c, Fiscal_Year__c, Period_Type__c, External_Key__c,
                       Total_Assets__c, Total_Equity__c,
                       Cash_And_Equivalents__c, Short_Term_Financial_Instruments__c,
                       Short_Term_Borrowings__c, Long_Term_Borrowings__c, Bonds_Payable__c
                FROM CorporateFinancialStatement__c
                WHERE Lead__c IN :targetIds
                ORDER BY Fiscal_Year__c DESC NULLS LAST, Id ASC
            ]
            : [
                SELECT Id, Account__c, Fiscal_Year__c, Period_Type__c, External_Key__c,
                       Total_Assets__c, Total_Equity__c,
                       Cash_And_Equivalents__c, Short_Term_Financial_Instruments__c,
                       Short_Term_Borrowings__c, Long_Term_Borrowings__c, Bonds_Payable__c
                FROM CorporateFinancialStatement__c
                WHERE Account__c IN :targetIds
                ORDER BY Fiscal_Year__c DESC NULLS LAST, Id ASC
            ];

        // 대상별로 모아 두고, 최신(최대 recencyKey)과 전년 동기를 각각 결정한다.
        Map<Id, List<CorporateFinancialStatement__c>> byTarget =
            new Map<Id, List<CorporateFinancialStatement__c>>();
        for (CorporateFinancialStatement__c statement : statements) {
            Id targetId = (Id) statement.get(relationship);
            if (targetId == null) {
                continue;
            }
            if (!byTarget.containsKey(targetId)) {
                byTarget.put(targetId, new List<CorporateFinancialStatement__c>());
            }
            byTarget.get(targetId).add(statement);
        }

        for (Id targetId : byTarget.keySet()) {
            List<CorporateFinancialStatement__c> stmts = byTarget.get(targetId);
            CorporateFinancialStatement__c latest = null;
            Integer latestKey = null;
            for (CorporateFinancialStatement__c statement : stmts) {
                Integer key = recencyKey(statement);
                if (latest == null || key > latestKey) {
                    latest = statement;
                    latestKey = key;
                }
            }
            if (latest == null) {
                continue;
            }
            latestByTarget.put(targetId, latest);

            // 전년 동기: 최신과 같은 보고서 코드 & Fiscal_Year-1 (없으면 prior 없음 → 공시 10점 규정 적용)
            String latestCode = reportCodeOf(latest);
            Integer priorYear = latest.Fiscal_Year__c == null ? null : latest.Fiscal_Year__c.intValue() - 1;
            if (priorYear == null) {
                continue;
            }
            for (CorporateFinancialStatement__c statement : stmts) {
                Integer year = statement.Fiscal_Year__c == null ? null : statement.Fiscal_Year__c.intValue();
                if (year == priorYear && sameCode(reportCodeOf(statement), latestCode)) {
                    priorByTarget.put(targetId, statement);
                    break;
                }
            }
        }
    }

    // (Fiscal_Year*10 + 보고서 서수). 연도·분기를 단조 증가 정수 하나로 만들어 최신 공시를 결정한다.
    private Integer recencyKey(CorporateFinancialStatement__c statement) {
        Integer year = statement.Fiscal_Year__c == null ? 0 : statement.Fiscal_Year__c.intValue();
        return year * 10 + periodOrdinal(statement);
    }

    // 보고서 코드/기간유형 → 연내 서수(1분기 11013=1, 반기 11012=2, 3분기 11014=3, 사업보고서 11011=4).
    // External_Key 파싱 실패 시 Period_Type__c(1~4분기) 로 폴백한다.
    private Integer periodOrdinal(CorporateFinancialStatement__c statement) {
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

    // External_Key__c(corpCode_year_reportCode)의 마지막 세그먼트(보고서 코드)를 반환한다.
    private String reportCodeOf(CorporateFinancialStatement__c statement) {
        if (String.isBlank(statement.External_Key__c)) {
            return null;
        }
        List<String> parts = statement.External_Key__c.split('_');
        return parts.size() >= 3 ? parts[parts.size() - 1] : null;
    }

    // 두 보고서 코드가 모두 존재하고 동일한지. null(파싱 실패)끼리는 같지 않음으로 처리해 오매칭을 막는다.
    private Boolean sameCode(String a, String b) {
        return a != null && a == b;
    }

    /**
     * 대상별 최신 공시(Signal_Type__c='공시') 시그널의 연도를 반환한다.
     * @param targetIds 대상 Id 집합
     * @return 대상 Id → 최신 공시 연도(공시가 없는 대상은 미포함)
     */
    private Map<Id, Integer> loadLatestDisclosureYears(Set<Id> targetIds) {
        Map<Id, Integer> yearByTarget = new Map<Id, Integer>();
        if (targetIds.isEmpty()) {
            return yearByTarget;
        }
        String relationship = relationshipField();
        List<ExternalSignal__c> signals = targetKind == Target.LEAD
            ? [
                SELECT Lead__c, Signal_Date__c
                FROM ExternalSignal__c
                WHERE Lead__c IN :targetIds AND Signal_Type__c = :DISCLOSURE_SIGNAL AND Signal_Date__c != null
            ]
            : [
                SELECT Account__c, Signal_Date__c
                FROM ExternalSignal__c
                WHERE Account__c IN :targetIds AND Signal_Type__c = :DISCLOSURE_SIGNAL AND Signal_Date__c != null
            ];

        for (ExternalSignal__c signal : signals) {
            Id targetId = (Id) signal.get(relationship);
            if (targetId == null) {
                continue;
            }
            Integer signalYear = signal.Signal_Date__c.year();
            Integer existing = yearByTarget.get(targetId);
            if (existing == null || signalYear > existing) {
                yearByTarget.put(targetId, signalYear);
            }
        }
        return yearByTarget;
    }

    private String relationshipField() {
        return targetKind == Target.LEAD ? 'Lead__c' : 'Account__c';
    }

    // ─── 편의 메서드 ─────────────────────────────────────────────────────

    /**
     * Lead 와 Account 두 대상의 점수 재계산 배치를 각각 기동한다.
     */
    public static void runAll() {
        Database.executeBatch(new PriorityScoreBatch(Target.LEAD), DEFAULT_BATCH_SIZE);
        Database.executeBatch(new PriorityScoreBatch(Target.ACCOUNT), DEFAULT_BATCH_SIZE);
    }

    /**
     * 매일 새벽 3시에 두 대상 점수를 재계산하도록 스케줄한다.
     * @return 스케줄된 잡 Id
     */
    public static String scheduleDaily() {
        return System.schedule(
            'PriorityScoreBatch - Daily 3AM',
            '0 0 3 * * ?',
            new PriorityScoreBatch(Target.LEAD)
        );
    }
}