/**
 * 계약서 PDF(전체 항목판) 컨트롤러 — Visualforce ContractPdfFull 전용.
 *
 * docs/52 의 ContractDocumentPdf 는 상품팀 회신 직후 아직 커밋되지 않은 Contract 를 그리기 위해
 * 값을 URL 파라미터로 받았다. 이 페이지는 반대로 **이미 저장된 계약**을 대상으로 하므로
 * 계약 Id 하나만 받아 레코드에서 직접 읽는다(수식 필드는 저장 후에만 값이 생기므로 이 방식이어야 한다).
 *
 * - 기존 ContractDocumentPdf / ContractDocumentPdfController / ContractDocumentService 는 건드리지 않는다.
 * - WITH USER_MODE: 실행 사용자가 볼 수 있는 값만 읽는다. 권한 없는 필드는 빈칸으로 나간다.
 * - 값이 비면 빈칸으로 출력한다(계약서에 "null" 이 찍히지 않게 한다).
 */
public with sharing class ContractPdfFullController {

    public String contractNumber { get; private set; }
    public String contractForm { get; private set; }
    public String accountName { get; private set; }
    public String brn { get; private set; }
    public String contactName { get; private set; }
    public String ownerName { get; private set; }
    public String opportunityName { get; private set; }

    public String dealDirection { get; private set; }
    public String productName { get; private set; }
    public String issuerName { get; private set; }
    public String couponText { get; private set; }

    public String startText { get; private set; }
    public String maturityText { get; private set; }
    public String termText { get; private set; }
    public String periodDaysText { get; private set; }

    public String amountText { get; private set; }
    public String yieldText { get; private set; }
    public String yieldStructure { get; private set; }
    public String yieldBasis { get; private set; }
    public String repurchaseText { get; private set; }
    public String profitText { get; private set; }
    public String taxText { get; private set; }

    public String feeRateText { get; private set; }
    public String feeAmountText { get; private set; }
    public String collateralText { get; private set; }

    public String settlementAccount { get; private set; }
    public String earlyRedemption { get; private set; }
    public String specialTerms { get; private set; }

    public String contractDate { get; private set; }
    /** 헤더 우상단 문서번호. 계약 Id 끝 4자리로 문서를 구분한다(계약번호와 별개의 출력물 식별자). */
    public String documentNo { get; private set; }

    public ContractPdfFullController() {
        contractDate = Datetime.now().format('yyyy년 M월 d일', 'Asia/Seoul');
        documentNo = 'BS-RPC-' + Datetime.now().format('yyyyMMdd', 'Asia/Seoul');
        blank();
        String id = ApexPages.currentPage().getParameters().get('id');
        if (String.isNotBlank(id)) {
            documentNo += '-' + id.right(4).toUpperCase();
            bind((Id) id);
        }
    }

    /** 값이 없어도 페이지가 깨지지 않도록 전부 빈 문자열로 시작한다. */
    private void blank() {
        contractNumber = ''; contractForm = ''; accountName = ''; brn = ''; contactName = '';
        ownerName = ''; opportunityName = ''; dealDirection = ''; productName = ''; issuerName = '';
        couponText = ''; startText = ''; maturityText = ''; termText = ''; periodDaysText = '';
        amountText = ''; yieldText = ''; yieldStructure = ''; yieldBasis = ''; repurchaseText = '';
        profitText = ''; taxText = ''; feeRateText = ''; feeAmountText = ''; collateralText = '';
        settlementAccount = ''; earlyRedemption = ''; specialTerms = '';
    }

    private void bind(Id contractId) {
        List<Contract> cs = [
            SELECT Id, ContractNumber, StartDate, ContractTerm, SpecialTerms,
                   Owner.Name, AccountId, Account.Name, Account.Business_Registration_Number__c,
                   SourceOpportunity.Name, Contact__r.Name,
                   Contract_Form__c, Deal_Direction__c, Product__r.Name, Issuer_Name__c, Coupon_Rate__c,
                   Maturity_Date__c, Contract_Period_Days__c,
                   Contract_Amount__c, RP_Yield__c, Yield_Structure__c, Yield_Basis__c,
                   Repurchase_Amount__c, Profit_Amount__c, Tax_Amount__c,
                   Fee_Rate__c, Fee_Amount_Auto__c, Collateral_Ratio__c,
                   Settlement_Account__c, Early_Redemption_Terms__c
            FROM Contract
            WHERE Id = :contractId
            WITH USER_MODE
            LIMIT 1
        ];
        if (cs.isEmpty()) {
            return;
        }
        Contract c = cs[0];

        contractNumber = text(c.ContractNumber);
        contractForm = text(c.Contract_Form__c);
        accountName = c.Account == null ? '' : text(c.Account.Name);
        brn = c.Account == null ? '' : text(c.Account.Business_Registration_Number__c);
        contactName = c.Contact__r == null ? '' : text(c.Contact__r.Name);
        ownerName = c.Owner == null ? '' : text(c.Owner.Name);
        opportunityName = c.SourceOpportunity == null ? '' : text(c.SourceOpportunity.Name);

        dealDirection = text(c.Deal_Direction__c);
        productName = c.Product__r == null ? '' : text(c.Product__r.Name);
        issuerName = text(c.Issuer_Name__c);
        couponText = percent(c.Coupon_Rate__c);

        startText = day(c.StartDate);
        maturityText = day(c.Maturity_Date__c);
        termText = c.ContractTerm == null ? '' : String.valueOf(c.ContractTerm) + '개월';
        periodDaysText = c.Contract_Period_Days__c == null ? '' : c.Contract_Period_Days__c.setScale(0).format() + '일';

        amountText = money(c.Contract_Amount__c);
        yieldText = percent(c.RP_Yield__c);
        yieldStructure = text(c.Yield_Structure__c);
        yieldBasis = text(c.Yield_Basis__c);
        repurchaseText = money(c.Repurchase_Amount__c);
        profitText = money(c.Profit_Amount__c);
        taxText = money(c.Tax_Amount__c);

        feeRateText = percent(c.Fee_Rate__c);
        feeAmountText = money(c.Fee_Amount_Auto__c);
        collateralText = percent(c.Collateral_Ratio__c);

        settlementAccount = text(c.Settlement_Account__c);
        earlyRedemption = text(c.Early_Redemption_Terms__c);
        specialTerms = text(c.SpecialTerms);
    }

    private static String text(String v) {
        return v == null ? '' : v;
    }

    private static String day(Date v) {
        return v == null ? '' : v.year() + '년 ' + v.month() + '월 ' + v.day() + '일';
    }

    private static String money(Decimal v) {
        return v == null ? '' : v.setScale(0).format() + '원';
    }

    private static String percent(Decimal v) {
        return v == null ? '' : v.stripTrailingZeros().toPlainString() + '%';
    }
}