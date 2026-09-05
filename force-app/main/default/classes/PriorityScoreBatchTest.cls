/**
 * PriorityScoreBatch 테스트.
 * 상품 결정(비율 기반), 3개 항목 채점, 제외(자본잠식·영업중), null 유지, 재실행 결정성,
 * 공시 YoY/미수집 판정, Account 경로를 배치 경계에서 검증한다.
 *
 * 테스트 데이터는 팀 동결 파일 TestDataFactory 를 수정하지 않기 위해
 * (Account 생성만 팩토리를 재사용하고) Lead/CFS/시그널/Opportunity 는 이 클래스의 헬퍼로 생성한다.
 */
@isTest
private class PriorityScoreBatchTest {

    // 원화 임계값
    private static final Decimal RP_FUND_FULL = 30000000000L;    // RP 300억 → 니즈 30
    private static final Decimal BOND_FUND_FULL = 300000000000L; // 회사채 3,000억 → 니즈 30
    private static final Decimal ASSETS = 100000000000L;         // 자산총계 1000억

    @isTest
    static void shouldScoreRpLead_WhenCashRatioHighAndFundLarge() {
        // Given: 현금자산비율 = 300억/1000억 = 30% → 적합도 40(만점)
        //        RP 자금 300억 → 니즈 로그보간 19.9 / 직전 연간 없음 → 공시 10 = 총 69.9
        Lead lead = createLead('RP Lead');
        insertStatement(lead.Id, null, 2023, ASSETS, ASSETS, RP_FUND_FULL, 0);

        Test.startTest();
        Database.executeBatch(new PriorityScoreBatch(PriorityScoreBatch.Target.LEAD), 200);
        Test.stopTest();

        Lead result = [SELECT Priority_Score__c FROM Lead WHERE Id = :lead.Id];
        Assert.areEqual(69.9, result.Priority_Score__c, '적합도40 + 니즈19.9 + 공시10 = 69.9 이어야 한다');
    }

    @isTest
    static void shouldChooseBond_WhenDebtRatioBeatsCashRatio() {
        // Given: 현금 60억(6% → 적합도 7), 차입금 3,000억(자산比 300% → 적합도 40) → 회사채 선택
        //        회사채 자금 3,000억 → 니즈 로그보간 19.9 / 직전 없음 → 공시 10 = 총 69.9
        Lead lead = createLead('Bond Lead');
        insertStatement(lead.Id, null, 2023, ASSETS, ASSETS, 6000000000L, BOND_FUND_FULL);

        Test.startTest();
        Database.executeBatch(new PriorityScoreBatch(PriorityScoreBatch.Target.LEAD), 200);
        Test.stopTest();

        Lead result = [SELECT Priority_Score__c FROM Lead WHERE Id = :lead.Id];
        Assert.areEqual(69.9, result.Priority_Score__c, '회사채 적합도40 + 니즈19.9 + 공시10 = 69.9 이어야 한다');
    }

    @isTest
    static void shouldExcludeAndNull_WhenCapitalImpaired() {
        // Given: 자본총계 0 이하 → 자본잠식 제외 → null
        Lead lead = createLead('Impaired Lead');
        insertStatement(lead.Id, null, 2023, ASSETS, -1, RP_FUND_FULL, 0);

        Test.startTest();
        Database.executeBatch(new PriorityScoreBatch(PriorityScoreBatch.Target.LEAD), 200);
        Test.stopTest();

        Lead result = [SELECT Priority_Score__c FROM Lead WHERE Id = :lead.Id];
        Assert.areEqual(null, result.Priority_Score__c, '자본잠식 기업은 제외되어 null 이어야 한다');
    }

    @isTest
    static void shouldKeepNull_WhenLeadHasNoStatement() {
        // Given: 재무제표 없음 → null
        Lead lead = createLead('Empty Lead');

        Test.startTest();
        Database.executeBatch(new PriorityScoreBatch(PriorityScoreBatch.Target.LEAD), 200);
        Test.stopTest();

        Lead result = [SELECT Priority_Score__c FROM Lead WHERE Id = :lead.Id];
        Assert.areEqual(null, result.Priority_Score__c, '재무 데이터가 없으면 null 이어야 한다');
    }

