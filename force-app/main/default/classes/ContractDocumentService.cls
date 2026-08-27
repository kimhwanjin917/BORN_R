/**
 * docs/52 — 22번 "계약". 심사 완료된 Opportunity 마다 계약서 PDF 를 만들고 표준 Contract 레코드에 저장,
 * Opportunity 에도 첨부한다. 값이 비어 있으면 빈칸(계약서 관행). 원천: Opportunity·Account·Primary_Product.
 *
 * 순서가 중요하다: getContentAsPDF() 는 콜아웃 취급이라 같은 트랜잭션에서 DML 뒤에 부르면
 * "uncommitted work pending" 이 나고, 별도 요청으로 렌더링되어 미커밋 레코드를 못 본다.
 * 그래서 (1) 값은 URL 파라미터로 넘기고 (2) PDF 를 먼저 전부 렌더링한 뒤 (3) Contract·파일 DML 을 한다.
 * 호출자(OpportunityReviewService)도 이 메서드를 자기 DML 보다 먼저 불러야 한다.
 */
public with sharing class ContractDocumentService {

    public class Result {
        public Id opportunityId;
        public Id contractId;
        public Id contentDocumentId;
        public String fileName;
        public Boolean isSuccess = false;
        public String errorMessage;
    }

    private class Prepared {
        Opportunity opp;
        Contract con;
        Blob pdf;
        String fileName;
    }

    /** 기회별로 PDF → Contract → 파일 순으로 만든다. 개별 실패는 Result 에 담고 다른 기회는 계속 진행한다. */
    public static Map<Id, Result> createContracts(List<Opportunity> oppsIn) {
        Map<Id, Result> results = new Map<Id, Result>();
        if (oppsIn == null || oppsIn.isEmpty()) {
            return results;
        }
        Map<Id, Opportunity> opps = new Map<Id, Opportunity>([
            SELECT Id, Name, OwnerId, Owner.Name, AccountId, Account.Name, Account.Business_Registration_Number__c,
                   Amount, RP_Yield__c, RP_Maturity_Date__c, Issuer_Name__c, Coupon_Rate__c, CurrencyIsoCode,
                   Primary_Product__c, Primary_Product__r.Name, Primary_Product__r.Family, Primary_Product__r.Default_Fee_Rate__c
            FROM Opportunity WHERE Id IN :oppsIn
        ]);
        Map<Id, String> contactByAccount = new Map<Id, String>();
        for (Contact c : [SELECT AccountId, Name FROM Contact WHERE AccountId IN :accountIds(opps.values()) ORDER BY CreatedDate ASC]) {
            if (!contactByAccount.containsKey(c.AccountId)) {
                contactByAccount.put(c.AccountId, c.Name);
            }
        }

        // (1)+(2) 렌더링 먼저 — DML 전
        List<Prepared> prepared = new List<Prepared>();
        Date startDate = Date.today();
        for (Opportunity opp : opps.values()) {
            Result r = new Result();
            r.opportunityId = opp.Id;
            results.put(opp.Id, r);
            if (opp.AccountId == null) {
                r.errorMessage = '고객사(Account)가 없어 계약을 만들 수 없습니다.';
                continue;
            }
            Prepared pr = new Prepared();
            pr.opp = opp;
            Integer termMonths = opp.RP_Maturity_Date__c == null ? 12
                : Math.max(1, startDate.monthsBetween(opp.RP_Maturity_Date__c) + (opp.RP_Maturity_Date__c.day() > startDate.day() ? 1 : 0));
            Decimal fee = opp.Primary_Product__r == null ? null : opp.Primary_Product__r.Default_Fee_Rate__c;
            pr.con = new Contract(
                AccountId = opp.AccountId, SourceOpportunityId = opp.Id, OwnerId = opp.OwnerId, Status = 'Draft',
                StartDate = startDate, ContractTerm = termMonths, CurrencyIsoCode = opp.CurrencyIsoCode,
                Product__c = opp.Primary_Product__c, Contract_Amount__c = opp.Amount, RP_Yield__c = opp.RP_Yield__c,
                Maturity_Date__c = opp.RP_Maturity_Date__c, Fee_Rate__c = fee, Issuer_Name__c = opp.Issuer_Name__c,
                Coupon_Rate__c = opp.Coupon_Rate__c, Description = '자동 생성 계약서 (' + opp.Name + ', 심사 완료)'
            );
            pr.fileName = '계약서_' + opp.Account.Name + '_' + Datetime.now().format('yyyyMMdd', 'Asia/Seoul') + '.pdf';
            try {
                pr.pdf = renderPdf(buildPageParameters(
                    null, opp.Account.Name, opp.Account.Business_Registration_Number__c, contactByAccount.get(opp.AccountId), opp.Owner.Name,
                    opp.Name, opp.Primary_Product__r == null ? null : opp.Primary_Product__r.Name,
                    opp.Primary_Product__r == null ? null : opp.Primary_Product__r.Family,
                    opp.Amount, opp.RP_Yield__c, startDate, opp.RP_Maturity_Date__c, termMonths, fee, opp.Issuer_Name__c, opp.Coupon_Rate__c));
            } catch (Exception e) {
                r.errorMessage = 'PDF 생성 실패: ' + e.getMessage();
                continue;
            }
            prepared.add(pr);
        }
        if (prepared.isEmpty()) {
            return results;
        }

        // (3) Contract
        List<Contract> contracts = new List<Contract>();
        for (Prepared pr : prepared) {
            contracts.add(pr.con);
        }
        List<Database.SaveResult> saves = Database.insert(contracts, false, AccessLevel.USER_MODE);
        List<ContentVersion> files = new List<ContentVersion>();
        List<Prepared> withFile = new List<Prepared>();
        for (Integer i = 0; i < saves.size(); i++) {
            Result r = results.get(prepared[i].opp.Id);
            if (!saves[i].isSuccess()) {
                r.errorMessage = saves[i].getErrors()[0].getMessage();
                continue;
            }
            r.contractId = saves[i].getId();
            r.fileName = prepared[i].fileName;
            files.add(new ContentVersion(Title = r.fileName.removeEnd('.pdf'), PathOnClient = r.fileName,
                VersionData = prepared[i].pdf, FirstPublishLocationId = r.contractId));
            withFile.add(prepared[i]);
        }
        if (files.isEmpty()) {
            return results;
        }
        insert as user files;
        Map<Id, Id> docIdByVersion = new Map<Id, Id>();
        for (ContentVersion cv : [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id IN :files]) {
            docIdByVersion.put(cv.Id, cv.ContentDocumentId);
        }
        List<ContentDocumentLink> links = new List<ContentDocumentLink>();
        for (Integer i = 0; i < files.size(); i++) {
            Result r = results.get(withFile[i].opp.Id);
            r.contentDocumentId = docIdByVersion.get(files[i].Id);
            r.isSuccess = true;
            links.add(new ContentDocumentLink(ContentDocumentId = r.contentDocumentId, LinkedEntityId = withFile[i].opp.Id, ShareType = 'V', Visibility = 'AllUsers'));
        }
        insert as user links;
        return results;
    }

    /** 페이지 파라미터(표시 문자열로 변환). 컨트롤러의 id 경로도 같은 함수를 쓴다. */
    public static Map<String, String> buildPageParameters(
        String contractNumber, String accountName, String brn, String contactName, String ownerName, String opportunityName,
        String productName, String productFamily, Decimal amount, Decimal yieldPct, Date startDate, Date maturity,
        Integer termMonths, Decimal feePct, String issuerName, Decimal couponPct
    ) {
        return new Map<String, String>{
            'contractNumber' => nz(contractNumber), 'accountName' => nz(accountName), 'brn' => nz(brn),
            'contactName' => nz(contactName), 'ownerName' => nz(ownerName), 'opportunityName' => nz(opportunityName),
            'productName' => nz(productName), 'productFamily' => nz(productFamily),
            'amountText' => amount == null ? '' : amount.setScale(0).format() + ' 원',
            'yieldText' => pct(yieldPct), 'startText' => startDate == null ? '' : startDate.format(),
            'maturityText' => maturity == null ? '' : maturity.format(),
            'termText' => termMonths == null ? '' : String.valueOf(termMonths),
            'feeText' => pct(feePct), 'issuerName' => nz(issuerName), 'couponText' => pct(couponPct)
        };
    }

    @TestVisible
    private static Blob renderPdf(Map<String, String> params) {
        PageReference page = Page.ContractDocumentPdf;
        page.getParameters().putAll(params);
        return Test.isRunningTest() ? Blob.valueOf('PDF-TEST ' + params.get('accountName')) : page.getContentAsPDF();
    }

    private static Set<Id> accountIds(List<Opportunity> opps) {
        Set<Id> ids = new Set<Id>();
        for (Opportunity o : opps) {
            if (o.AccountId != null) {
                ids.add(o.AccountId);
            }
        }
        return ids;
    }

    private static String nz(String s) { return s == null ? '' : s; }
    private static String pct(Decimal d) { return d == null ? '' : d.setScale(2).stripTrailingZeros().toPlainString() + ' %'; }
}