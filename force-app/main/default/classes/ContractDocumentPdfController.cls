/**
 * docs/52 — 계약서 PDF(Visualforce ContractDocumentPdf, renderAs="pdf") 컨트롤러.
 *
 * getContentAsPDF() 는 별도 요청으로 렌더링되므로 같은 트랜잭션에서 막 insert 한 Contract 를 볼 수 없다.
 * 그래서 값은 전부 URL 파라미터로 받는다(ContractDocumentService.buildPageParameters). id 로 조회하는 경로는
 * 이미 커밋된 Contract 를 다시 출력할 때(파라미터 없이 페이지를 직접 열 때)만 쓴다. 빈 값은 빈칸.
 */
public with sharing class ContractDocumentPdfController {

    public String contractNumber { get; private set; }
    public String accountName { get; private set; }
    public String brn { get; private set; }
    public String contactName { get; private set; }
    public String ownerName { get; private set; }
    public String opportunityName { get; private set; }
    public String productName { get; private set; }
    public String productFamily { get; private set; }
    public String amountText { get; private set; }
    public String yieldText { get; private set; }
    public String startText { get; private set; }
    public String maturityText { get; private set; }
    public String termText { get; private set; }
    public String feeText { get; private set; }
    public String issuerName { get; private set; }
    public String couponText { get; private set; }
    public String contractDate { get; private set; }

    public ContractDocumentPdfController() {
        Map<String, String> p = ApexPages.currentPage().getParameters();
        contractDate = Datetime.now().format('yyyy년 M월 d일', 'Asia/Seoul');
        if (p.containsKey('accountName')) {
            bindFromParameters(p);
        } else if (p.get('id') != null) {
            bindFromContract((Id) p.get('id'));
        } else {
            bindFromParameters(new Map<String, String>());
        }
    }

    private void bindFromParameters(Map<String, String> p) {
        contractNumber = nz(p.get('contractNumber'));
        accountName = nz(p.get('accountName'));
        brn = nz(p.get('brn'));
        contactName = nz(p.get('contactName'));
        ownerName = nz(p.get('ownerName'));
        opportunityName = nz(p.get('opportunityName'));
        productName = nz(p.get('productName'));
        productFamily = nz(p.get('productFamily'));
        amountText = nz(p.get('amountText'));
        yieldText = nz(p.get('yieldText'));
        startText = nz(p.get('startText'));
        maturityText = nz(p.get('maturityText'));
        termText = nz(p.get('termText'));
        feeText = nz(p.get('feeText'));
        issuerName = nz(p.get('issuerName'));
        couponText = nz(p.get('couponText'));
    }

    private void bindFromContract(Id contractId) {
        List<Contract> cs = [
            SELECT Id, ContractNumber, StartDate, ContractTerm, Owner.Name, AccountId, Account.Name,
                   Account.Business_Registration_Number__c, SourceOpportunity.Name, Product__r.Name, Product__r.Family,
                   Contract_Amount__c, RP_Yield__c, Maturity_Date__c, Fee_Rate__c, Issuer_Name__c, Coupon_Rate__c
            FROM Contract WHERE Id = :contractId WITH USER_MODE LIMIT 1
        ];
        if (cs.isEmpty()) {
            bindFromParameters(new Map<String, String>());
            return;
        }
        Contract con = cs[0];
        String contact = '';
        List<Contact> people = [SELECT Name FROM Contact WHERE AccountId = :con.AccountId WITH USER_MODE ORDER BY CreatedDate ASC LIMIT 1];
        if (!people.isEmpty()) {
            contact = people[0].Name;
        }
        bindFromParameters(ContractDocumentService.buildPageParameters(
            con.ContractNumber, con.Account.Name, con.Account.Business_Registration_Number__c, contact, con.Owner.Name,
            con.SourceOpportunity == null ? null : con.SourceOpportunity.Name,
            con.Product__r == null ? null : con.Product__r.Name, con.Product__r == null ? null : con.Product__r.Family,
            con.Contract_Amount__c, con.RP_Yield__c, con.StartDate, con.Maturity_Date__c, con.ContractTerm,
            con.Fee_Rate__c, con.Issuer_Name__c, con.Coupon_Rate__c));
    }

    private static String nz(String s) {
        return s == null ? '' : s;
    }
}