    @isTest
    static void shouldKeepZeroFit_WhenBothRatiosLow() {
        // Given: 현금 10억(1% → 적합도 1.2), 차입금 10억(1% → 적합도 0.6) → 상품 RP(높은 쪽)
        //        RP 자금 10억(FLOOR) → 니즈 0 / 직전 없음 → 공시 10 = 총 11.2 (제외 아님, 최하위)
        Lead lead = createLead('Low Fit Lead');
        insertStatement(lead.Id, null, 2023, ASSETS, ASSETS, 1000000000L, 1000000000L);

        Test.startTest();
        Database.executeBatch(new PriorityScoreBatch(PriorityScoreBatch.Target.LEAD), 200);
        Test.stopTest();

        Lead result = [SELECT Priority_Score__c FROM Lead WHERE Id = :lead.Id];
        Assert.areEqual(11.2, result.Priority_Score__c, '적합도 낮은 기업도 제외 아닌 낮은 점수(11.2)로 남아야 한다');
    }

    @isTest
    static void shouldScoreDisclosure30_WhenFundGrewOver50Pct() {
        // Given: 직전 RP 자금 200억, 최신 300억 → +50% → 공시 30(만점)
        //        적합도 40(30%) + 니즈 19.9(300억) + 공시 30 = 89.9
        Lead lead = createLead('Growth Lead');
        insertStatement(lead.Id, null, 2022, ASSETS, ASSETS, 20000000000L, 0);
        insertStatement(lead.Id, null, 2023, ASSETS, ASSETS, RP_FUND_FULL, 0);

        Test.startTest();
        Database.executeBatch(new PriorityScoreBatch(PriorityScoreBatch.Target.LEAD), 200);
        Test.stopTest();

        Lead result = [SELECT Priority_Score__c FROM Lead WHERE Id = :lead.Id];
        Assert.areEqual(89.9, result.Priority_Score__c, 'YoY +50% → 공시 만점 30 → 총 89.9 이어야 한다');
    }

    @isTest
    static void shouldScoreDisclosure0_WhenNewDisclosureNotYetCollected() {
        // Given: 최신 재무는 2023, 그런데 2024 공시 시그널이 이미 존재 → 재무 미수집 → 공시 0
        //        적합도 40 + 니즈 19.9 + 공시 0 = 59.9
        Lead lead = createLead('Pending Disclosure Lead');
        insertStatement(lead.Id, null, 2023, ASSETS, ASSETS, RP_FUND_FULL, 0);
        insertDisclosureSignal(lead.Id, null, Date.newInstance(2024, 3, 15));

        Test.startTest();
        Database.executeBatch(new PriorityScoreBatch(PriorityScoreBatch.Target.LEAD), 200);
        Test.stopTest();

        Lead result = [SELECT Priority_Score__c FROM Lead WHERE Id = :lead.Id];
        Assert.areEqual(59.9, result.Priority_Score__c, '새 공시가 떴으나 재무 미수집이면 공시 0점 → 총 59.9');
    }

