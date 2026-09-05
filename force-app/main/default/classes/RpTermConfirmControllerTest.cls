/**
 * Tests for RpTermConfirmController — 조건 확정 모달의 조회·검증·저장·PDF 연결.
 *
 * PDF 렌더링은 ContractDocumentService 와 같은 방식으로 Test.isRunningTest() 분기에서
 * 더미 Blob 을 돌려주므로(getContentAsPDF 는 테스트에서 호출할 수 없다) 여기서는
 * "파일이 Opportunity 에 연결되었는가 / 재확정 시 새 버전이 쌓이는가" 만 검증한다.
 *
 * TestDataFactory 는 팀 공용 동결 파일이라 쓰지 않고 이 클래스 안에서 @TestSetup 으로 만든다.
 * Account 필수값(Industry, Business_Registration_Number__c)은 이 org 의 검증 규칙 때문에 반드시 채운다.
 */
@isTest
private class RpTermConfirmControllerTest {

    @TestSetup
    static void makeData() {
        Account acct = new Account(
            Name = 'RP 조건확정 테스트 고객사',
            Industry = 'Banking',
            Business_Registration_Number__c = '3000000777'
        );
        insert acct;

        insert new Opportunity(
            Name = 'RP 조건확정 테스트 기회',
            AccountId = acct.Id,
            StageName = 'Prospecting',
            CloseDate = Date.newInstance(2026, 12, 31)
        );

        // 모달의 상품 목록은 활성 상품 전체다 — 상품군은 가리지 않고, 비활성만 제외한다.
        insert new List<Product2>{
            new Product2(Name = 'RP 테스트 상품', Family = 'RP', IsActive = true, Default_Fee_Rate__c = 0.15),
            new Product2(Name = '회사채 테스트 상품', Family = '채권', IsActive = true),
            new Product2(Name = '단종 테스트 상품', Family = '채권', IsActive = false)
        };
    }

    private static Opportunity theOpp() {
        return [SELECT Id, Name FROM Opportunity WHERE Name = 'RP 조건확정 테스트 기회' LIMIT 1];
    }

    private static Product2 rpProduct() {
        return [SELECT Id FROM Product2 WHERE Name = 'RP 테스트 상품' LIMIT 1];
    }

    /** 유효한 확정 입력값 한 벌. 개별 테스트가 필요한 필드만 바꿔 쓴다. */
    private static RpTermConfirmController.TermInput validInput(Id productId) {
        RpTermConfirmController.TermInput i = new RpTermConfirmController.TermInput();
        i.productId = productId;
        i.dealDirection = 'RP 매수';
        i.startDate = Date.newInstance(2026, 9, 1);
        i.endDate = Date.newInstance(2026, 12, 1);
        i.amount = 100000000;
        i.rpYield = 3.25;
        i.yieldStructure = '고정금리';
        i.yieldBasis = '세전';
        i.feeMethod = '정률';
        i.feeRate = 0.05;
        i.feeAmount = null;
        i.feeBearer = '고객';
        i.earlyRedemption = '불가';
        i.specialTerms = '없음';
        i.customerFinalAgreement = '완료';
        i.couponRate = 2.50;
        i.collateralRatio = 130.00;
        return i;
    }

    @isTest
    static void shouldListEveryActiveProductAndAllPicklists_WhenInitialising() {
        Opportunity opp = theOpp();

        Test.startTest();
        RpTermConfirmController.InitState s = RpTermConfirmController.getInit(opp.Id);
        Test.stopTest();

        Assert.areEqual('RP 조건확정 테스트 기회', s.opportunityName, '거래ID = Opportunity.Name');
        Assert.areEqual('RP 조건확정 테스트 고객사', s.accountName, 'Account name is returned');

        Map<String, String> familyByName = new Map<String, String>();
        for (RpTermConfirmController.ProductOption o : s.products) {
            familyByName.put(o.name, o.family);
        }
        Assert.isTrue(familyByName.containsKey('RP 테스트 상품'), 'RP 상품은 계속 보인다');
        Assert.isTrue(familyByName.containsKey('회사채 테스트 상품'), 'RP 가 아닌 활성 상품도 함께 보인다');
        Assert.isFalse(familyByName.containsKey('단종 테스트 상품'), '비활성 상품은 제외된다');

        // 신규 picklist 선택지가 모두 내려온다.
        Assert.isTrue(s.dealDirections.contains('RP 매수') && s.dealDirections.contains('RP 매도'), '거래방향 선택지');
        Assert.isTrue(s.yieldBases.contains('세전') && s.yieldBases.contains('세후'), '수익률 기준 선택지');
        Assert.isTrue(s.feeMethods.contains('정률') && s.feeMethods.contains('정액'), '수수료 방식 선택지');
        Assert.isTrue(s.feeBearers.contains('고객') && s.feeBearers.contains('증권사'), '수수료 부담 주체 선택지');
        Assert.isTrue(s.earlyRedemptions.contains('가능') && s.earlyRedemptions.contains('불가'), '중도환매 선택지');
        Assert.isTrue(s.customerFinalAgreements.contains('완료') && s.customerFinalAgreements.contains('미완료'), '고객 최종합의 선택지');
        Assert.isFalse(s.yieldStructures.isEmpty(), '수익률 구조 선택지');
        Assert.isFalse(s.hasConfirmedPdf, 'A fresh Opportunity has no confirmed terms PDF yet');
    }

