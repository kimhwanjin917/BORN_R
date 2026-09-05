/**
 * 계약서 PDF(전체 항목판) 생성·첨부 — 계약 화면 [계약서 PDF 생성] 버튼이 부른다.
 *
 * Visualforce ContractPdfFull 을 계약 Id 로 렌더링해 그 계약에 파일로 붙인다.
 * 이미 저장된 계약만 대상으로 하므로 수식 필드(환매예정금액·수익금·세금·수수료 금액)까지 찍힌다.
 *
 * - 기존 ContractDocumentService / ContractDocumentPdf 는 건드리지 않는다(다른 흐름 전용).
 * - getContentAsPDF() 는 콜아웃 취급이라 DML 뒤에 부르면 "uncommitted work pending" 이 난다.
 *   그래서 렌더링을 먼저 하고 그다음에 ContentVersion 을 insert 한다.
 * - 같은 계약에 여러 번 누르면 파일이 버전이 아니라 새 파일로 쌓인다(이력 보존).
 */
public with sharing class ContractPdfService {

    /** 화면에 돌려줄 결과. */
    public class Result {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String message;
        @AuraEnabled public String contractNumber;
        @AuraEnabled public Id contentDocumentId;

        Result() {
            this.success = false;
        }
    }

    /**
     * 계약 하나의 PDF 를 만들어 그 계약에 첨부한다.
     * @param contractId 대상 계약
     */
    @AuraEnabled
    public static Result generate(Id contractId) {
        Result r = new Result();
        if (contractId == null) {
            r.message = '계약을 찾을 수 없습니다.';
            return r;
        }

        List<Contract> cs = [
            SELECT Id, ContractNumber, Account.Name
            FROM Contract
            WHERE Id = :contractId
            WITH USER_MODE
            LIMIT 1
        ];
        if (cs.isEmpty()) {
            r.message = '계약을 찾을 수 없습니다.';
            return r;
        }
        Contract c = cs[0];
        r.contractNumber = c.ContractNumber;

        Blob pdf;
        try {
            pdf = render(contractId, c.Account == null ? '' : c.Account.Name);
        } catch (Exception e) {
            r.message = 'PDF 생성에 실패했습니다: ' + e.getMessage();
            return r;
        }

        String fileName = fileNameFor(c);
        ContentVersion cv = new ContentVersion(
            Title = fileName.removeEnd('.pdf'),
            PathOnClient = fileName,
            VersionData = pdf,
            FirstPublishLocationId = contractId
        );
        try {
            insert cv;
        } catch (DmlException e) {
            r.message = '계약서 파일 저장에 실패했습니다: ' + e.getDmlMessage(0);
            return r;
        }

        List<ContentVersion> saved = [
            SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id LIMIT 1
        ];
        if (!saved.isEmpty()) {
            r.contentDocumentId = saved[0].ContentDocumentId;
        }
        r.success = true;
        r.message = '계약서 ' + c.ContractNumber + ' PDF 를 계약에 첨부했습니다.';
        return r;
    }

    /** 파일명: 계약서_{계약번호}_{고객사}.pdf */
    @TestVisible
    private static String fileNameFor(Contract c) {
        String account = (c.Account == null || String.isBlank(c.Account.Name)) ? '' : '_' + c.Account.Name;
        return '계약서_' + c.ContractNumber + account + '.pdf';
    }

    /** 테스트에서는 렌더링을 하지 않는다(getContentAsPDF 는 테스트 컨텍스트에서 쓸 수 없다). */
    private static Blob render(Id contractId, String accountName) {
        PageReference page = Page.ContractPdfFull;
        page.getParameters().put('id', contractId);
        return Test.isRunningTest() ? Blob.valueOf('PDF-TEST ' + accountName) : page.getContentAsPDF();
    }
}