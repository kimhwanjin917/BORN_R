/**
 * PriorityScoreExplainer 테스트.
 *
 * 핵심 보증: 분해 합계(Explainer.total)가 PriorityScoreBatch 가 실제로 저장한 Priority_Score__c 와
 * 정확히 일치한다 — 두 클래스의 채점 규칙이 벌어지면(드리프트) 이 테스트가 실패한다.
 *
 * 테스트 데이터는 동결 파일 TestDataFactory 를 건드리지 않기 위해 이 클래스 헬퍼로 생성한다
 * (PriorityScoreBatchTest 와 동일한 시드 방식).
 */
@isTest
private class PriorityScoreExplainerTest {

    private static final Decimal ASSETS = 100000000000L;         // 자산총계 1000억
    private static final Decimal RP_FUND_FULL = 30000000000L;    // RP 300억 (현금자산비율 30%)
    private static final Decimal BOND_FUND_FULL = 300000000000L; // 회사채 3,000억

    @isTest
    static void shouldMatchBatchScore_ForRpLead() {
        Lead lead = createLead('RP Explain');
        insertStatement(lead.Id, 2023, '11011', ASSETS, ASSETS, RP_FUND_FULL, 0);

        Test.startTest();
        Database.executeBatch(new PriorityScoreBatch(PriorityScoreBatch.Target.LEAD), 200);
        Test.stopTest();

        Decimal batchScore = [SELECT Priority_Score__c FROM Lead WHERE Id = :lead.Id].Priority_Score__c;
        PriorityScoreExplainer.Breakdown b = PriorityScoreExplainer.explainLead(lead.Id);

        Assert.isTrue(b.available, '재무가 있으면 분해가 가능해야 한다');
        Assert.isTrue(b.isRp, '현금자산비율이 높으면 RP 로 판정해야 한다');
        Assert.areEqual(batchScore, b.total, '분해 합계는 배치 산정 점수(69.9)와 일치해야 한다');
        Assert.areEqual(
            b.total,
            (b.fitScore + b.needScore + b.disclosureScore).setScale(1, System.RoundingMode.HALF_UP),
            '세 항목 합이 total 과 같아야 한다'
        );
        Assert.isNull(b.yoyGrowth, '직전 동기 공시가 없으면 YoY 는 null 이어야 한다');
    }

    @isTest
    static void shouldMatchBatchScore_ForBondLead() {
        Lead lead = createLead('Bond Explain');
        insertStatement(lead.Id, 2023, '11011', ASSETS, ASSETS, 6000000000L, BOND_FUND_FULL);

        Test.startTest();
        Database.executeBatch(new PriorityScoreBatch(PriorityScoreBatch.Target.LEAD), 200);
        Test.stopTest();

        Decimal batchScore = [SELECT Priority_Score__c FROM Lead WHERE Id = :lead.Id].Priority_Score__c;
        PriorityScoreExplainer.Breakdown b = PriorityScoreExplainer.explainLead(lead.Id);

        Assert.isFalse(b.isRp, '차입금의존도가 더 높으면 회사채로 판정해야 한다');
        Assert.areEqual(batchScore, b.total, '회사채 경로에서도 분해 합계가 배치 점수와 일치해야 한다');

        String text = PriorityScoreExplainer.buildGroundingText(lead.Id);
        Assert.isTrue(text.contains('회사채'), '회사채 경로는 근거 텍스트에 회사채가 나와야 한다');
    }

    @isTest
    static void shouldMatchBatchScore_WhenFundGrewYoY() {
        Lead lead = createLead('Growth Explain');
        insertStatement(lead.Id, 2022, '11011', ASSETS, ASSETS, 20000000000L, 0); // 직전 200억
        insertStatement(lead.Id, 2023, '11011', ASSETS, ASSETS, RP_FUND_FULL, 0); // 최신 300억 → +50%

        Test.startTest();
        Database.executeBatch(new PriorityScoreBatch(PriorityScoreBatch.Target.LEAD), 200);
        Test.stopTest();

        Decimal batchScore = [SELECT Priority_Score__c FROM Lead WHERE Id = :lead.Id].Priority_Score__c;
        PriorityScoreExplainer.Breakdown b = PriorityScoreExplainer.explainLead(lead.Id);

        Assert.areEqual(batchScore, b.total, 'YoY 성장 케이스도 배치 점수와 일치해야 한다');
        Assert.areEqual(0.50, b.yoyGrowth.setScale(2, System.RoundingMode.HALF_UP), '전년 동기比 +50% 여야 한다');

        String text = PriorityScoreExplainer.buildGroundingText(lead.Id);
        Assert.isTrue(text.contains('우선순위 점수'), '근거 텍스트에 우선순위 점수 헤더가 있어야 한다');
        Assert.isTrue(text.contains('전년 동기比'), 'YoY 가 있으면 전년 동기比 표기가 있어야 한다');
    }

    @isTest
    static void shouldReturnNull_WhenNoStatement() {
        Lead lead = createLead('Empty Explain');

        Test.startTest();
        PriorityScoreExplainer.Breakdown b = PriorityScoreExplainer.explainLead(lead.Id);
        String text = PriorityScoreExplainer.buildGroundingText(lead.Id);
        Test.stopTest();

        Assert.isFalse(b.available, '재무가 없으면 분해 불가여야 한다');
        Assert.isNull(text, '분해 불가면 근거 텍스트는 null 이어야 한다');
    }

    @isTest
    static void shouldReturnUnavailable_WhenCapitalImpaired() {
        Lead lead = createLead('Impaired Explain');
        insertStatement(lead.Id, 2023, '11011', ASSETS, -1, RP_FUND_FULL, 0);

        Test.startTest();
        PriorityScoreExplainer.Breakdown b = PriorityScoreExplainer.explainLead(lead.Id);
        Test.stopTest();

        Assert.isFalse(b.available, '자본잠식이면 분해 불가(available=false)여야 한다');
    }

    @isTest
    static void shouldReturnUnavailable_WhenNullId() {
        Test.startTest();
        PriorityScoreExplainer.Breakdown b = PriorityScoreExplainer.explainLead(null);
        String text = PriorityScoreExplainer.buildGroundingText(null);
        Test.stopTest();

        Assert.isFalse(b.available, 'leadId 가 null 이면 분해 불가여야 한다');
        Assert.isNull(text, 'null id 는 근거 텍스트 null 이어야 한다');
    }

    // ─── 헬퍼 (TestDataFactory 동결로 이 클래스에 둔다) ───

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

    private static void insertStatement(
        Id leadId, Integer fiscalYear, String reportCode,
        Decimal totalAssets, Decimal totalEquity, Decimal rpFund, Decimal bondFund
    ) {
        insert new CorporateFinancialStatement__c(
            Lead__c = leadId,
            Fiscal_Year__c = fiscalYear,
            Period_Type__c = periodTypeOf(reportCode),
            Total_Assets__c = totalAssets,
            Total_Equity__c = totalEquity,
            Cash_And_Equivalents__c = rpFund,
            Short_Term_Financial_Instruments__c = 0,
            Bonds_Payable__c = bondFund,
            Short_Term_Borrowings__c = 0,
            Long_Term_Borrowings__c = 0,
            External_Key__c = 'K_' + leadId + '_' + fiscalYear + '_' + reportCode
        );
    }

    private static String periodTypeOf(String reportCode) {
        if (reportCode == '11011') { return '4분기'; }
        if (reportCode == '11012') { return '2분기'; }
        if (reportCode == '11014') { return '3분기'; }
        return '1분기';
    }
}
