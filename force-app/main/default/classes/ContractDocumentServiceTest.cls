@IsTest
private class ContractDocumentServiceTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(Name = '대성정밀(주)', Industry = '제조업', Business_Registration_Number__c = '1234567890');
        insert acc;
        Product2 rp = new Product2(Name = 'RP (환매조건부채권)', Family = 'RP', IsActive = true, Default_Fee_Rate__c = 0.5);
        insert rp;
        insert new List<Opportunity>{
            new Opportunity(Name = '대성정밀 RP', AccountId = acc.Id, StageName = '심사', CloseDate = Date.today().addDays(30),
                Amount = 100000000, Primary_Product__c = rp.Id, RP_Yield__c = 3.2, RP_Maturity_Date__c = Date.today().addMonths(6),
                Issuer_Name__c = '한국전력', Coupon_Rate__c = 4.1),
            new Opportunity(Name = '빈값 기회', AccountId = acc.Id, StageName = '미팅', CloseDate = Date.today().addDays(30))
        };
    }

    @IsTest
    static void shouldCreateContractsWithCopiedValues_AndBlankWhenMissing() {
        List<Opportunity> opps = [SELECT Id, Name FROM Opportunity ORDER BY Name];

        Test.startTest();
        Map<Id, ContractDocumentService.Result> results = ContractDocumentService.createContracts(opps);
        Test.stopTest();

        Assert.areEqual(2, results.size());
        for (Opportunity opp : opps) {
            ContractDocumentService.Result r = results.get(opp.Id);
            Assert.isTrue(r.isSuccess, opp.Name + ': ' + r.errorMessage);
            Assert.isNotNull(r.contractId);
            Assert.isNotNull(r.contentDocumentId);
            Assert.isTrue(r.fileName.startsWith('계약서_대성정밀(주)_'), r.fileName);
        }
        Contract full = [SELECT Contract_Amount__c, RP_Yield__c, Issuer_Name__c, Coupon_Rate__c, Fee_Rate__c, Maturity_Date__c, Product__r.Family, Status, StartDate, ContractTerm FROM Contract WHERE SourceOpportunityId = :opps[0].Id];
        Assert.areEqual('한국전력', full.Issuer_Name__c);
        Assert.areEqual(4.1, full.Coupon_Rate__c);
        Assert.areEqual('RP', full.Product__r.Family);
        Assert.areEqual(Date.today(), full.StartDate);
        Contract blank = [SELECT Contract_Amount__c, RP_Yield__c, Product__c, ContractTerm FROM Contract WHERE SourceOpportunityId = :opps[1].Id];
        Assert.isNull(blank.Contract_Amount__c, '값 없으면 빈칸');
        Assert.isNull(blank.Product__c);
        Assert.areEqual(12, blank.ContractTerm, '만기 없으면 기본 12개월');
    }

    @IsTest
    static void shouldReportErrorWhenNoAccount() {
        Opportunity noAcc = new Opportunity(Name = '고객사 없음', StageName = '미팅', CloseDate = Date.today());
        insert noAcc;
        ContractDocumentService.Result r = ContractDocumentService.createContracts(new List<Opportunity>{ noAcc }).get(noAcc.Id);
        Assert.isFalse(r.isSuccess);
        Assert.isTrue(r.errorMessage.contains('고객사'));
        Assert.areEqual(0, ContractDocumentService.createContracts(null).size());
    }
}