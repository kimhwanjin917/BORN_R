/**
 * Tests for RpContractCreationService — Form 최종 제출이 부르는 Contract 생성 진입점.
 *
 * 검증 시나리오는 "Opportunity 가 있으면 자동 생성" 이 아니라 Form submit 을 가정한 명시 호출이다:
 *   - 호출 직전 Contract 0 건
 *   - createContract 호출 후 Contract 1 건 + 관계/스냅샷/PDF
 *   - 같은 Opportunity 로 다시 호출하면 중복 생성 없이 기존 Contract 반환
 *
 * ContractDocumentService 는 Test.isRunningTest() 분기에서 더미 PDF Blob 을 돌려주므로
 * (getContentAsPDF 는 테스트에서 호출 불가) 파일 연결까지 그대로 검증된다.
 *
 * TestDataFactory 는 팀 공용 동결 파일이라 쓰지 않고 여기서 @TestSetup 으로 만든다.
 * Account 필수값(Industry, Business_Registration_Number__c)은 이 org 검증 규칙 때문에 채운다.
 * Meeting_Log__c 는 건드리지 않는다 — 건드리면 OpportunityReviewService 자동 심사가 걸려 계약이 자동 생성된다.
 */
@isTest
private class RpContractCreationServiceTest {

    @TestSetup
    static void makeData() {
        Account acct = new Account(
            Name = 'RP 계약생성 테스트 고객사',
            Industry = 'Banking',
            Business_Registration_Number__c = '3000000888'
        );
        insert acct;

        // 이 org 검증 규칙상 Contact 는 Email 과 커스텀 필수 필드 name_new__c(이름(new), Text(10)) 필수.
        Contact con = new Contact(
            LastName = '담당자', AccountId = acct.Id,
            Email = 'rp.contact.test@example.com', name_new__c = '담당'
        );
        insert con;

        Product2 prod = new Product2(Name = 'RP 계약 테스트 상품', Family = 'RP', IsActive = true, Default_Fee_Rate__c = 0.15);
        insert prod;

        // 확정 조건이 모두 채워진 "심사 완료 직전" 상태의 Opportunity.
        insert new Opportunity(
            Name = 'RP 계약생성 테스트 기회',
            AccountId = acct.Id,
            ContactId = con.Id,
            StageName = 'Prospecting',
            CloseDate = Date.newInstance(2026, 12, 31),
            Primary_Product__c = prod.Id,
            Amount = 500000000,
            RP_Yield__c = 3.25,
            Fee_Rate__c = 0.15,
            Fee_Amount__c = 1500000,
            Contract_Start_Date__c = Date.newInstance(2026, 9, 1),
            RP_Maturity_Date__c = Date.newInstance(2027, 2, 28),
            Yield_Structure__c = '고정금리',
            Deal_Direction__c = 'RP 매수',
            Yield_Basis__c = '세후'
        );
    }

    private static Opportunity theOpp() {
        return [SELECT Id, AccountId, ContactId, Primary_Product__c FROM Opportunity WHERE Name = 'RP 계약생성 테스트 기회' LIMIT 1];
    }

    private static Contact theContact() {
        return [
            SELECT Id FROM Contact
            WHERE AccountId IN (SELECT Id FROM Account WHERE Name = 'RP 계약생성 테스트 고객사')
            ORDER BY CreatedDate ASC LIMIT 1
        ];
    }