    @isTest
    static void shouldDefaultStartDateToToday_WhenContractStartIsBlank() {
        // 미팅 저장은 종료일(RP_Maturity_Date__c)만 채우고 시작일은 남긴다. 모달은 시작일 초기값으로 오늘을 보여준다.
        Opportunity opp = theOpp();
        opp.Amount = 1200000000;
        opp.RP_Yield__c = 3.5;
        opp.Fee_Rate__c = 0.30;
        opp.RP_Maturity_Date__c = Date.today().addDays(90);
        opp.Contract_Start_Date__c = null;
        update opp;

        Test.startTest();
        RpTermConfirmController.InitState s = RpTermConfirmController.getInit(opp.Id);
        Test.stopTest();

        Assert.areEqual(Date.today(), s.startDate, '시작일이 비어 있으면 오늘을 초기값으로 내려준다');
        Assert.areEqual(1200000000, s.amount, '계약금액 prefill 유지');
        Assert.areEqual(3.5, s.rpYield, '약정수익률 prefill 유지');
        Assert.areEqual(0.30, s.feeRate, '확정 수수료율 prefill 유지');
        Assert.areEqual(Date.today().addDays(90), s.endDate, '환매일(RP_Maturity_Date__c) prefill 유지');

        Opportunity afterOpp = [SELECT Contract_Start_Date__c FROM Opportunity WHERE Id = :opp.Id];
        Assert.isNull(afterOpp.Contract_Start_Date__c, '모달을 여는 것만으로 Contract_Start_Date__c 를 저장하지 않는다');
    }

    @isTest
    static void shouldDefaultNewPicklists_WhenNeverFilled() {
        // 신규 조건 필드가 아직 아무도 채운 적 없을 때(전부 null) 모달이 합리적 기본값으로 열려야 한다.
        Opportunity opp = theOpp(); // 신규 필드 전부 null 상태

        Test.startTest();
        RpTermConfirmController.InitState s = RpTermConfirmController.getInit(opp.Id);
        Test.stopTest();

        Assert.areEqual('RP 매수', s.dealDirection, '거래방향 기본값');
        Assert.areEqual('세전', s.yieldBasis, '수익률 기준 기본값');
        Assert.areEqual('정률', s.feeMethod, '수수료 방식 기본값');
        Assert.areEqual('고객', s.feeBearer, '수수료 부담 주체 기본값');
        Assert.areEqual('불가', s.earlyRedemption, '중도환매 기본값');
        Assert.areEqual('미완료', s.customerFinalAgreement, '고객 최종합의 기본값');
        Assert.areEqual('고정금리', s.yieldStructure, '수익률 구조 기본값');

        // 기본값은 조회 응답에만 존재 — Opportunity 에는 저장되지 않는다.
        Opportunity afterOpp = [SELECT Deal_Direction__c, Fee_Method__c FROM Opportunity WHERE Id = :opp.Id];
        Assert.isNull(afterOpp.Deal_Direction__c, '모달을 여는 것만으로 저장하지 않는다');
        Assert.isNull(afterOpp.Fee_Method__c, '모달을 여는 것만으로 저장하지 않는다');
    }

    @isTest
    static void shouldKeepExistingStartDate_WhenContractStartIsSet() {
        Opportunity opp = theOpp();
        Date existing = Date.newInstance(2026, 9, 1);
        opp.Contract_Start_Date__c = existing;
        update opp;

        Test.startTest();
        RpTermConfirmController.InitState s = RpTermConfirmController.getInit(opp.Id);
        Test.stopTest();

        Assert.areEqual(existing, s.startDate, '이미 확정된 시작일은 오늘로 덮어쓰지 않는다');
    }

