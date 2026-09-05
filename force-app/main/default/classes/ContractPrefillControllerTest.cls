/**
 * ContractPrefillController 테스트.
 * 팀 공용 TestDataFactory 는 쓰지 않고 이 클래스의 @TestSetup 으로만 데이터를 만든다.
 */
@IsTest
private class ContractPrefillControllerTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(Name = '프리필테스트 법인', Business_Registration_Number__c = '9999999999');
        insert acc;

        Contact con = new Contact(LastName = '김담당', name_new__c = '김담당', AccountId = acc.Id, Email = 'prefill.test@example.com', Title = '재무팀장');
        insert con;

        Product2 prod = new Product2(Name = '프리필테스트 RP', Family = 'RP', IsActive = true);
        insert prod;

        // 조건이 모두 채워진 정상 건
        Opportunity ready = new Opportunity(
            Name = '프리필 정상',
            AccountId = acc.Id,
            StageName = '심사',
            CloseDate = Date.today().addDays(30),
            Amount = 1000000000,
            Primary_Product__c = prod.Id,
            Deal_Direction__c = 'RP 매수',
            Issuer_Name__c = '테스트발행사',
            Coupon_Rate__c = 3.1,
            Collateral_Ratio__c = 120.00,
            Contract_Start_Date__c = Date.newInstance(2026, 9, 1),
            RP_Maturity_Date__c = Date.newInstance(2026, 11, 30),
            RP_Yield__c = 3.5,
            Fee_Rate__c = 0.1,
            Special_Terms__c = '테스트 특약'
        );

        // 날짜가 비어 조건 확정이 끝나지 않은 건
        Opportunity notReady = new Opportunity(
            Name = '프리필 미완',
            AccountId = acc.Id,
            StageName = '미팅',
            CloseDate = Date.today().addDays(30)
        );
        insert new List<Opportunity>{ ready, notReady };

        insert new OpportunityContactRole(
            OpportunityId = ready.Id,
            ContactId = con.Id,
            IsPrimary = true
        );
    }

    private static Opportunity oppByName(String name) {
        return [SELECT Id, OwnerId FROM Opportunity WHERE Name = :name LIMIT 1];
    }

    @IsTest
    static void prefillReturnsDefaultsWhenTermsReady() {
        Opportunity opp = oppByName('프리필 정상');

        Test.startTest();
        ContractPrefillController.Prefill result = ContractPrefillController.getPrefill(opp.Id);
        Test.stopTest();

        Assert.isTrue(result.ready, '조건이 채워졌으면 ready 여야 한다');
        Assert.isNull(result.existingContractNumber, '기존 계약이 없어야 한다');

        Map<String, Object> v = result.defaults;
        Assert.areEqual(opp.Id, v.get('SourceOpportunityId'), '영업기회가 연결되어야 한다');
        Assert.areEqual('Draft', v.get('Status'), '계약 상태는 Draft 고정');
        Assert.areEqual('RP 매매계약서', v.get('Contract_Form__c'), 'RP 매수는 RP 매매계약서');
        Assert.areEqual(3, v.get('ContractTerm'), '9/1~11/30 은 3개월');
        Assert.areEqual(1000000000, v.get('Contract_Amount__c'), '약정 금액은 Opportunity Amount');
        Assert.areEqual(3.5, v.get('RP_Yield__c'), '약정 수익률이 옮겨져야 한다');
        Assert.areEqual('테스트 특약', v.get('SpecialTerms'), '특약이 옮겨져야 한다');
        Assert.isNotNull(v.get('Contact__c'), '기본 연락처가 담겨야 한다');
        Assert.areEqual(120.00, v.get('Collateral_Ratio__c'), '담보비율이 옮겨져야 한다');
        Assert.areEqual('테스트발행사', v.get('Issuer_Name__c'), 'Issuer 값이 있으면 그대로 유지');
    }

    @IsTest
    static void prefillFillsSignatureInformation() {
        Opportunity opp = oppByName('프리필 정상');
        Contact con = [SELECT Id FROM Contact LIMIT 1];

        Test.startTest();
        ContractPrefillController.Prefill result = ContractPrefillController.getPrefill(opp.Id);
        Test.stopTest();

        Map<String, Object> v = result.defaults;
        Assert.areEqual(opp.OwnerId, v.get('CompanySignedId'), '자사 서명자는 영업기회 담당 RM');
        Assert.areEqual(con.Id, v.get('CustomerSignedId'), '고객사 서명자는 기본 담당자');
        Assert.areEqual('재무팀장', v.get('CustomerSignedTitle'), '서명자 직책은 기본 담당자의 직책');
        Assert.isFalse(v.containsKey('CompanySignedDate'), '자사 서명일은 미리 채우지 않는다');
        Assert.isFalse(v.containsKey('CustomerSignedDate'), '고객사 서명일은 미리 채우지 않는다');
    }

    @IsTest
    static void prefillOmitsCustomerSignerWhenNoPrimaryContact() {
        Opportunity opp = oppByName('프리필 정상');
        delete [SELECT Id FROM OpportunityContactRole WHERE OpportunityId = :opp.Id];

        Test.startTest();
        ContractPrefillController.Prefill result = ContractPrefillController.getPrefill(opp.Id);
        Test.stopTest();

        Map<String, Object> v = result.defaults;
        Assert.isTrue(result.ready, '기본 담당자가 없어도 계약서 작성은 가능해야 한다');
        Assert.areEqual(opp.OwnerId, v.get('CompanySignedId'), '자사 서명자는 그대로 채워져야 한다');
        Assert.isFalse(v.containsKey('CustomerSignedId'), '기본 담당자가 없으면 고객사 서명자를 비운다');
        Assert.isFalse(v.containsKey('CustomerSignedTitle'), '기본 담당자가 없으면 직책도 비운다');
        Assert.isFalse(v.containsKey('Contact__c'), '기본 담당자가 없으면 담당 Contact 도 비운다');
    }

    @IsTest
    static void prefillUsesNonPrimaryContactRole() {
        // 실제 org 처럼 Contact Role 이 primary 표시 없이 만들어진 경우에도
        // 고객사 서명자가 채워져야 한다.
        Opportunity opp = oppByName('프리필 정상');
        Contact con = [SELECT Id FROM Contact LIMIT 1];
        delete [SELECT Id FROM OpportunityContactRole WHERE OpportunityId = :opp.Id];
        insert new OpportunityContactRole(
            OpportunityId = opp.Id,
            ContactId = con.Id,
            IsPrimary = false
        );

        Test.startTest();
        ContractPrefillController.Prefill result = ContractPrefillController.getPrefill(opp.Id);
        Test.stopTest();

        Map<String, Object> v = result.defaults;
        Assert.isTrue(result.ready, 'primary 표시가 없어도 계약서 작성은 가능해야 한다');
        Assert.areEqual(con.Id, v.get('CustomerSignedId'), 'primary 아니어도 고객사 서명자가 채워져야 한다');
        Assert.areEqual(con.Id, v.get('Contact__c'), 'primary 아니어도 담당 Contact 가 채워져야 한다');
        Assert.areEqual('재무팀장', v.get('CustomerSignedTitle'), '서명자 직책도 채워져야 한다');
    }

    @IsTest
    static void prefillWarnsWhenTermsMissing() {
        Opportunity opp = oppByName('프리필 미완');

        Test.startTest();
        ContractPrefillController.Prefill result = ContractPrefillController.getPrefill(opp.Id);
        Test.stopTest();

        Assert.isFalse(result.ready, '날짜가 비면 ready 가 아니어야 한다');
        Assert.isTrue(result.message.contains('조건 확정'), '안내 문구가 있어야 한다');
        Assert.isTrue(result.defaults.isEmpty(), '기본값을 만들지 않아야 한다');
    }

    @IsTest
    static void prefillReportsExistingContract() {
        Opportunity opp = oppByName('프리필 정상');
        Account acc = [SELECT Id FROM Account LIMIT 1];
        insert new Contract(
            AccountId = acc.Id,
            Status = 'Draft',
            StartDate = Date.today(),
            ContractTerm = 3,
            SourceOpportunityId = opp.Id
        );

        Test.startTest();
        ContractPrefillController.Prefill result = ContractPrefillController.getPrefill(opp.Id);
        Test.stopTest();

        Assert.isTrue(result.ready, '기존 계약이 있어도 진행은 가능해야 한다');
        Assert.isNotNull(result.existingContractId, '기존 계약 Id 를 알려줘야 한다');
        Assert.isNotNull(result.existingContractNumber, '기존 계약번호를 알려줘야 한다');
    }

    @IsTest
    static void prefillWarnsWhenOpportunityMissing() {
        Test.startTest();
        ContractPrefillController.Prefill result = ContractPrefillController.getPrefill(null);
        Test.stopTest();

        Assert.isFalse(result.ready, 'null 이면 ready 가 아니어야 한다');
        Assert.isTrue(result.message.contains('찾을 수 없습니다'), '안내 문구가 있어야 한다');
    }

    @IsTest
    static void prefillDefaultsIssuerWhenBlank() {
        Opportunity opp = oppByName('프리필 정상');
        opp.Issuer_Name__c = null;
        update opp;

        Test.startTest();
        ContractPrefillController.Prefill result = ContractPrefillController.getPrefill(opp.Id);
        Test.stopTest();

        Assert.areEqual('근본증권', result.defaults.get('Issuer_Name__c'), 'Issuer 가 비면 근본증권 기본값');
    }

    @IsTest
    static void contractTermIsAtLeastOneMonth() {
        Date d = Date.newInstance(2026, 9, 1);
        Assert.areEqual(1, ContractPrefillController.monthsBetween(d, d.addDays(10)), '한 달 미만도 1개월');
        Assert.areEqual(3, ContractPrefillController.monthsBetween(d, Date.newInstance(2026, 11, 30)), '9/1~11/30 은 3개월');
        Assert.areEqual(4, ContractPrefillController.monthsBetween(d, Date.newInstance(2026, 12, 1)), '9/1~12/1 은 4개월');
    }

    @IsTest
    static void contractFormFallsBackToEtc() {
        Assert.areEqual('기타', ContractPrefillController.formFor(null), '값이 없으면 기타');
        Assert.areEqual('기타', ContractPrefillController.formFor('알수없음'), '매칭 없으면 기타');
        Assert.areEqual('RP 매매계약서', ContractPrefillController.formFor('RP 매도'), 'RP 매도도 RP 양식');
    }
}