    @isTest
    static void shouldProduceSameScore_WhenRecomputedTwice() {
        // Given
        Lead lead = createLead('Idempotent Lead');
        insertStatement(lead.Id, null, 2023, ASSETS, ASSETS, RP_FUND_FULL, 0);

        // When: 1회차 배치
        Test.startTest();
        Database.executeBatch(new PriorityScoreBatch(PriorityScoreBatch.Target.LEAD), 200);
        Test.stopTest();
        Decimal firstRun = [SELECT Priority_Score__c FROM Lead WHERE Id = :lead.Id].Priority_Score__c;

        // 2회차: 값을 오염시킨 뒤 execute() 직접 재호출 → 동일 결과로 복원되는지 확인
        update new Lead(Id = lead.Id, Priority_Score__c = 1);
        List<SObject> scope = [SELECT Id, Priority_Score__c FROM Lead WHERE Id = :lead.Id];
        new PriorityScoreBatch(PriorityScoreBatch.Target.LEAD).execute((Database.BatchableContext) null, scope);
        Decimal secondRun = [SELECT Priority_Score__c FROM Lead WHERE Id = :lead.Id].Priority_Score__c;

        Assert.areEqual(69.9, firstRun, '1회차 점수는 69.9 이어야 한다');
        Assert.areEqual(firstRun, secondRun, '재실행해도 점수가 동일해야 한다');
    }

    @isTest
    static void shouldUseMostRecentQuarter_WhenQuarterlyNewerThanAnnual() {
        // Given: 2025 연간(현금 100억=10% → 적합 15.7, 니즈 13.5) vs 2026 반기(현금 300억=30% → 적합 40, 니즈 19.9)
        //        최신 공시는 2026 반기여야 하며, 전년 동기(2025 반기) 없음 → 공시 10 = 총 69.9.
        //        만약 연간을 최신으로 잘못 고르면 15.7+13.5+10=39.2 가 된다(구분 가능).
        Lead lead = createLead('Recent Quarter Lead');
        insertStatement(lead.Id, null, 2025, '11011', ASSETS, ASSETS, 10000000000L, 0);
        insertStatement(lead.Id, null, 2026, '11012', ASSETS, ASSETS, RP_FUND_FULL, 0);

        Test.startTest();
        Database.executeBatch(new PriorityScoreBatch(PriorityScoreBatch.Target.LEAD), 200);
        Test.stopTest();

        Lead result = [SELECT Priority_Score__c FROM Lead WHERE Id = :lead.Id];
        Assert.areEqual(69.9, result.Priority_Score__c, '더 최근 분기(2026 반기) 재무로 채점되어 69.9 이어야 한다');
    }

    @isTest
    static void shouldCompareSameQuarterYoY_WhenLatestIsQuarter() {
        // Given: 최신 2026 반기(300억). 전년 동기 2025 반기(200억) → +50% → 공시 30.
        //        2025 연간(290억)은 방해용: 전년 동기를 연간으로 잘못 매칭하면 +3.4% → 공시 6.7(총 66.7)이 된다.
        //        올바르게 반기끼리 비교하면 적합40+니즈19.9+공시30 = 89.9.
        Lead lead = createLead('Quarter YoY Lead');
        insertStatement(lead.Id, null, 2025, '11012', ASSETS, ASSETS, 20000000000L, 0);
        insertStatement(lead.Id, null, 2025, '11011', ASSETS, ASSETS, 29000000000L, 0);
        insertStatement(lead.Id, null, 2026, '11012', ASSETS, ASSETS, RP_FUND_FULL, 0);

        Test.startTest();
        Database.executeBatch(new PriorityScoreBatch(PriorityScoreBatch.Target.LEAD), 200);
        Test.stopTest();

        Lead result = [SELECT Priority_Score__c FROM Lead WHERE Id = :lead.Id];
        Assert.areEqual(89.9, result.Priority_Score__c, '전년 동기(2025 반기) 대비 +50% → 공시 30 → 총 89.9 이어야 한다');
    }

    @isTest
    static void shouldScoreAccount_WhenOpenOpportunityExists() {
        // Given: 열린 Opportunity(영업 진행 중)가 있어도 제외하지 않는다 — 추가 상품 판매 여지가 있어 우선순위에 남긴다.
        //        열린 딜 없는 동일 재무 케이스(shouldScoreAccount_WhenNoOpenOpportunity)와 같은 69.9 가 나와야 한다.
        Account account = TestDataFactory.createAccount('90000001', true);
        insertStatement(null, account.Id, 2023, ASSETS, ASSETS, RP_FUND_FULL, 0);
        insert new Opportunity(
            Name = 'Open Deal',
            AccountId = account.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addMonths(1)
        );

        Test.startTest();
        Database.executeBatch(new PriorityScoreBatch(PriorityScoreBatch.Target.ACCOUNT), 200);
        Test.stopTest();

        Account result = [SELECT Priority_Score__c FROM Account WHERE Id = :account.Id];
        Assert.areEqual(69.9, result.Priority_Score__c, '열린 Opportunity 가 있어도 제외하지 않고 정상 채점(69.9)되어야 한다');
    }