    @isTest
    static void shouldCreateContractWithRelationshipsAndSnapshot_OnFormSubmit() {
        Opportunity opp = theOpp();
        Contact con = theContact();
        // Form submit 직전: 이 Opportunity 에 Contract 가 하나도 없어야 한다.
        Assert.areEqual(0, [SELECT COUNT() FROM Contract WHERE SourceOpportunityId = :opp.Id],
            '호출 전 Contract 는 0 건');

        Test.startTest();
        RpContractCreationService.Result r = RpContractCreationService.createContract(opp.Id, con.Id);
        Test.stopTest();

        Assert.isTrue(r.created, '이번 호출로 새 Contract 를 만들었다');
        Assert.isFalse(r.reused, '재사용이 아니다');
        Assert.isNotNull(r.contractId, 'Contract Id 가 반환된다');
        Assert.isNotNull(r.contractNumber, 'Contract 번호가 반환된다');

        // 신규 필드(Contact__c/Fee_Amount__c/Yield_Structure__c)는 실행 사용자에게 FLS 가 아직 없어
        // USER_MODE SOQL 은 "No such column" 이 난다 — 검증은 SYSTEM_MODE 로 읽는다.
        Id oppId = opp.Id;
        List<Contract> cons = Database.queryWithBinds(
            'SELECT Id, AccountId, SourceOpportunityId, Contact__c, Product__c, Status, '
            + 'StartDate, Maturity_Date__c, Contract_Amount__c, RP_Yield__c, Fee_Rate__c, '
            + 'Fee_Amount__c, Yield_Structure__c, Deal_Direction__c, Yield_Basis__c '
            + 'FROM Contract WHERE SourceOpportunityId = :oppId',
            new Map<String, Object>{ 'oppId' => oppId },
            AccessLevel.SYSTEM_MODE
        );
        Assert.areEqual(1, cons.size(), 'Contract 가 정확히 1 건 생성된다');
        Contract c = cons[0];

        // 관계 연결
        Assert.areEqual(opp.AccountId, c.AccountId, 'Account 연결 = Opportunity.AccountId');
        Assert.areEqual(opp.Id, c.SourceOpportunityId, 'Opportunity 연결 = 원본 Opportunity');
        Assert.areEqual(con.Id, c.Contact__c, '담당 Contact 연결 = 전달된 contactId');
        Assert.areEqual(opp.Primary_Product__c, c.Product__c, 'Product 연결 = Opportunity.Primary_Product__c');

        // 확정 조건 스냅샷
        Assert.areEqual(Date.newInstance(2026, 9, 1), c.StartDate, 'StartDate = Opportunity.Contract_Start_Date__c');
        Assert.areEqual(Date.newInstance(2027, 2, 28), c.Maturity_Date__c, 'Maturity_Date__c(계약 종료일) = Opportunity.RP_Maturity_Date__c');
        Assert.areEqual(500000000, c.Contract_Amount__c, '계약금액 = Opportunity.Amount');
        Assert.areEqual(3.25, c.RP_Yield__c, 'RP 약정수익률 = Opportunity.RP_Yield__c');
        Assert.areEqual(0.15, c.Fee_Rate__c, '확정 수수료율 = Opportunity.Fee_Rate__c');
        Assert.areEqual(1500000, c.Fee_Amount__c, '수수료 = Opportunity.Fee_Amount__c');
        Assert.areEqual('고정금리', c.Yield_Structure__c, '수익률 구조 = Opportunity.Yield_Structure__c');
        Assert.areEqual('RP 매수', c.Deal_Direction__c, '거래방향 = Opportunity.Deal_Direction__c');
        Assert.areEqual('세후', c.Yield_Basis__c, '수익률 기준 = Opportunity.Yield_Basis__c');
        Assert.areEqual('Draft', c.Status, '신규 계약은 Draft 로 만든다');

        // PDF 가 Contract Files 에 연결됐는지 (ContractDocumentService 재사용 결과)
        Assert.isNotNull(r.contentDocumentId, 'PDF ContentDocument 가 반환된다');
        Assert.areEqual(1, [
            SELECT COUNT() FROM ContentDocumentLink
            WHERE LinkedEntityId = :c.Id AND ContentDocumentId = :r.contentDocumentId
        ], '계약서 PDF 가 Contract 에 연결된다');
    }

    @isTest
    static void shouldReuseExistingContract_WhenSubmittedAgain() {
        Opportunity opp = theOpp();
        Contact con = theContact();

        RpContractCreationService.Result first = RpContractCreationService.createContract(opp.Id, con.Id);
        Assert.isTrue(first.created, '첫 제출은 새로 만든다');

        Test.startTest();
        RpContractCreationService.Result second = RpContractCreationService.createContract(opp.Id, con.Id);
        Test.stopTest();

        Assert.isTrue(second.reused, '두 번째 제출은 기존 Contract 를 재사용한다');
        Assert.isFalse(second.created, '두 번째 제출은 새로 만들지 않는다');
        Assert.areEqual(first.contractId, second.contractId, '같은 Contract 를 돌려준다');
        Assert.areEqual(1, [SELECT COUNT() FROM Contract WHERE SourceOpportunityId = :opp.Id],
            '중복 호출에도 Contract 는 여전히 1 건');
    }

    @isTest
    static void shouldFallBackToOpportunityContact_WhenContactIdOmitted() {
        // contactId 를 넘기지 않아도 Opportunity.ContactId 로 담당 Contact 를 보완한다.
        Opportunity opp = theOpp();

        Test.startTest();
        RpContractCreationService.Result r = RpContractCreationService.createContract(opp.Id);
        Test.stopTest();

        Assert.isTrue(r.created, 'contactId 없이도 계약을 만든다');
        Id oppId = opp.Id;
        List<Contract> cons = Database.queryWithBinds(
            'SELECT Contact__c FROM Contract WHERE SourceOpportunityId = :oppId LIMIT 1',
            new Map<String, Object>{ 'oppId' => oppId },
            AccessLevel.SYSTEM_MODE
        );
        Assert.areEqual(opp.ContactId, cons[0].Contact__c,
            'contactId 를 안 넘기면 Opportunity.ContactId 로 담당 Contact 를 보완한다');
    }

