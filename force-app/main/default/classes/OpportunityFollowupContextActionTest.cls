@IsTest
private class OpportunityFollowupContextActionTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(Name = '대성정밀(주)', Industry = '제조업', Business_Registration_Number__c = '1234567890');
        insert acc;
        Product2 rp = new Product2(Name = 'RP (환매조건부채권)', Family = 'RP', IsActive = true);
        insert rp;
        Opportunity opp = new Opportunity(
            Name = '대성정밀 RP', AccountId = acc.Id, StageName = 'Closed Won',
            CloseDate = Date.today().addDays(-90), Primary_Product__c = rp.Id,
            Last_Recommendation__c = '지난 추천: RP 유지'
        );
        insert opp;
        List<Meeting_Note__c> notes = new List<Meeting_Note__c>();
        for (Integer i = 0; i < 5; i++) {
            notes.add(new Meeting_Note__c(Opportunity__c = opp.Id, Raw_Content__c = '메모 ' + i + ' 010-1111-222' + i));
        }
        insert notes;
        insert new Asset(Name = 'RP 1억', AccountId = acc.Id, Product2Id = rp.Id, Price = 100000000,
            UsageEndDate = Date.today().addDays(30), Status = 'Installed');
        insert new List<CorporateFinancialStatement__c>{
            new CorporateFinancialStatement__c(Account__c = acc.Id, Fiscal_Year__c = 2024, Period_Type__c = '연간', Cash_And_Equivalents__c = 20000000),
            new CorporateFinancialStatement__c(Account__c = acc.Id, Fiscal_Year__c = 2025, Period_Type__c = '연간', Cash_And_Equivalents__c = 35000000, Bonds_Payable__c = 5000000),
            new CorporateFinancialStatement__c(Account__c = acc.Id, Fiscal_Year__c = 2023, Period_Type__c = '연간')
        };
        insert new List<ExternalSignal__c>{
            new ExternalSignal__c(Account__c = acc.Id, Signal_Type__c = '수주', Title__c = '대규모 수주', Signal_Date__c = Date.today().addDays(-5), Amount__c = 300000000),
            new ExternalSignal__c(Account__c = acc.Id, Signal_Type__c = '뉴스', Title__c = '설비 증설', Signal_Date__c = Date.today().addDays(-20))
        };
    }

    private static OpportunityFollowupContextAction.Response run(Id oppId) {
        OpportunityFollowupContextAction.Request r = new OpportunityFollowupContextAction.Request();
        r.opportunityId = oppId;
        return OpportunityFollowupContextAction.gather(new List<OpportunityFollowupContextAction.Request>{ r })[0];
    }

    @IsTest
    static void shouldGatherAllContext() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];

        OpportunityFollowupContextAction.Response res = run(opp.Id);

        Assert.isTrue(res.isAccessible, res.message);
        Assert.areEqual('대성정밀(주)', res.accountName);
        Assert.areEqual('RP (환매조건부채권)', res.primaryProductName);
        Assert.areEqual('지난 추천: RP 유지', res.lastRecommendation);
        Assert.areEqual(OpportunityFollowupContextAction.MAX_NOTES, res.pastNotesText.split('\n').size(), '정제본 최근 3건');
        Assert.isFalse(res.pastNotesText.contains('010-1111'), '정제본만 사용(전화번호 마스킹됨)');
        Assert.isTrue(res.hasMaturingAsset, '30일 뒤 만기 → 임박');
        Assert.isTrue(res.heldAssetText.contains('만기 임박'));
        Assert.areEqual(OpportunityFollowupContextAction.MAX_FINANCIALS, res.financialText.split('\n').size());
        Assert.isTrue(res.financialText.startsWith('- 2025'), '최신 연도 먼저: ' + res.financialText);
        Assert.isTrue(res.signalText.contains('[수주]'));
        Assert.isTrue(res.message.contains('만기 임박 있음'));
    }

    @IsTest
    static void shouldReturnInaccessibleForMissingOpp() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        delete opp;
        OpportunityFollowupContextAction.Response res = run(opp.Id);
        Assert.isFalse(res.isAccessible);
        Assert.isTrue(res.message.contains('찾지 못했거나'));
    }

    @IsTest
    static void shouldHandleNullAndEmpty() {
        Assert.isFalse(run(null).isAccessible);
        Assert.areEqual(0, OpportunityFollowupContextAction.gather(null).size());
    }
}