    @isTest
    static void shouldPrefillNewFields_WhenAlreadyStored() {
        Opportunity opp = theOpp();
        opp.Deal_Direction__c = 'RP 매수';
        opp.Yield_Basis__c = '세후';
        opp.Fee_Method__c = '정액';
        opp.Fee_Amount__c = 250000;
        opp.Fee_Bearer__c = '증권사';
        opp.Early_Redemption__c = '가능';
        opp.Special_Terms__c = '조기상환 협의';
        opp.Customer_Final_Agreement__c = '완료';
        update opp;

        Test.startTest();
        RpTermConfirmController.InitState s = RpTermConfirmController.getInit(opp.Id);
        Test.stopTest();

        Assert.areEqual('RP 매수', s.dealDirection, '거래방향 prefill');
        Assert.areEqual('세후', s.yieldBasis, '수익률 기준 prefill');
        Assert.areEqual('정액', s.feeMethod, '수수료 방식 prefill');
        Assert.areEqual(250000, s.feeAmount, '수수료 금액 prefill');
        Assert.areEqual('증권사', s.feeBearer, '수수료 부담 주체 prefill');
        Assert.areEqual('가능', s.earlyRedemption, '중도환매 prefill');
        Assert.areEqual('조기상환 협의', s.specialTerms, '특약 prefill');
        Assert.areEqual('완료', s.customerFinalAgreement, '고객 최종합의 prefill');
    }

    @isTest
    static void shouldSaveRateFeeAndClearAmount_WhenMethodIsRate() {
        Opportunity opp = theOpp();
        RpTermConfirmController.TermInput i = validInput(rpProduct().Id);
        i.feeMethod = '정률';
        i.feeRate = 0.05;
        i.feeAmount = 999999; // 정률이므로 저장되면 안 된다

        Test.startTest();
        RpTermConfirmController.ConfirmResult r = RpTermConfirmController.confirmTerms(opp.Id, JSON.serialize(i));
        Test.stopTest();

        Assert.isNotNull(r.contentDocumentId, '조건서 PDF 가 생성된다');
        Opportunity saved = [
            SELECT Deal_Direction__c, Yield_Basis__c, Fee_Method__c, Fee_Rate__c, Fee_Amount__c,
                   Fee_Bearer__c, Early_Redemption__c, Special_Terms__c, Customer_Final_Agreement__c,
                   Amount, RP_Yield__c, Contract_Start_Date__c, RP_Maturity_Date__c,
                   Coupon_Rate__c, Collateral_Ratio__c
            FROM Opportunity WHERE Id = :opp.Id
        ];
        Assert.areEqual('RP 매수', saved.Deal_Direction__c, '거래방향 저장');
        Assert.areEqual('세전', saved.Yield_Basis__c, '수익률 기준 저장');
        Assert.areEqual('정률', saved.Fee_Method__c, '수수료 방식 저장');
        Assert.areEqual(0.05, saved.Fee_Rate__c, '정률이면 수수료율 저장');
        Assert.isNull(saved.Fee_Amount__c, '정률이면 수수료 금액은 비운다');
        Assert.areEqual('고객', saved.Fee_Bearer__c, '수수료 부담 주체 저장');
        Assert.areEqual('불가', saved.Early_Redemption__c, '중도환매 저장');
        Assert.areEqual('완료', saved.Customer_Final_Agreement__c, '고객 최종합의 저장');
        Assert.areEqual(2.50, saved.Coupon_Rate__c, '표면금리 저장');
        Assert.areEqual(130.00, saved.Collateral_Ratio__c, '담보비율 저장');
    }

    @isTest
    static void shouldSaveAmountFeeAndClearRate_WhenMethodIsAmount() {
        Opportunity opp = theOpp();
        RpTermConfirmController.TermInput i = validInput(rpProduct().Id);
        i.feeMethod = '정액';
        i.feeAmount = 300000;
        i.feeRate = 0.07; // 정액이므로 저장되면 안 된다

        Test.startTest();
        RpTermConfirmController.confirmTerms(opp.Id, JSON.serialize(i));
        Test.stopTest();

        Opportunity saved = [SELECT Fee_Method__c, Fee_Rate__c, Fee_Amount__c FROM Opportunity WHERE Id = :opp.Id];
        Assert.areEqual('정액', saved.Fee_Method__c, '수수료 방식 저장');
        Assert.areEqual(300000, saved.Fee_Amount__c, '정액이면 수수료 금액 저장');
        Assert.isNull(saved.Fee_Rate__c, '정액이면 수수료율은 비운다');
    }