    @isTest
    static void shouldLeaveContactNull_WhenNeitherArgNorOpportunityContact() {
        // 인자도 없고 Opportunity.ContactId 도 없으면 담당 Contact 는 비운다 (임의 Contact 선택 금지).
        // 기존 setup Opportunity 의 ContactId 를 지우는 대신, 처음부터 ContactId 없는
        // 별도 Opportunity 를 만들어 fallback 마지막 케이스만 독립적으로 검증한다.
        Opportunity seed = theOpp();
        Opportunity opp = new Opportunity(
            Name = 'RP 담당자 미지정 기회',
            AccountId = seed.AccountId,
            StageName = 'Prospecting',
            CloseDate = Date.newInstance(2026, 12, 31),
            Primary_Product__c = seed.Primary_Product__c,
            Amount = 500000000,
            RP_Yield__c = 3.25,
            Fee_Rate__c = 0.15,
            Fee_Amount__c = 1500000,
            Contract_Start_Date__c = Date.newInstance(2026, 9, 1),
            RP_Maturity_Date__c = Date.newInstance(2027, 2, 28),
            Yield_Structure__c = '고정금리',
            Deal_Direction__c = 'RP 매수',
            Yield_Basis__c = '세후'
        );
        insert opp;

        Test.startTest();
        RpContractCreationService.Result r = RpContractCreationService.createContract(opp.Id);
        Test.stopTest();

        Assert.isTrue(r.created, 'Contact 가 없어도 계약은 만든다');
        Id oppId = opp.Id;
        List<Contract> cons = Database.queryWithBinds(
            'SELECT Contact__c FROM Contract WHERE SourceOpportunityId = :oppId LIMIT 1',
            new Map<String, Object>{ 'oppId' => oppId },
            AccessLevel.SYSTEM_MODE
        );
        Assert.isNull(cons[0].Contact__c, '둘 다 없으면 담당 Contact 는 비어 있다');
    }

    @isTest
    static void shouldRejectAndCreateNothing_WhenConditionsMissing() {
        // 확정 조건이 준비되지 않은 Opportunity — 필수값을 비워 둔다.
        Opportunity bare = new Opportunity(
            Name = 'RP 미확정 기회',
            AccountId = theOpp().AccountId,
            StageName = 'Prospecting',
            CloseDate = Date.newInstance(2026, 12, 31)
        );
        insert bare;

        Test.startTest();
        Boolean threw = false;
        try {
            RpContractCreationService.createContract(bare.Id, null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, '확정 조건이 없으면 거절한다');
        Assert.areEqual(0, [SELECT COUNT() FROM Contract WHERE SourceOpportunityId = :bare.Id],
            '검증 실패 시 부분 Contract 를 만들지 않는다');
    }

    @isTest
    static void shouldReject_WhenEndDateBeforeStartDate() {
        Opportunity opp = theOpp();
        Opportunity bad = new Opportunity(
            Id = opp.Id,
            Contract_Start_Date__c = Date.newInstance(2027, 3, 1),
            RP_Maturity_Date__c = Date.newInstance(2026, 12, 1)
        );
        List<String> errors = RpContractCreationService.validate(
            [SELECT AccountId, Primary_Product__c, Amount, RP_Yield__c, Fee_Amount__c,
                    Contract_Start_Date__c, RP_Maturity_Date__c, Yield_Structure__c
             FROM Opportunity WHERE Id = :opp.Id LIMIT 1]
        );
        Assert.areEqual(0, errors.size(), '기본 셋업은 유효하다');

        // 종료일이 시작일보다 빠른 케이스는 validate 에 직접 넣어 확인
        Opportunity flipped = new Opportunity(
            AccountId = opp.AccountId, Primary_Product__c = opp.Primary_Product__c, Amount = 100,
            RP_Yield__c = 3.0, Contract_Start_Date__c = Date.newInstance(2027, 3, 1),
            RP_Maturity_Date__c = Date.newInstance(2026, 12, 1)
        );
        List<String> flippedErrors = RpContractCreationService.validate(flipped);
        Assert.isTrue(flippedErrors.size() == 1 && flippedErrors[0].contains('종료일'),
            '종료일이 시작일보다 빠르면 거절한다');
    }
}