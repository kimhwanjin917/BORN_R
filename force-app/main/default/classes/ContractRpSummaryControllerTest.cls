/**
 * Tests for ContractRpSummaryController — Contract RP 확정조건 요약 조회.
 *
 * 두 층위를 검증한다:
 *   1) 계산 wrapper(RpTermConfirmController.calculateRpTerms) 재사용이 기존 산식과 정확히 일치하는가.
 *   2) getSummary 가 FLS 없는 신규 커스텀 필드를 SELECT 에서 제외해도 요약 화면 전체가 조회되는가
 *      (특히 민감정보 Settlement_Account__c 는 접근 불가 시 미노출).
 *
 * 실행 사용자는 신규 커스텀 필드에 FLS 가 아직 없다(팀이 org UI 에서 부여). 그래서 USER_MODE 로는
 * 커스텀 필드가 조회되지 않고, snapshot 자체의 정확성은 SYSTEM_MODE 로 검증한다 — 기존
 * RpContractCreationServiceTest 와 같은 방식.
 *
 * TestDataFactory 는 팀 공용 동결 파일이라 쓰지 않고 여기서 @TestSetup 으로 만든다.
 */
@isTest
private class ContractRpSummaryControllerTest {

    @TestSetup
    static void makeData() {
        Account acct = new Account(
            Name = 'RP 요약 테스트 고객사',
            Industry = 'Banking',
            Business_Registration_Number__c = '3000000999'
        );
        insert acct;

        Contact con = new Contact(
            LastName = '요약담당', AccountId = acct.Id,
            Email = 'rp.summary.test@example.com', name_new__c = '요약'
        );
        insert con;

        Product2 prod = new Product2(Name = 'RP 요약 테스트 상품', Family = 'RP', IsActive = true, Default_Fee_Rate__c = 0.05);
        insert prod;

        // E2E 확정조건: RP 매수 / 세후 / 1억 / 3.25% / 고정 / 정률 0.05% / 2026-09-01 ~ 2026-10-01
        insert new Opportunity(
            Name = 'RP 요약 테스트 기회',
            AccountId = acct.Id,
            ContactId = con.Id,
            StageName = 'Prospecting',
            CloseDate = Date.newInstance(2026, 12, 31),
            Primary_Product__c = prod.Id,
            Amount = 100000000,
            RP_Yield__c = 3.25,
            Fee_Rate__c = 0.05,
            Contract_Start_Date__c = Date.newInstance(2026, 9, 1),
            RP_Maturity_Date__c = Date.newInstance(2026, 10, 1),
            Yield_Structure__c = '고정금리',
            Deal_Direction__c = 'RP 매수',
            Yield_Basis__c = '세후'
        );
    }

    private static Opportunity theOpp() {
        return [SELECT Id, ContactId FROM Opportunity WHERE Name = 'RP 요약 테스트 기회' LIMIT 1];
    }

    // ─── 계산 wrapper: 기존 산식과 정확히 일치 ─────────────────────────
    @isTest
    static void calculateRpTerms_matchesLegacyFormula_postTax() {
        Date startOn = Date.newInstance(2026, 9, 1);
        Date endOn = Date.newInstance(2026, 10, 1); // 30일

        Test.startTest();
        RpTermConfirmController.RpCalculationResult r =
            RpTermConfirmController.calculateRpTerms(100000000, 3.25, startOn, endOn, '세후');
        Test.stopTest();

        // 총이자 = 1억 × 3.25% × 30 / 365 = 267,123 (HALF_UP)
        Assert.areEqual(30, r.days, '기간(일)');
        Assert.areEqual(267123, r.grossInterest, '세전 총이자');
        // 세후: 267,123 × 0.14 = 37,397 (HALF_UP)
        Assert.areEqual(37397, r.withholdingTax, '원천징수세');
        Assert.areEqual(229726, r.netInterest, '수익금 = 총이자 − 세금');
        // 환매예정금액은 기존 computeRedemptionAmount 그대로 = 100,229,726
        Assert.areEqual(100229726, r.redemptionAmount, '환매예정금액 = 원금 + 순이자');
        // wrapper 의 환매예정금액이 기존 helper 와 동일해야 한다(단일 계산 source).
        Assert.areEqual(
            RpTermConfirmController.computeRedemptionAmount(100000000, 3.25, startOn, endOn, '세후'),
            r.redemptionAmount, 'wrapper 환매예정금액 = 기존 helper 결과');
    }

    @isTest
    static void calculateRpTerms_preTax_hasNoWithholding() {
        Date startOn = Date.newInstance(2026, 9, 1);
        Date endOn = Date.newInstance(2026, 10, 1);

        RpTermConfirmController.RpCalculationResult r =
            RpTermConfirmController.calculateRpTerms(100000000, 3.25, startOn, endOn, '세전');

        Assert.areEqual(0, r.withholdingTax, '세전은 원천징수 0');
        Assert.areEqual(r.grossInterest, r.netInterest, '세전은 수익금 = 총이자');
        Assert.areEqual(100267123, r.redemptionAmount, '세전 환매예정금액 = 원금 + 총이자');
    }