    @isTest
    static void shouldAttachPdf_WhenConfirmed() {
        Opportunity opp = theOpp();

        Test.startTest();
        RpTermConfirmController.ConfirmResult r =
            RpTermConfirmController.confirmTerms(opp.Id, JSON.serialize(validInput(rpProduct().Id)));
        Test.stopTest();

        Assert.isNotNull(r.contentDocumentId, 'A ContentDocument must be created');
        Assert.isFalse(r.newVersion, 'The first confirmation creates a document, not a new version');
        Assert.isTrue(r.fileName.contains('_RP_확정조건_'), 'File name follows the naming rule');

        List<ContentDocumentLink> links = [
            SELECT ContentDocumentId FROM ContentDocumentLink
            WHERE LinkedEntityId = :opp.Id AND ContentDocumentId = :r.contentDocumentId
        ];
        Assert.areEqual(1, links.size(), 'The PDF is linked to the Opportunity');
    }

    @isTest
    static void shouldAddNewVersion_WhenTermsAreConfirmedAgain() {
        Opportunity opp = theOpp();
        Id productId = rpProduct().Id;

        RpTermConfirmController.ConfirmResult first =
            RpTermConfirmController.confirmTerms(opp.Id, JSON.serialize(validInput(productId)));

        Test.startTest();
        RpTermConfirmController.TermInput second = validInput(productId);
        second.amount = 200000000;
        second.yieldStructure = '변동금리';
        RpTermConfirmController.ConfirmResult r2 = RpTermConfirmController.confirmTerms(opp.Id, JSON.serialize(second));
        Test.stopTest();

        Assert.isTrue(r2.newVersion, 'Re-confirming stacks a new version instead of a second document');
        Assert.areEqual(first.contentDocumentId, r2.contentDocumentId, 'The same ContentDocument keeps the history');

        Integer versions = [SELECT COUNT() FROM ContentVersion WHERE ContentDocumentId = :first.contentDocumentId];
        Assert.areEqual(2, versions, 'Both versions are retained');

        Opportunity saved = [SELECT Yield_Structure__c, Amount FROM Opportunity WHERE Id = :opp.Id];
        Assert.areEqual('변동금리', saved.Yield_Structure__c, 'The latest confirmation wins');
        Assert.areEqual(200000000, saved.Amount, 'The latest amount wins');
    }

    @isTest
    static void shouldRejectAndSaveNothing_WhenRequiredValuesAreMissing() {
        Opportunity opp = theOpp();

        Test.startTest();
        Boolean threw = false;
        try {
            RpTermConfirmController.confirmTerms(opp.Id, JSON.serialize(new RpTermConfirmController.TermInput()));
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Missing required values must be rejected');
        Assert.areEqual(0, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :opp.Id],
            'No PDF is produced when validation fails');
    }

    @isTest
    static void shouldReject_WhenRateMethodMissesRate() {
        RpTermConfirmController.TermInput i = validInput(rpProduct().Id);
        i.feeMethod = '정률';
        i.feeRate = null;
        List<String> errors = RpTermConfirmController.validate(i);
        Assert.isTrue(hasError(errors, '수수료율'), '정률인데 수수료율이 없으면 거절');
    }

    @isTest
    static void shouldReject_WhenAmountMethodMissesAmount() {
        RpTermConfirmController.TermInput i = validInput(rpProduct().Id);
        i.feeMethod = '정액';
        i.feeRate = null;
        i.feeAmount = null;
        List<String> errors = RpTermConfirmController.validate(i);
        Assert.isTrue(hasError(errors, '수수료 금액'), '정액인데 수수료 금액이 없으면 거절');
    }

    @isTest
    static void shouldReject_WhenEndDateIsBeforeStartDate() {
        RpTermConfirmController.TermInput i = validInput(rpProduct().Id);
        i.startDate = Date.newInstance(2026, 12, 1);
        i.endDate = Date.newInstance(2026, 11, 30);
        List<String> errors = RpTermConfirmController.validate(i);
        Assert.isTrue(hasError(errors, '환매일'), '환매일이 매매일보다 빠르면 거절');
    }

