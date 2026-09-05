/**
 * ContractPdfFullController 테스트.
 * 팀 공용 TestDataFactory 는 쓰지 않고 이 클래스의 @TestSetup 으로만 데이터를 만든다.
 */
@IsTest
private class ContractPdfFullControllerTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(Name = 'PDF테스트 법인', Business_Registration_Number__c = '1234512345');
        insert acc;

        Contact con = new Contact(
            LastName = '박대리', name_new__c = '박대리', AccountId = acc.Id, Email = 'pdf.test@example.com'
        );
        insert con;

        Product2 prod = new Product2(Name = 'PDF테스트 RP', Family = 'RP', IsActive = true);
        insert prod;

        insert new Contract(
            AccountId = acc.Id,
            Status = 'Draft',
            StartDate = Date.newInstance(2026, 9, 1),
            ContractTerm = 3,
            Maturity_Date__c = Date.newInstance(2026, 11, 30),
            Contract_Amount__c = 1000000000,
            RP_Yield__c = 3.5,
            Fee_Rate__c = 0.1,
            Coupon_Rate__c = 3.1,
            Issuer_Name__c = 'PDF발행사',
            Deal_Direction__c = 'RP 매수',
            Contract_Form__c = 'RP 매매계약서',
            Product__c = prod.Id,
            Contact__c = con.Id,
            SpecialTerms = 'PDF 특약',
            Settlement_Account__c = '123-456-789',
            Early_Redemption_Terms__c = '불가',
            Collateral_Ratio__c = 105
        );
    }

    private static Contract theContract() {
        return [SELECT Id, ContractNumber FROM Contract LIMIT 1];
    }

    @IsTest
    static void bindsSavedContractValues() {
        Contract c = theContract();
        PageReference page = Page.ContractPdfFull;
        page.getParameters().put('id', c.Id);
        Test.setCurrentPage(page);

        Test.startTest();
        ContractPdfFullController ctrl = new ContractPdfFullController();
        Test.stopTest();

        Assert.areEqual(c.ContractNumber, ctrl.contractNumber, '계약번호가 찍혀야 한다');
        Assert.areEqual('PDF테스트 법인', ctrl.accountName, '고객사명이 찍혀야 한다');
        Assert.areEqual('1234512345', ctrl.brn, '사업자등록번호가 찍혀야 한다');
        Assert.areEqual(
            'BS-RPC-' + Datetime.now().format('yyyyMMdd', 'Asia/Seoul') + '-' + String.valueOf(c.Id).right(4).toUpperCase(),
            ctrl.documentNo,
            '문서번호는 BS-RPC-작성일-계약Id끝4자리 여야 한다'
        );
        Assert.areEqual('RP 매수', ctrl.dealDirection, '거래 방향이 찍혀야 한다');
        Assert.areEqual('RP 매매계약서', ctrl.contractForm, '계약 양식이 찍혀야 한다');
        Assert.isTrue(ctrl.contactName.contains('박대리'), '대표자·대리인이 찍혀야 한다');
        Assert.isTrue(ctrl.amountText.contains('원'), '금액은 원 단위로 표기한다');
        Assert.isTrue(ctrl.yieldText.contains('%'), '수익률은 % 로 표기한다');
        Assert.isTrue(ctrl.startText.contains('2026년'), '날짜는 한국어로 표기한다');
        Assert.areEqual('3개월', ctrl.termText, '계약 기간 표기');
        Assert.areEqual('불가', ctrl.earlyRedemption, '중도환매 조건이 찍혀야 한다');
        Assert.areEqual('PDF 특약', ctrl.specialTerms, '특약이 찍혀야 한다');
    }

    @IsTest
    static void bindsCalculatedAmounts() {
        Contract c = theContract();
        PageReference page = Page.ContractPdfFull;
        page.getParameters().put('id', c.Id);
        Test.setCurrentPage(page);

        Test.startTest();
        ContractPdfFullController ctrl = new ContractPdfFullController();
        Test.stopTest();

        Assert.areEqual('90일', ctrl.periodDaysText, '9/1~11/30 은 90일');
        Assert.isTrue(ctrl.repurchaseText.contains('원'), '환매예정금액이 계산되어야 한다');
        Assert.isTrue(ctrl.profitText.contains('원'), '수익금이 계산되어야 한다');
        Assert.isTrue(ctrl.taxText.contains('원'), '세금이 계산되어야 한다');
        Assert.isTrue(ctrl.feeAmountText.contains('원'), '수수료 금액이 계산되어야 한다');
    }

    @IsTest
    static void rendersBlankWhenNoId() {
        Test.setCurrentPage(Page.ContractPdfFull);

        Test.startTest();
        ContractPdfFullController ctrl = new ContractPdfFullController();
        Test.stopTest();

        Assert.areEqual('', ctrl.contractNumber, 'id 가 없으면 빈칸이어야 한다');
        Assert.areEqual('', ctrl.accountName, '빈칸이어야 한다');
        Assert.isTrue(String.isNotBlank(ctrl.contractDate), '작성일은 항상 채운다');
        Assert.areEqual(
            'BS-RPC-' + Datetime.now().format('yyyyMMdd', 'Asia/Seoul'),
            ctrl.documentNo,
            'id 가 없으면 문서번호에 계약 접미사가 붙지 않는다'
        );
    }

    @IsTest
    static void rendersBlankWhenContractMissing() {
        PageReference page = Page.ContractPdfFull;
        page.getParameters().put('id', '800000000000000AAA');
        Test.setCurrentPage(page);

        Test.startTest();
        ContractPdfFullController ctrl = new ContractPdfFullController();
        Test.stopTest();

        Assert.areEqual('', ctrl.contractNumber, '없는 계약이면 빈칸이어야 한다');
    }
}