    @isTest
    static void shouldScoreAccount_WhenNoOpenOpportunity() {
        // Given: 열린 딜 없음, RP 300억 경로 → 69.9
        Account account = TestDataFactory.createAccount('90000002', true);
        insertStatement(null, account.Id, 2023, ASSETS, ASSETS, RP_FUND_FULL, 0);

        Test.startTest();
        Database.executeBatch(new PriorityScoreBatch(PriorityScoreBatch.Target.ACCOUNT), 200);
        Test.stopTest();

        Account result = [SELECT Priority_Score__c FROM Account WHERE Id = :account.Id];
        Assert.areEqual(69.9, result.Priority_Score__c, 'Account 정상 채점 시 69.9 이어야 한다');
    }

    @isTest
    static void shouldSkipLockedLead_WhenScoreLocked() {
        // Given: 원래라면 69.9 가 나올 재무. 그러나 점수를 95.4 로 수기 고정하고 잠금.
        Lead lead = createLead('Locked Lead');
        insertStatement(lead.Id, null, 2023, ASSETS, ASSETS, RP_FUND_FULL, 0);
        update new Lead(Id = lead.Id, Priority_Score__c = 95.4, Priority_Score_Locked__c = true);

        // When: 배치 재계산
        Test.startTest();
        Database.executeBatch(new PriorityScoreBatch(PriorityScoreBatch.Target.LEAD), 200);
        Test.stopTest();

        // Then: 잠긴 리드는 스코프에서 빠져 고정값 95.4 가 그대로 유지되어야 한다.
        Lead result = [SELECT Priority_Score__c FROM Lead WHERE Id = :lead.Id];
        Assert.areEqual(95.4, result.Priority_Score__c, '잠긴 리드는 배치가 재계산하지 않고 고정값(95.4)을 유지해야 한다');
    }

    @isTest
    static void shouldThrow_WhenConstructedWithNullTarget() {
        try {
            new PriorityScoreBatch(null);
            Assert.fail('target 이 null 이면 예외가 발생해야 한다');
        } catch (IllegalArgumentException e) {
            Assert.isTrue(e.getMessage().contains('필수'), '필수 파라미터 오류여야 한다');
        }
    }

    @isTest
    static void shouldRunViaScheduler_WhenExecuteCalled() {
        // Given
        Lead lead = createLead('Scheduled Lead');
        insertStatement(lead.Id, null, 2023, ASSETS, ASSETS, RP_FUND_FULL, 0);

        // When: 스케줄러 execute → runAll → Lead/Account 배치 기동
        Test.startTest();
        new PriorityScoreBatch(PriorityScoreBatch.Target.LEAD).execute((SchedulableContext) null);
        Test.stopTest();

        Lead result = [SELECT Priority_Score__c FROM Lead WHERE Id = :lead.Id];
        Assert.areEqual(69.9, result.Priority_Score__c, '스케줄러가 배치를 기동해 Lead 점수를 산정해야 한다');
    }

