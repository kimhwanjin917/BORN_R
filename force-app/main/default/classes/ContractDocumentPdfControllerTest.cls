@IsTest
private class ContractDocumentPdfControllerTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(Name = '대성정밀(주)', Industry = '제조업', Business_Registration_Number__c = '1234567890');
        insert acc;
        insert new Contact(LastName = '김담당', name_new__c = '김담당', AccountId = acc.Id, Email = 'kim@daesung.demo');
        Product2 rp = new Product2(Name = 'RP (환매조건부채권)', Family = 'RP', IsActive = true);
        insert rp;
        Opportunity opp = new Opportunity(Name = '대성정밀 RP', AccountId = acc.Id, StageName = '심사', CloseDate = Date.today());
        insert opp;
        insert new Contract(AccountId = acc.Id, SourceOpportunityId = opp.Id, Status = 'Draft', StartDate = Date.today(), ContractTerm = 6,
            Product__c = rp.Id, Contract_Amount__c = 100000000, RP_Yield__c = 3.2, Fee_Rate__c = 0.5, Coupon_Rate__c = 4.1,
            Maturity_Date__c = Date.today().addMonths(6), Issuer_Name__c = '한국전력');
    }

    @IsTest
    static void shouldBindFromParameters() {
        PageReference pr = Page.ContractDocumentPdf;
        pr.getParameters().putAll(ContractDocumentService.buildPageParameters(
            'C-001', '대성정밀(주)', '1234567890', '김담당', '이상윤', '대성정밀 RP', 'RP (환매조건부채권)', 'RP',
            100000000, 3.2, Date.today(), Date.today().addMonths(6), 6, 0.5, '한국전력', 4.1));
        Test.setCurrentPage(pr);

        ContractDocumentPdfController ctrl = new ContractDocumentPdfController();

        Assert.areEqual('C-001', ctrl.contractNumber);
        Assert.areEqual('대성정밀(주)', ctrl.accountName);
        Assert.areEqual('김담당', ctrl.contactName);
        Assert.areEqual('이상윤', ctrl.ownerName);
        Assert.areEqual('100,000,000 원', ctrl.amountText);
        Assert.areEqual('3.2 %', ctrl.yieldText);
        Assert.areEqual('0.5 %', ctrl.feeText);
        Assert.areEqual('4.1 %', ctrl.couponText);
        Assert.areEqual('6', ctrl.termText);
        Assert.areEqual('한국전력', ctrl.issuerName);
        Assert.isTrue(ctrl.maturityText.length() > 0);
        Assert.isTrue(ctrl.contractDate.contains('년'));
    }

    @IsTest
    static void shouldBindFromCommittedContractById() {
        Contract c = [SELECT Id FROM Contract LIMIT 1];
        PageReference pr = Page.ContractDocumentPdf;
        pr.getParameters().put('id', c.Id);
        Test.setCurrentPage(pr);

        ContractDocumentPdfController ctrl = new ContractDocumentPdfController();

        Assert.areEqual('대성정밀(주)', ctrl.accountName);
        Assert.areEqual('김담당', ctrl.contactName, '고객사 첫 Contact');
        Assert.areEqual('100,000,000 원', ctrl.amountText);
        Assert.areEqual('RP', ctrl.productFamily);
        Assert.isTrue(ctrl.contractNumber.length() > 0, '커밋된 계약은 계약번호 표시');
    }

    @IsTest
    static void shouldHandleMissingIdAndBlankValues() {
        Test.setCurrentPage(Page.ContractDocumentPdf);
        ContractDocumentPdfController ctrl = new ContractDocumentPdfController();
        Assert.areEqual('', ctrl.amountText);
        Assert.areEqual('', ctrl.yieldText);
        Assert.areEqual('', ctrl.contactName);
        Assert.areEqual('', ctrl.maturityText);
        Assert.areEqual('', ctrl.contractNumber);
    }
}