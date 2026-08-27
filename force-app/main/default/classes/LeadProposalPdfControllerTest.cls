/**
 * PDF 컨트롤러는 URL 파라미터로만 값을 받는다. 파라미터가 깨졌을 때 렌더링 자체가 죽으면
 * 사용자는 원인을 알 수 없는 오류만 보게 되므로, 빈 문서로라도 떨어지는지를 함께 확인한다.
 */
@IsTest
private class LeadProposalPdfControllerTest {

    @IsTest
    static void parsesPayloadFromPageParameter() {
        LeadProposalPdfController.ProposalDoc source = new LeadProposalPdfController.ProposalDoc();
        source.docNumber = 'BS-PRP-20260827-4K2N';
        source.companyName = '씨앤씨인터내셔널';
        source.hasMemo = true;
        source.backgroundMemo = '3분기 증설 자금 일정 반영';

        LeadProposalPdfController.ProductRow row = new LeadProposalPdfController.ProductRow();
        row.name = 'RP 91일물';
        row.yieldText = '3.20%';
        source.products.add(row);

        PageReference page = Page.LeadProposalPdf;
        page.getParameters().put('d', JSON.serialize(source));
        Test.setCurrentPage(page);

        Test.startTest();
        LeadProposalPdfController controller = new LeadProposalPdfController();
        Test.stopTest();

        System.Assert.areEqual('BS-PRP-20260827-4K2N', controller.doc.docNumber, '문서번호가 그대로 넘어와야 한다');
        System.Assert.areEqual('씨앤씨인터내셔널', controller.doc.companyName, '고객사가 그대로 넘어와야 한다');
        System.Assert.areEqual(1, controller.doc.products.size(), '상품 목록이 넘어와야 한다');
        System.Assert.areEqual('3.20%', controller.doc.products[0].yieldText, '수익률 표기가 유지돼야 한다');
    }

    @IsTest
    static void fallsBackToEmptyDocWhenNoParameter() {
        Test.setCurrentPage(Page.LeadProposalPdf);

        Test.startTest();
        LeadProposalPdfController controller = new LeadProposalPdfController();
        Test.stopTest();

        System.Assert.isNotNull(controller.doc, '빈 문서라도 있어야 렌더링이 죽지 않는다');
        System.Assert.isFalse(controller.doc.hasMemo, '없는 블록은 꺼져 있어야 한다');
        System.Assert.isFalse(controller.doc.hasFinancials, '없는 블록은 꺼져 있어야 한다');
        System.Assert.isFalse(controller.doc.hasSimulation, '없는 블록은 꺼져 있어야 한다');
        System.Assert.isTrue(controller.doc.products.isEmpty(), '상품 목록은 빈 리스트여야 한다 (null 이면 VF 가 죽는다)');
    }

    @IsTest
    static void fallsBackToEmptyDocWhenPayloadIsBroken() {
        LeadProposalPdfController.ProposalDoc doc = LeadProposalPdfController.parse('{이건 JSON 이 아니다');

        System.Assert.isNotNull(doc, '깨진 파라미터로 예외를 던지면 안 된다');
        System.Assert.isTrue(doc.products.isEmpty(), '빈 상품 목록으로 초기화돼야 한다');
    }

    @IsTest
    static void renderPassesDocToPage() {
        LeadProposalPdfController.ProposalDoc doc = new LeadProposalPdfController.ProposalDoc();
        doc.docNumber = 'BS-PRP-20260827-TEST';
        doc.companyName = '넉넉기업';

        Test.startTest();
        Blob rendered = LeadProposalPdfController.render(doc);
        Test.stopTest();

        System.Assert.isNotNull(rendered, '테스트에서는 실제 PDF 대신 대체 Blob 이 나온다');
        System.Assert.isTrue(rendered.toString().contains('넉넉기업'), '문서 내용이 렌더링에 전달돼야 한다');
    }
}