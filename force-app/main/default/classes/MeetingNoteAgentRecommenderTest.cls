@IsTest
private class MeetingNoteAgentRecommenderTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(Name = '대성정밀(주)', Industry = '제조업', Business_Registration_Number__c = '1234567890');
        insert acc;
        insert new Opportunity(Name = '대성정밀 RP', AccountId = acc.Id, StageName = '미팅', CloseDate = Date.today().addDays(30));
    }

    private static Meeting_Note__c newNote(String raw) {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        return new Meeting_Note__c(Opportunity__c = opp.Id, Raw_Content__c = raw);
    }

    @IsTest
    static void shouldWriteAgentReplyToNoteAndOpportunity() {
        Test.setMock(HttpCalloutMock.class, new AgentApiClientTest.AgentApiMock());
        AgentApiClient.agentDeveloperName = anyBotName();
        Meeting_Note__c note = newNote('고객 연락처 010-1234-5678, RP 만족. 규모 확대 검토');

        Test.startTest();
        insert note; // MeetingNoteTrigger(정제) → MeetingNoteRecommendTrigger(큐) → Queueable 실행
        Test.stopTest();

        note = [SELECT Product_Recommendation__c, Opportunity__c, Sanitized_Content__c FROM Meeting_Note__c WHERE Id = :note.Id];
        Assert.isNotNull(note.Sanitized_Content__c, '정제본이 먼저 생겨야 함');
        Assert.areEqual('추천 1순위 RP\n근거: 현금성자산', note.Product_Recommendation__c);
        Opportunity opp = [SELECT Last_Recommendation__c FROM Opportunity WHERE Id = :note.Opportunity__c];
        Assert.areEqual('추천 1순위 RP\n근거: 현금성자산', opp.Last_Recommendation__c);
    }

    @IsTest
    static void shouldRecordFailureOnNoteOnly() {
        AgentApiClientTest.AgentApiMock mock = new AgentApiClientTest.AgentApiMock();
        mock.messageStatus = 500;
        Test.setMock(HttpCalloutMock.class, mock);
        AgentApiClient.agentDeveloperName = anyBotName();
        Meeting_Note__c note = newNote('메모');

        Test.startTest();
        insert note;
        Test.stopTest();

        note = [SELECT Product_Recommendation__c, Opportunity__c FROM Meeting_Note__c WHERE Id = :note.Id];
        Assert.isTrue(note.Product_Recommendation__c.startsWith(MeetingNoteAgentRecommender.FAILURE_PREFIX), note.Product_Recommendation__c);
        Assert.isNull([SELECT Last_Recommendation__c FROM Opportunity WHERE Id = :note.Opportunity__c].Last_Recommendation__c, '실패는 Opp 최신값을 덮지 않음');
    }

    @IsTest
    static void shouldNotEnqueueWhenSanitizedUnchanged() {
        Test.setMock(HttpCalloutMock.class, new AgentApiClientTest.AgentApiMock());
        AgentApiClient.agentDeveloperName = anyBotName();
        Meeting_Note__c note = newNote('메모');
        insert note; // 첫 큐는 startTest 밖이라 실행되지 않음(테스트 컨텍스트에서 동기 실행 안 됨)

        Test.startTest();
        Integer before = Limits.getQueueableJobs();
        // 정제본과 무관한 필드만 바꿈 → 재큐잉 없어야 함
        update new Meeting_Note__c(Id = note.Id, Product_Recommendation__c = '수동 메모');
        Integer after = Limits.getQueueableJobs();
        Test.stopTest();

        Assert.areEqual(before, after, '정제본이 안 바뀌면 큐에 넣지 않음');
    }

    @IsTest
    static void shouldSkipNotesWithoutOpportunityOrSanitized() {
        List<Meeting_Note__c> notes = new List<Meeting_Note__c>{
            new Meeting_Note__c(Raw_Content__c = '기회 없음'),
            new Meeting_Note__c(Opportunity__c = [SELECT Id FROM Opportunity LIMIT 1].Id, Sanitized_Content__c = null)
        };
        Test.startTest();
        Integer before = Limits.getQueueableJobs();
        MeetingNoteAgentRecommender.enqueueForNotes(notes, null);
        Assert.areEqual(before, Limits.getQueueableJobs());
        Test.stopTest();
    }

    @IsTest
    static void utteranceShouldCarryIdsNotContent() {
        Meeting_Note__c note = newNote('민감한 원문');
        insert note;
        note = [SELECT Id, Opportunity__c, Opportunity__r.Name, Opportunity__r.Account.Name FROM Meeting_Note__c WHERE Id = :note.Id];
        String u = MeetingNoteAgentRecommender.buildUtterance(note);
        Assert.isTrue(u.contains(String.valueOf(note.Opportunity__c)));
        Assert.isTrue(u.contains(String.valueOf(note.Id)));
        Assert.isFalse(u.contains('민감한 원문'), '원문은 발화에 넣지 않는다');
    }

    private static String anyBotName() {
        List<BotDefinition> bots = [SELECT DeveloperName FROM BotDefinition LIMIT 1];
        return bots.isEmpty() ? 'RM_Assistant' : bots[0].DeveloperName;
    }
}