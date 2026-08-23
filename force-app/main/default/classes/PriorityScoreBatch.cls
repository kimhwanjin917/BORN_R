/**
 * 기업 영업 우선순위 점수(Priority_Score__c, 0~100 정수)를 결정적으로 재계산하는 배치.
 *
 * 대상: 발굴 Lead(IsConverted=false, Status='New') 와 Account. 스케줄러가 두 대상을 각각 기동한다.
 *
 * 채점(총 100점):
 *   1) 상품 적합도 40점 — 현금자산비율(RP) 과 차입금의존도(회사채) 중 점수가 높은 쪽을 그 기업의 상품으로 정한다.
 *   2) 니즈 규모 30점 — 정해진 상품의 운용 가능 자금(절대 금액)으로 채점.
 *   3) 최신 공시 30점 — 정해진 상품 자금의 전년 동기(직전 연간) 대비 증가율.
 *
 * 제외(점수 null 로 저장 → 목록에서 빠짐):
 *   - 자본잠식(Total_Equity__c <= 0)
 *   - 이미 영업 진행 중(Lead: Status != 'New' 는 애초 대상에서 빠짐 / Account: 열린 Opportunity 보유)
 * 적합도 0점 기업은 제외가 아니라 낮은 점수로 남겨 최하위로 깔린다.
 *
 * 결정성: 최신/직전 연간은 Period_Type__c='연간' 중 Fiscal_Year__c 로 선택하며,
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

    // ─── 적합도 임계값 (비율, 예: 0.12 = 12%) ────────────────────────────────
    private static final Decimal CASH_RATIO_T40 = 0.12;
    private static final Decimal CASH_RATIO_T20 = 0.06;
    private static final Decimal DEBT_RATIO_T40 = 0.25;
    private static final Decimal DEBT_RATIO_T20 = 0.12;

    // ─── 니즈 규모 임계값 (원화, 상품별) ─────────────────────────────────────
    private static final Decimal RP_NEED_T30 = 30000000000L;    // RP 300억
    private static final Decimal RP_NEED_T15 = 10000000000L;    // RP 100억
    private static final Decimal BOND_NEED_T30 = 300000000000L; // 회사채 3,000억
    private static final Decimal BOND_NEED_T15 = 100000000000L; // 회사채 1,000억

    // ─── 최신 공시(YoY 증가율) 임계값 ────────────────────────────────────────
    private static final Decimal YOY_T30 = 0.30; // 30% 이상 증가
    private static final Decimal YOY_T20 = 0.10; // 10~30% 증가

    private static final String ANNUAL_PERIOD = '연간';
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
     * Lead 는 발굴 단계(Status='New')만, Account 는 전체를 조회하고 execute 에서 제외 판정을 적용한다.
     * @param context 배치 컨텍스트
     * @return 대상 레코드 QueryLocator
     */
    public Database.QueryLocator start(Database.BatchableContext context) {
        if (targetKind == Target.LEAD) {
            return Database.getQueryLocator([
                SELECT Id, Priority_Score__c
                FROM Lead
                WHERE IsConverted = false AND Status = 'New'
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
        loadAnnualStatements(targetIds, latestByTarget, priorByTarget);

        Set<Id> excludedByOpenDeal = targetKind == Target.ACCOUNT
            ? loadAccountsWithOpenOpportunity(targetIds)
            : new Set<Id>();
        Map<Id, Integer> latestDisclosureYearByTarget = loadLatestDisclosureYears(targetIds);

        List<SObject> recordsToUpdate = new List<SObject>();
        for (SObject record : scope) {
            Id targetId = record.Id;
            CorporateFinancialStatement__c latest = latestByTarget.get(targetId);
            Integer newScore = computeScore(
                latest,
                priorByTarget.get(targetId),
                latestDisclosureYearByTarget.get(targetId),
                excludedByOpenDeal.contains(targetId)
            );
            Object currentScore = record.get('Priority_Score__c');
            Integer currentInt = currentScore == null ? null : Integer.valueOf(currentScore);
            if (newScore != currentInt) {
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
     * 제외 대상(자본잠식·영업중)이거나 최신 재무가 없으면 null 을 반환한다.
     * @param latest 최신 연간 재무제표(없으면 null)
     * @param prior 직전 연간 재무제표(없으면 null)
     * @param latestDisclosureYear 최신 공시 시그널의 연도(없으면 null)
     * @param excludedByOpenDeal 열린 Opportunity 로 영업 진행 중이면 true
     * @return 0~100 정수 점수 또는 null(제외/데이터 없음)
     */
    private Integer computeScore(
        CorporateFinancialStatement__c latest,
        CorporateFinancialStatement__c prior,
        Integer latestDisclosureYear,
        Boolean excludedByOpenDeal
    ) {
        if (excludedByOpenDeal || latest == null) {
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
        Decimal cashRatio = cashFund / totalAssets;
        Decimal debtRatio = bondFund / totalAssets;

        Integer cashFitScore = scoreCashFit(cashRatio);
        Integer debtFitScore = scoreDebtFit(debtRatio);

        // 상품 결정: 적합도 점수가 높은 쪽. 동점이면 RP 우선.
        Product productKind = debtFitScore > cashFitScore ? Product.BOND : Product.RP;
        Integer fitScore = productKind == Product.BOND ? debtFitScore : cashFitScore;

        Decimal fund = productKind == Product.RP ? cashFund : bondFund;
        Integer needScore = scoreNeed(productKind, fund);
        Integer disclosureScore = scoreDisclosure(latest, prior, latestDisclosureYear, productKind);

        return fitScore + needScore + disclosureScore;
    }

    private Integer scoreCashFit(Decimal cashRatio) {
        if (cashRatio >= CASH_RATIO_T40) {
            return 40;
        }
        if (cashRatio >= CASH_RATIO_T20) {
            return 20;
        }
        return 0;
    }

    private Integer scoreDebtFit(Decimal debtRatio) {
        if (debtRatio >= DEBT_RATIO_T40) {
            return 40;
        }
        if (debtRatio >= DEBT_RATIO_T20) {
            return 20;
        }
        return 0;
    }

    private Integer scoreNeed(Product productKind, Decimal fund) {
        Decimal t30 = productKind == Product.RP ? RP_NEED_T30 : BOND_NEED_T30;
        Decimal t15 = productKind == Product.RP ? RP_NEED_T15 : BOND_NEED_T15;
        if (fund >= t30) {
            return 30;
        }
        if (fund >= t15) {
            return 15;
        }
        return 0;
    }

    /**
     * 최신 공시 점수(30점). 상품 자금의 전년(직전 연간) 대비 증가율로 채점하되,
     * 최신 CFS 보다 미래 연도의 공시 시그널이 있으면(=새 공시는 떴으나 재무 미수집) 0점.
     * 직전 연간이 없어 비교 불가하면 규정에 따라 10점.
     */
    private Integer scoreDisclosure(
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
            return 10; // 비교할 직전 공시 없음
        }
        Decimal priorFund = sumFund(prior, productKind);
        if (priorFund == null || priorFund <= 0) {
            return 10;
        }
        Decimal latestFund = sumFund(latest, productKind);
        Decimal growth = (latestFund - priorFund) / priorFund;
        if (growth >= YOY_T30) {
            return 30;
        }
        if (growth >= YOY_T20) {
            return 20;
        }
        return 10; // 10% 미만 증가 또는 감소
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

    // ─── 관련 레코드 로딩 ─────────────────────────────────────────────────

    /**
     * 대상별 최신·직전 연간 재무제표를 채운다.
     * Fiscal_Year__c DESC, Id ASC 로 조회해 대상별 1번째=최신, 2번째=직전으로 결정적으로 선택한다.
     * @param targetIds 대상 Id 집합
     * @param latestByTarget (출력) 대상 Id → 최신 연간
     * @param priorByTarget (출력) 대상 Id → 직전 연간
     */
    private void loadAnnualStatements(
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
                SELECT Id, Lead__c, Fiscal_Year__c, Total_Assets__c, Total_Equity__c,
                       Cash_And_Equivalents__c, Short_Term_Financial_Instruments__c,
                       Short_Term_Borrowings__c, Long_Term_Borrowings__c, Bonds_Payable__c
                FROM CorporateFinancialStatement__c
                WHERE Lead__c IN :targetIds AND Period_Type__c = :ANNUAL_PERIOD
                ORDER BY Fiscal_Year__c DESC NULLS LAST, Id ASC
            ]
            : [
                SELECT Id, Account__c, Fiscal_Year__c, Total_Assets__c, Total_Equity__c,
                       Cash_And_Equivalents__c, Short_Term_Financial_Instruments__c,
                       Short_Term_Borrowings__c, Long_Term_Borrowings__c, Bonds_Payable__c
                FROM CorporateFinancialStatement__c
                WHERE Account__c IN :targetIds AND Period_Type__c = :ANNUAL_PERIOD
                ORDER BY Fiscal_Year__c DESC NULLS LAST, Id ASC
            ];

        for (CorporateFinancialStatement__c statement : statements) {
            Id targetId = (Id) statement.get(relationship);
            if (targetId == null) {
                continue;
            }
            if (!latestByTarget.containsKey(targetId)) {
                latestByTarget.put(targetId, statement);
            } else if (!priorByTarget.containsKey(targetId)) {
                priorByTarget.put(targetId, statement);
            }
        }
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

    /**
     * 열린 Opportunity(IsClosed=false)를 가진 Account Id 집합을 반환한다(영업 진행 중 제외용).
     * @param accountIds Account Id 집합
     * @return 열린 딜을 보유한 Account Id 집합
     */
    private Set<Id> loadAccountsWithOpenOpportunity(Set<Id> accountIds) {
        Set<Id> withOpenDeal = new Set<Id>();
        if (accountIds.isEmpty()) {
            return withOpenDeal;
        }
        for (Opportunity opp : [
            SELECT AccountId
            FROM Opportunity
            WHERE AccountId IN :accountIds AND IsClosed = false
        ]) {
            withOpenDeal.add(opp.AccountId);
        }
        return withOpenDeal;
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