    @isTest
    static void shouldScoreLead_WhenStatusNotNew() {
        // 비신규 상태(영업 진행 중) 리드도 제외하지 않고 채점한다 — 신규 케이스와 동일한 69.9.
        List<LeadStatus> working = [
            SELECT MasterLabel
            FROM LeadStatus
            WHERE IsConverted = false AND MasterLabel != '신규'
            ORDER BY SortOrder ASC NULLS LAST
            LIMIT 1
        ];
        if (working.isEmpty()) {
            return; // org 에 비신규·미전환 상태가 없으면 검증 불가 → 건너뜀
        }
        Lead lead = new Lead(
            LastName = 'Tester',
            Company = 'Working Lead',
            Status = working[0].MasterLabel,
            IsConverted = false,
            name_new__c = 'Tester',
            Email = 'working@example.com'
        );
        insert lead;
        insertStatement(lead.Id, null, 2023, ASSETS, ASSETS, RP_FUND_FULL, 0);

        Test.startTest();
        Database.executeBatch(new PriorityScoreBatch(PriorityScoreBatch.Target.LEAD), 200);
        Test.stopTest();

        Lead result = [SELECT Priority_Score__c FROM Lead WHERE Id = :lead.Id];
        Assert.areEqual(69.9, result.Priority_Score__c, '비신규 상태 리드도 제외하지 않고 정상 채점(69.9)되어야 한다');
    }

    // ─── 테스트 데이터 헬퍼 (TestDataFactory 동결로 이 클래스에 둔다) ──────────

    private static Lead createLead(String company) {
        Lead lead = new Lead(
            LastName = 'Tester',
            Company = company,
            Status = '신규',
            IsConverted = false,
            name_new__c = 'Tester',
            Email = 'tester@example.com'
        );
        insert lead;
        return lead;
    }

    /**
     * 연간 재무제표 1건 생성(기본 보고서=사업보고서 11011). RP 자금은 현금및현금성자산에,
     * 회사채 자금은 사채에 넣어 상품별 합산 산식을 단순 검증한다(현금비율/차입금비율 = fund / assets).
     */
    private static void insertStatement(
        Id leadId, Id accountId, Integer fiscalYear,
        Decimal totalAssets, Decimal totalEquity, Decimal rpFund, Decimal bondFund
    ) {
        insertStatement(leadId, accountId, fiscalYear, '11011', totalAssets, totalEquity, rpFund, bondFund);
    }

    /**
     * 재무제표 1건 생성. reportCode 로 보고서를 지정한다(11011 연간/11012 반기/11013 1분기/11014 3분기).
     * External_Key 는 실제 형식(마지막 세그먼트가 보고서 코드)을 따라, PriorityScoreBatch 의
     * 보고서 코드 파싱·최신 공시 선택·전년 동기 매칭을 검증할 수 있게 한다.
     */
    private static void insertStatement(
        Id leadId, Id accountId, Integer fiscalYear, String reportCode,
        Decimal totalAssets, Decimal totalEquity, Decimal rpFund, Decimal bondFund
    ) {
        insert new CorporateFinancialStatement__c(
            Lead__c = leadId,
            Account__c = accountId,
            Fiscal_Year__c = fiscalYear,
            Period_Type__c = periodTypeOf(reportCode),
            Total_Assets__c = totalAssets,
            Total_Equity__c = totalEquity,
            Cash_And_Equivalents__c = rpFund,
            Short_Term_Financial_Instruments__c = 0,
            Bonds_Payable__c = bondFund,
            Short_Term_Borrowings__c = 0,
            Long_Term_Borrowings__c = 0,
            External_Key__c = 'K_' + leadId + '_' + accountId + '_' + fiscalYear + '_' + reportCode
        );
    }

    private static String periodTypeOf(String reportCode) {
        if (reportCode == '11011') { return '4분기'; }
        if (reportCode == '11012') { return '2분기'; }
        if (reportCode == '11014') { return '3분기'; }
        return '1분기';
    }

    private static void insertDisclosureSignal(Id leadId, Id accountId, Date signalDate) {
        insert new ExternalSignal__c(
            Lead__c = leadId,
            Account__c = accountId,
            Signal_Type__c = '공시',
            Signal_Date__c = signalDate,
            External_Key__c = 'SIG_' + leadId + '_' + accountId + '_' + signalDate.year()
        );
    }
}