/**
 * docs/51 — 후속 추천 PDF. Visualforce 페이지 FollowupRecommendationPdf(renderAs="pdf") 의 컨트롤러이자,
 * 화면 Flow 가 "PDF 생성하시겠습니까? → 예" 뒤에 부르는 Invocable.
 *
 * - getContentAsPDF() 는 별도 요청으로 렌더링되므로 추천 본문은 URL 파라미터 't' 로 넘긴다(정적 변수·미커밋 DML 은 보이지 않음).
 *   파라미터가 없으면 Opportunity.Last_Recommendation__c 로 대체한다.
 * - 한글: VF PDF 렌더러 내장 'Arial Unicode MS'. 생성 PDF 는 ContentVersion 으로 Opportunity 에 연결한다.
 * - 렌더링(콜아웃 취급)을 먼저 하고 DML 은 그 뒤에 한다.
 */
public with sharing class FollowupRecommendationPdfController {

    public Opportunity opp { get; private set; }
    public String recommendationText { get; private set; }
    public List<String> recommendationLines { get; private set; }
    public String generatedAt { get; private set; }

    public FollowupRecommendationPdfController() {
        Map<String, String> p = ApexPages.currentPage().getParameters();
        Id oppId = p.get('id');
        opp = oppId == null ? new Opportunity() : [
            SELECT Id, Name, Account.Name, Account.Industry, Owner.Name, Primary_Product__r.Name, Product_Family__c, Last_Recommendation__c
            FROM Opportunity WHERE Id = :oppId WITH USER_MODE LIMIT 1
        ];
        recommendationText = p.get('t') != null ? p.get('t') : opp.Last_Recommendation__c;
        if (recommendationText == null) {
            recommendationText = '';
        }
        recommendationLines = recommendationText.split('\n');
        generatedAt = Datetime.now().format('yyyy-MM-dd HH:mm', 'Asia/Seoul');
    }

    public class Request {
        @InvocableVariable(label='Opportunity Id' required=true)
        public Id opportunityId;
        @InvocableVariable(label='추천 본문' description='화면에 표시한 에이전트 추천 텍스트' required=true)
        public String recommendationText;
    }

    public class Response {
        @InvocableVariable(label='성공 여부') public Boolean isSuccess;
        @InvocableVariable(label='ContentDocument Id') public Id contentDocumentId;
        @InvocableVariable(label='파일명') public String fileName;
        @InvocableVariable(label='오류 메시지') public String errorMessage;
    }

    @InvocableMethod(
        label='후속 추천 PDF 생성·첨부'
        description='에이전트 후속 추천 본문을 PDF 로 만들어 기회의 파일로 첨부합니다.'
        category='근본증권 RM')
    public static List<Response> generate(List<Request> requests) {
        List<Response> out = new List<Response>();
        if (requests == null) {
            return out;
        }
        for (Request req : requests) {
            Response res = new Response();
            try {
                res.contentDocumentId = generateAndAttach(req.opportunityId, req.recommendationText, res);
                res.isSuccess = true;
            } catch (Exception e) {
                res.isSuccess = false;
                res.errorMessage = e.getMessage();
            }
            out.add(res);
        }
        return out;
    }

    private static Id generateAndAttach(Id oppId, String text, Response res) {
        if (oppId == null) {
            throw new PdfException('기회 Id 가 비어 있습니다.');
        }
        if (String.isBlank(text)) {
            throw new PdfException('추천 본문이 비어 있습니다.');
        }
        Opportunity opp = [SELECT Name, Account.Name FROM Opportunity WHERE Id = :oppId WITH USER_MODE LIMIT 1];
        Blob pdf = renderPdf(oppId, text);
        String fileName = '후속추천_' + (opp.Account == null ? opp.Name : opp.Account.Name) + '_'
            + Datetime.now().format('yyyyMMdd', 'Asia/Seoul') + '.pdf';
        ContentVersion cv = new ContentVersion(
            Title = fileName.removeEnd('.pdf'), PathOnClient = fileName, VersionData = pdf, FirstPublishLocationId = oppId
        );
        insert as user cv;
        res.fileName = fileName;
        return [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
    }

    @TestVisible
    private static Blob renderPdf(Id oppId, String text) {
        PageReference page = Page.FollowupRecommendationPdf;
        page.getParameters().put('id', oppId);
        page.getParameters().put('t', text.abbreviate(6000)); // URL 길이 보호
        return Test.isRunningTest() ? Blob.valueOf('PDF-TEST ' + text) : page.getContentAsPDF();
    }

    public class PdfException extends Exception {}
}