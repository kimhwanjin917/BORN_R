@IsTest
private class MeetingNoteAgentRecommenderTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(Name = '대성정밀(주)', Industry = '제조업', Business_Registration_Number__c = '1234567890');
        insert acc;
        insert new Opportunity(Name = '대성정밀 RP', AccountId = acc.Id, StageName = '탐색', CloseDate = Date.today().addDays(30));
    }

    private static Meeting_Note__c newNote(String raw) {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        return new Meeting_Note__c(Opportunity__c = opp.Id, Raw_Content__c = raw);
    }

    private static void stub(String text, String sessionId) {
        AgentFlowClient.Reply r = new AgentFlowClient.Reply();
        r.text = text;
        r.sessionId = sessionId;
        AgentFlowClient.stubReply = r;
    }

    @IsTest
    static void shouldWriteAgentReplyToNoteAndOpportunity() {
        stub('추천 1순위 RP\n근거: 현금성자산', 'sess-1');
        Meeting_Note__c note = newNote('고객 연락처 010-1234-5678, RP 만족. 규모 확대 검토');

        Test.startTest();
        insert note; // MeetingNoteTrigger(정제) → MeetingNoteRecommendTrigger(큐) → Queueable 실행
        Test.stopTest();

        note = [SELECT Product_Recommendation__c, Agent_Session_Id__c, Opportunity__c, Sanitized_Content__c FROM Meeting_Note__c WHERE Id = :note.Id];
        Assert.isNotNull(note.Sanitized_Content__c, '정제본이 먼저 생겨야 함');
        Assert.areEqual('추천 1순위 RP\n근거: 현금성자산', note.Product_Recommendation__c);
        Assert.areEqual('sess-1', note.Agent_Session_Id__c, '추가 질문용 세션 Id 저장');
        Opportunity opp = [SELECT Last_Recommendation__c FROM Opportunity WHERE Id = :note.Opportunity__c];
        Assert.areEqual('추천 1순위 RP\n근거: 현금성자산', opp.Last_Recommendation__c);
    }

    @IsTest
    static void shouldRecordFailureOnNoteOnly() {
        AgentFlowClient.stubError = '에이전트 호출 실패';
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
        stub('x', 's');
        Meeting_Note__c note = newNote('메모');
        insert note;

        Test.startTest();
        Integer before = Limits.getQueueableJobs();
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

    @IsTest
    static void followupShouldContinueSessionAndAppend() {
        stub('추천 1순위 RP', 'sess-1');
        Meeting_Note__c note = newNote('메모');
        Test.startTest();
        insert note;
        Test.stopTest();

        stub('최소 1억원입니다.', 'sess-1');
        MeetingNoteFollowupController.FollowupResult r = MeetingNoteFollowupController.askFollowup(note.Id, '최소 가입 금액은?');
        Assert.areEqual('최소 1억원입니다.', r.answer);
        Assert.isTrue(r.recommendation.contains('[추가 질문] 최소 가입 금액은?'));
        note = [SELECT Product_Recommendation__c FROM Meeting_Note__c WHERE Id = :note.Id];
        Assert.isTrue(note.Product_Recommendation__c.contains('[답변] 최소 1억원입니다.'));
    }

    @IsTest
    static void followupShouldMaskPiiAndCarryOpportunityContext() {
        stub('추천 1순위 RP', 'sess-1');
        Meeting_Note__c note = newNote('메모');
        Test.startTest();
        insert note;
        Test.stopTest();

        stub('연락드리겠습니다.', 'sess-1');
        AgentFlowClient.capturedMessages.clear();
        MeetingNoteFollowupController.FollowupResult r =
            MeetingNoteFollowupController.askFollowup(note.Id, '김민준 부장 010-1234-5678 에게 뭐라고 안내하지?');
        String sent = AgentFlowClient.capturedMessages[0];
        Assert.isFalse(sent.contains('010-1234-5678'), '전화번호는 가려서 보낸다: ' + sent);
        Assert.isTrue(sent.contains(String.valueOf(note.Opportunity__c)), '기회 Id 를 매번 붙인다');
        Assert.isTrue(sent.contains('대성정밀'), '고객사(기업명)는 허용');
        Assert.isFalse(r.recommendation.contains('010-1234-5678'), '기록에도 마스킹본만 남긴다');
    }

    @IsTest
    static void followupShouldRejectBeforeRecommendation() {
        Meeting_Note__c note = newNote('메모');
        insert note; // 큐 미실행 → 추천 없음
        try {
            MeetingNoteFollowupController.askFollowup(note.Id, '질문');
            Assert.fail('추천 전에는 거부');
        } catch (AuraHandledException e) {
            Assert.isTrue(true);
        }
    }

    @IsTest
    static void extractMessageShouldUnwrapEnvelope() {
        String raw = '{"type":"InformMessage","value":{"result":[],"message":"본문입니다","isContentSafe":true}}';
        Assert.areEqual('본문입니다', AgentFlowClient.extractMessage(raw));
        Assert.areEqual('그냥 텍스트', AgentFlowClient.extractMessage(' 그냥 텍스트 '));
        Assert.isNull(AgentFlowClient.extractMessage(''));
    }
}