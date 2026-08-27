/**
 * 리드 상품 제안서 PDF(LeadProposalPdf) 의 컨트롤러.
 *
 * getContentAsPDF() 는 콜아웃 취급이라 별도 요청으로 렌더링된다 — 정적 변수도 미커밋 DML 도 보이지 않으므로
 * 화면에서 고른 상품·수익률·제안 배경은 전부 URL 파라미터 'd'(JSON) 로 넘긴다.
 * (org 의 ContractDocumentService·FollowupRecommendationPdfController 와 같은 방식이다.)
 *
 * 문서에 실을 값의 서식(금액 표기, 억 단위 병기, 세금 계산)은 전부 LeadProposalController 에서 만들어
 * ProposalDoc 에 담아 넘긴다. 이 클래스는 받아서 그리기만 한다.
 */
public with sharing class LeadProposalPdfController {

    /** URL 파라미터 JSON 이 담기는 그릇. VF 가 읽으므로 전부 프로퍼티여야 한다. */
    public class ProposalDoc {
        public String docNumber { get; set; }
        public String createdDateText { get; set; }
        public String companyName { get; set; }
        public String industry { get; set; }
        public String recipient { get; set; }
        public String ownerName { get; set; }

        public Boolean hasMemo { get; set; }
        public String backgroundMemo { get; set; }

        public Boolean hasFinancials { get; set; }
        public String finReportLabel { get; set; }
        public String finPeriodYm { get; set; }
        public String cashText { get; set; }
        public String cashUnit { get; set; }
        public Boolean hasStfi { get; set; }
        public String stfiText { get; set; }
        public String stfiUnit { get; set; }

        public List<ProductRow> products { get; set; }

        public Boolean hasSimulation { get; set; }
        public String assumedAmountText { get; set; }
        public List<SimRow> simulations { get; set; }

        public String complianceReviewText { get; set; }

        public ProposalDoc() {
            hasMemo = false;
            hasFinancials = false;
            hasStfi = false;
            hasSimulation = false;
            products = new List<ProductRow>();
            simulations = new List<SimRow>();
        }
    }

    public class ProductRow {
        public String name { get; set; }
        public String family { get; set; }
        public String term { get; set; }
        public String yieldText { get; set; }
        public String note { get; set; }
    }

    public class SimRow {
        public String name { get; set; }
        public String term { get; set; }
        public String grossText { get; set; }
        public String taxText { get; set; }
        public String netText { get; set; }
    }

    public ProposalDoc doc { get; private set; }

    public LeadProposalPdfController() {
        String payload = ApexPages.currentPage().getParameters().get('d');
        doc = parse(payload);
    }

    /**
     * 파라미터가 없거나 깨졌으면 빈 문서를 돌려준다 — 렌더링 자체가 실패하면 사용자는
     * 원인을 알 수 없는 오류만 보게 되므로, 빈 제안서라도 나오게 해서 무엇이 빠졌는지 보이게 한다.
     */
    @TestVisible
    private static ProposalDoc parse(String payload) {
        if (String.isBlank(payload)) {
            return new ProposalDoc();
        }
        try {
            ProposalDoc parsed = (ProposalDoc) JSON.deserialize(payload, ProposalDoc.class);
            return parsed == null ? new ProposalDoc() : parsed;
        } catch (Exception e) {
            return new ProposalDoc();
        }
    }

    /** 제안서 PDF 를 렌더링한다. DML 보다 반드시 먼저 불러야 한다 (uncommitted work pending). */
    public static Blob render(ProposalDoc doc) {
        PageReference page = Page.LeadProposalPdf;
        page.getParameters().put('d', JSON.serialize(doc));
        return Test.isRunningTest()
            ? Blob.valueOf('PDF-TEST ' + doc.docNumber + ' ' + doc.companyName)
            : page.getContentAsPDF();
    }
}