@isTest
private class DealApprovalHandlerTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(Name = '근본물산', Business_Registration_Number__c = '1112233445');
        insert acc;
        Product2 prod = new Product2(Name = 'RP', Family = 'RP', IsActive = true, Default_Fee_Rate__c = 0.15);
        insert prod;
        Opportunity opp = new Opportunity(Name = '근본물산 - RP', AccountId = acc.Id, StageName = 'Prospecting',
            CloseDate = Date.today().addMonths(1), Amount = 5000000000L, Primary_Product__c = prod.Id,
            Fee_Rate__c = 0.12, RP_Maturity_Date__c = Date.today().addYears(1),
            Pending_Yield__c = 4.5, RP_Yield__c = 3.8);
        insert opp;
        insert new Case(Opportunity__c = opp.Id, AccountId = acc.Id, OwnerId = UserInfo.getUserId(),
            Subject = '판매 승인 요청', Agreed_Yield_Rate__c = 4.5);
    }

    private static Opportunity getOpp() {
        return [SELECT Id, Pending_Yield__c, RP_Yield__c FROM Opportunity LIMIT 1];
    }

    private static Case getCase() {
        return [SELECT Id, Approval_Status__c, Agreed_Yield_Rate__c FROM Case LIMIT 1];
    }

    @isTest
    static void approve_withPendingYield_promotesToRpYield() {
        Opportunity opp = getOpp();
        Assert.areEqual(4.5, opp.Pending_Yield__c, 'Pending 초기값');

        Map<String, Object> payload = new Map<String, Object>{
            'oppId' => String.valueOf(opp.Id),
            'channelId' => 'C0TEST',
            'ts' => '1700000000.000100'
        };

        Test.startTest();
        DealApprovalHandler.approveFromEvent(payload);
        Test.stopTest();

        Opportunity after = getOpp();
        Assert.areEqual(4.5, after.RP_Yield__c, 'Pending_Yield__c 가 RP_Yield__c 로 승격');
        Assert.isNull(after.Pending_Yield__c, 'Pending_Yield__c 는 비워짐');
        Assert.areEqual('승인', getCase().Approval_Status__c, 'Case 승인 상태');
    }

    @isTest
    static void approve_noPendingYield_usesCaseAgreedYieldRate() {
        Opportunity opp = getOpp();
        opp.Pending_Yield__c = null;
        opp.RP_Yield__c = 3.0;
        update opp;

        Map<String, Object> payload = new Map<String, Object>{
            'oppId' => String.valueOf(opp.Id),
            'channelId' => 'C0TEST',
            'ts' => '1700000000.000100'
        };

        Test.startTest();
        DealApprovalHandler.approveFromEvent(payload);
        Test.stopTest();

        Opportunity after = getOpp();
        Assert.areEqual(4.5, after.RP_Yield__c, 'Case.Agreed_Yield_Rate__c 가 RP_Yield__c 로 승격');
        Assert.isNull(after.Pending_Yield__c);
    }

    @isTest
    static void approve_noPendingAndNoCaseYield_doesNotChangeRpYield() {
        Opportunity opp = getOpp();
        opp.Pending_Yield__c = null;
        opp.RP_Yield__c = 3.0;
        update opp;
        Case c = getCase();
        c.Agreed_Yield_Rate__c = null;
        update c;

        Map<String, Object> payload = new Map<String, Object>{
            'oppId' => String.valueOf(opp.Id),
            'channelId' => 'C0TEST',
            'ts' => '1700000000.000100'
        };

        Test.startTest();
        DealApprovalHandler.approveFromEvent(payload);
        Test.stopTest();

        Opportunity after = getOpp();
        Assert.areEqual(3.0, after.RP_Yield__c, '수익률 변경 없음');
        Assert.areEqual('승인', getCase().Approval_Status__c, 'Case 승인은 됨');
    }

    @isTest
    static void handle_parsesSlackPayloadAndApproves() {
        Opportunity opp = getOpp();
        String payloadJson = '{"type":"block_actions","user":{"id":"U0TEST","name":"테스터"},'
            + '"channel":{"id":"C0DEAL1"},"message":{"ts":"1700000000.000100","blocks":[]},'
            + '"actions":[{"action_id":"deal_approval_approve","value":"' + opp.Id + '"}]}';
        Map<String, Object> p = (Map<String, Object>) JSON.deserializeUntyped(payloadJson);

        DealApprovalHandler.forceEventPath = true;
        Test.startTest();
        DealApprovalHandler.handle(p);
        Test.stopTest();
    }

    @isTest
    static void approvedBlocksFromOriginal_removesActionsAndAddsResult() {
        List<Object> original = new List<Object>{
            new Map<String, Object>{ 'type' => 'header', 'text' => new Map<String, Object>{ 'type' => 'plain_text', 'text' => '헤더' } },
            new Map<String, Object>{ 'type' => 'section', 'text' => new Map<String, Object>{ 'type' => 'mrkdwn', 'text' => '수수료' } },
            new Map<String, Object>{ 'type' => 'actions', 'elements' => new List<Object>() }
        };
        Account acc = new Account(Name = '테스트', Business_Registration_Number__c = '9999999999');
        insert acc;
        Opportunity opp = new Opportunity(Name = '테스트', AccountId = acc.Id, StageName = 'Prospecting', CloseDate = Date.today().addMonths(1));
        insert opp;

        List<Object> result = DealApprovalHandler.approvedBlocksFromOriginal(original, opp.Id, '테스터');
        String json = JSON.serialize(result);
        Assert.isTrue(json.contains('상품팀 검토 완료'), '검토 완료 문구 표시');
        Assert.isTrue(json.contains('조건이 승인되었습니다'), '승인 결과 문구 표시');
        Assert.isFalse(json.contains('테스터'), '승인자 슬랙ID/이름은 문구에 노출되지 않아야 함');
    }
}