    @isTest
    static void shouldComputeRedemption_PreTaxAndPostTax() {
        // 1억 × 3.65% × 100일 / 365 = 1,000,000 이자 (딱 떨어지게 100일 선택)
        Date startOn = Date.newInstance(2026, 9, 1);
        Date endOn = startOn.addDays(100);

        Decimal pre = RpTermConfirmController.computeRedemptionAmount(100000000, 3.65, startOn, endOn, '세전');
        Assert.areEqual(101000000, pre, '세전 환매예정금액 = 원금 + 총이자');

        Decimal post = RpTermConfirmController.computeRedemptionAmount(100000000, 3.65, startOn, endOn, '세후');
        // 이자 1,000,000 × (1 - 0.14) = 860,000 → 100,860,000
        Assert.areEqual(100860000, post, '세후는 이자에 원천징수(0.14)를 반영한다');

        Assert.isNull(
            RpTermConfirmController.computeRedemptionAmount(null, 3.65, startOn, endOn, '세전'),
            '입력이 부족하면 null 을 돌려준다'
        );
    }

    @isTest
    static void shouldBuildFileName_FromOpportunityNameAndDate() {
        String name = RpTermConfirmController.buildFileName('실리콘투 - RP', Date.newInstance(2026, 8, 30));
        Assert.areEqual('실리콘투 - RP_RP_확정조건_20260830.pdf', name, 'File name keeps Korean, spaces and hyphens');

        String sanitised = RpTermConfirmController.buildFileName('A/B:C*D', Date.newInstance(2026, 8, 30));
        Assert.isFalse(sanitised.contains('/'), 'Path separators are stripped from the file name');
    }

    @isTest
    static void shouldFindLatestPdf_ForProductTeamHandoff() {
        Opportunity opp = theOpp();
        Assert.isNull(RpTermConfirmController.findLatestTermPdfId(opp.Id),
            '확정 전에는 첨부할 조건서가 없다');

        RpTermConfirmController.ConfirmResult r =
            RpTermConfirmController.confirmTerms(opp.Id, JSON.serialize(validInput(rpProduct().Id)));

        Test.startTest();
        Id found = RpTermConfirmController.findLatestTermPdfId(opp.Id);
        Test.stopTest();

        Assert.areEqual(r.contentDocumentId, found, 'The confirmed terms PDF is the one handed to the product team');
    }

    @isTest
    static void shouldStageYieldToPending_WhenAboveCap() {
        // 상한(연 7%) 초과 확정 수익률은 승인 전까지 적용값(RP_Yield__c)이 아니라 대기 필드에만 저장한다.
        Opportunity opp = theOpp();
        RpTermConfirmController.TermInput i = validInput(rpProduct().Id);
        i.rpYield = 10;

        Test.startTest();
        RpTermConfirmController.confirmTerms(opp.Id, JSON.serialize(i));
        Test.stopTest();

        Opportunity saved = [SELECT RP_Yield__c, Pending_Yield__c FROM Opportunity WHERE Id = :opp.Id];
        Assert.isNull(saved.RP_Yield__c, '상한 초과분은 승인 전까지 적용값에 반영하지 않는다');
        Assert.areEqual(10, saved.Pending_Yield__c, '상한 초과분은 승인 대기 필드에 저장된다');

        RpTermConfirmController.InitState s = RpTermConfirmController.getInit(opp.Id);
        Assert.areEqual(10, s.rpYield, '재확정 모달엔 대기 중인 초과값을 되보여준다');
    }

    @isTest
    static void shouldApplyYieldAndClearPending_WhenAtOrBelowCap() {
        // 상한 이하이면 즉시 적용값에 반영하고, 이전에 대기 중이던 초과값이 있으면 비운다.
        Opportunity opp = theOpp();
        opp.Pending_Yield__c = 9;
        update opp;
        RpTermConfirmController.TermInput i = validInput(rpProduct().Id);
        i.rpYield = 5;

        Test.startTest();
        RpTermConfirmController.confirmTerms(opp.Id, JSON.serialize(i));
        Test.stopTest();

        Opportunity saved = [SELECT RP_Yield__c, Pending_Yield__c FROM Opportunity WHERE Id = :opp.Id];
        Assert.areEqual(5, saved.RP_Yield__c, '상한 이하이면 즉시 적용값에 반영');
        Assert.isNull(saved.Pending_Yield__c, '상한 이하이면 이전 대기값을 비운다');
    }

    private static Boolean hasError(List<String> errors, String needle) {
        for (String e : errors) {
            if (e.contains(needle)) return true;
        }
        return false;
    }
}