    @isTest
    static void calculateRpTerms_returnsNull_whenInputMissing() {
        Assert.isNull(
            RpTermConfirmController.calculateRpTerms(null, 3.25, Date.today(), Date.today().addDays(30), '세전'),
            '입력이 부족하면 null');
    }

    // ─── getSummary: 표준 필드는 항상, 민감정보 Settlement_Account 는 FLS 정책대로 ──
    // 실행 사용자(권한셋 RM_Assistant_Access)에게는 Settlement_Account__c 읽기 FLS 가 부여돼 있으므로
    // 접근 가능해야 하고, 스냅샷된 값이 그대로 노출돼야 한다(정책상 RM 은 결제계좌를 본다).
    @isTest
    static void getSummary_returnsStandardFields_andSettlementPerFls() {
        Opportunity opp = theOpp();
        RpContractCreationService.Result created =
            RpContractCreationService.createContract(opp.Id, opp.ContactId);
        Assert.isTrue(created.created, 'Contract 가 생성된다');

        // 결제계좌는 Contract 단계 직접 입력값 — 검증을 위해 스냅샷 이후 값을 채운다.
        Database.update(new Contract(Id = created.contractId, Settlement_Account__c = '123-456-7890'),
            true, AccessLevel.SYSTEM_MODE);

        Test.startTest();
        ContractRpSummaryController.Summary s =
            ContractRpSummaryController.getSummary(created.contractId);
        Test.stopTest();

        // 표준 필드는 FLS 와 무관하게 조회된다.
        Assert.areEqual('RP 요약 테스트 기회', s.dealId, '거래 ID = SourceOpportunity.Name');
        Assert.areEqual('RP 요약 테스트 고객사', s.accountName, '고객사');
        Assert.areEqual('Draft', s.status, '계약 상태');
        Assert.areEqual(Date.newInstance(2026, 9, 1), s.startDate, '최초 매매일(StartDate)');

        // 실행 사용자는 RM_Assistant_Access 로 Settlement_Account__c FLS 를 가지므로 노출된다.
        Assert.isTrue(s.settlementAccountAccessible, '결제계좌 FLS 있음(RM_Assistant_Access)');
        Assert.areEqual('123-456-7890', s.settlementAccount, '접근 가능 시 결제계좌 값을 노출한다');
    }

    @isTest
    static void getSummary_throws_whenContractIdNull() {
        Test.startTest();
        Boolean threw = false;
        try {
            ContractRpSummaryController.getSummary(null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();
        Assert.isTrue(threw, 'contractId 가 없으면 거절한다');
    }

    // ─── snapshot 독립성: Opportunity 변경이 Contract 계산을 바꾸지 않는다 ──
    @isTest
    static void contractSnapshot_isIndependentOfLaterOpportunityChange() {
        Opportunity opp = theOpp();
        RpContractCreationService.Result created =
            RpContractCreationService.createContract(opp.Id, opp.ContactId);
        Id contractId = created.contractId;

        // 생성 직후 Contract 스냅샷(SYSTEM_MODE — 실행 사용자는 신규 필드 FLS 없음)
        Contract before = readContract(contractId);
        Assert.areEqual('RP 매수', before.Deal_Direction__c, '거래방향 스냅샷');
        Assert.areEqual('세후', before.Yield_Basis__c, '수익률 기준 스냅샷');
        Assert.areEqual(opp.ContactId, before.Contact__c, '담당 Contact = Opportunity.ContactId (fallback)');

        // 계약 후 Opportunity 의 수익률 기준을 세전으로 변경
        Test.startTest();
        update new Opportunity(Id = opp.Id, Yield_Basis__c = '세전');
        Test.stopTest();

        // Contract 스냅샷은 그대로 세후 — Opportunity 변경에 영향받지 않는다.
        Contract after = readContract(contractId);
        Assert.areEqual('세후', after.Yield_Basis__c, 'Opportunity 변경 후에도 Contract 는 세후 유지');

        // Contract 스냅샷 기준 계산이 세후로 유지되는지 확인.
        RpTermConfirmController.RpCalculationResult calc = RpTermConfirmController.calculateRpTerms(
            after.Contract_Amount__c, after.RP_Yield__c, after.StartDate, after.Maturity_Date__c, after.Yield_Basis__c);
        Assert.areEqual(37397, calc.withholdingTax, 'Contract 세후 기준 세금 유지');
        Assert.areEqual(100229726, calc.redemptionAmount, 'Contract 세후 기준 환매예정금액 유지');
    }

    private static Contract readContract(Id contractId) {
        List<Contract> rows = Database.queryWithBinds(
            'SELECT Id, Status, StartDate, Deal_Direction__c, Yield_Basis__c, Contact__c, '
            + 'Contract_Amount__c, RP_Yield__c, Maturity_Date__c, Yield_Structure__c, Fee_Amount__c '
            + 'FROM Contract WHERE Id = :cid LIMIT 1',
            new Map<String, Object>{ 'cid' => contractId },
            AccessLevel.SYSTEM_MODE
        );
        return rows[0];
    }
}