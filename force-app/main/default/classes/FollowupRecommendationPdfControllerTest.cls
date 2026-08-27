@IsTest
private class FollowupRecommendationPdfControllerTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(Name = '대성정밀(주)', Industry = '제조업', Business_Registration_Number__c = '1234567890');
        insert acc;
        insert new Opportunity(Name = '대성정밀 RP', AccountId = acc.Id, StageName = 'Closed Won',
            CloseDate = Date.today(), Last_Recommendation__c = '기존 추천');
    }

    @IsTest
    static void shouldGeneratePdfAndAttachToOpportunity() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        FollowupRecommendationPdfController.Request r = new FollowupRecommendationPdfController.Request();
        r.opportunityId = opp.Id;
        r.recommendationText = '① RP 재계약 + 규모 확대\n② 회사채 발행 검토';

        Test.startTest();
        FollowupRecommendationPdfController.Response res =
            FollowupRecommendationPdfController.generate(new List<FollowupRecommendationPdfController.Request>{ r })[0];
        Test.stopTest();

        Assert.isTrue(res.isSuccess, 'pdf failed: ' + res.errorMessage);
        Assert.isNotNull(res.contentDocumentId);
        Assert.isTrue(res.fileName.startsWith('후속추천_대성정밀(주)_'), res.fileName);
        Assert.isTrue(res.fileName.endsWith('.pdf'));
        List<ContentDocumentLink> links = [SELECT Id FROM ContentDocumentLink WHERE LinkedEntityId = :opp.Id AND ContentDocumentId = :res.contentDocumentId];
        Assert.areEqual(1, links.size(), '기회에 첨부');
    }

    @IsTest
    static void pageControllerShouldUseParamThenFallback() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        PageReference pr = Page.FollowupRecommendationPdf;
        pr.getParameters().put('id', opp.Id);
        pr.getParameters().put('t', '줄1\n줄2');
        Test.setCurrentPage(pr);
        FollowupRecommendationPdfController c1 = new FollowupRecommendationPdfController();
        Assert.areEqual(2, c1.recommendationLines.size());
        Assert.areEqual('대성정밀 RP', c1.opp.Name);
        Assert.isNotNull(c1.generatedAt);

        PageReference pr2 = Page.FollowupRecommendationPdf;
        pr2.getParameters().put('id', opp.Id);
        Test.setCurrentPage(pr2);
        FollowupRecommendationPdfController c2 = new FollowupRecommendationPdfController();
        Assert.areEqual('기존 추천', c2.recommendationText, '파라미터가 없으면 Opp 최근 추천으로');

        Test.setCurrentPage(Page.FollowupRecommendationPdf);
        FollowupRecommendationPdfController c3 = new FollowupRecommendationPdfController();
        Assert.areEqual('', c3.recommendationText, 'id 없음 → 빈 본문');
    }

    @IsTest
    static void shouldFailOnMissingInputs() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        FollowupRecommendationPdfController.Request noText = new FollowupRecommendationPdfController.Request();
        noText.opportunityId = opp.Id;
        FollowupRecommendationPdfController.Request noOpp = new FollowupRecommendationPdfController.Request();
        noOpp.recommendationText = 'x';

        List<FollowupRecommendationPdfController.Response> out =
            FollowupRecommendationPdfController.generate(new List<FollowupRecommendationPdfController.Request>{ noText, noOpp });

        Assert.isFalse(out[0].isSuccess); Assert.isTrue(out[0].errorMessage.contains('본문'));
        Assert.isFalse(out[1].isSuccess); Assert.isTrue(out[1].errorMessage.contains('기회 Id'));
        Assert.areEqual(0, FollowupRecommendationPdfController.generate(null).size());
    }
}