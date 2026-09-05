/**
 * OpportunityDealChannelService 테스트. Slack 호출은 전부 HttpCalloutMock. 테스트 데이터는 @TestSetup 에서 직접 생성.
 */
@IsTest
private class OpportunityDealChannelServiceTest {

    private static final String REP_EMAIL = 'rep.tester@example.com';

    @TestSetup
    static void setup() {
        User rep;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
            rep = new User(FirstName = '상품', LastName = '담당', Alias = 'reptst', Email = REP_EMAIL,
                Username = 'deal.channel.rep@newborn.example.com', ProfileId = p.Id,
                TimeZoneSidKey = 'Asia/Seoul', LocaleSidKey = 'ko_KR', EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'ko');
            insert rep;
        }
        Account acc = new Account(Name = '근본물산', Business_Registration_Number__c = '1234567890');
        insert acc;
        Product2 prod = new Product2(Name = 'RP (환매조건부채권)', Family = 'RP', IsActive = true, Default_Fee_Rate__c = 0.15, Product_Team_Rep__c = rep.Id);
        insert prod;
        insert new Opportunity(Name = '근본물산 - RP', AccountId = acc.Id, StageName = 'Prospecting', CloseDate = Date.today().addMonths(1),
            Amount = 5000000000L, Primary_Product__c = prod.Id, Fee_Rate__c = 0.12, RP_Maturity_Date__c = Date.today().addYears(1));
    }

    private static Opportunity getOpp() {
        return [SELECT Id, Slack_Channel_ID__c, Slack_Channel_Link__c FROM Opportunity LIMIT 1];
    }

    private static Opportunity getOppFull() {
        return [SELECT Id, Name, Amount, Fee_Rate__c, RP_Maturity_Date__c, RP_Yield__c, Pending_Yield__c, Coupon_Rate__c, Issuer_Name__c, Meeting_Log__c,
                       Account.Name, Account.Industry, Account.AnnualRevenue, Account.Relationship_Grade__c, Account.Priority_Rationale_Summary__c,
                       Owner.Name, Primary_Product__r.Name, Primary_Product__r.Family, Primary_Product__r.Default_Fee_Rate__c
                FROM Opportunity LIMIT 1];
    }

    /** 상품군을 채권으로 바꿔 회사채 딜을 만든다(입력칸 3개 경로). */
    private static void makeBond() {
        Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
        prod.Name = '회사채';
        prod.Family = '채권';
        update prod;
    }

    /** Slack 호출 경로를 기록하고 정상 응답을 돌려주는 mock. failPath 는 ok:false 로 응답. */
    private class SlackMock implements HttpCalloutMock {
        public List<String> paths = new List<String>();
        public List<String> postMessageBodies = new List<String>();
        public String failPath;
        public Boolean channelArchived = false; // conversations.info 응답의 아카이브 여부
        public HttpResponse respond(HttpRequest req) {
            String path = req.getEndpoint().substringAfter('callout:Slack').substringBefore('?');
            paths.add(path);
            if (path == '/chat.postMessage') {
                postMessageBodies.add(req.getBody());
            }
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            if (path == failPath) {
                res.setBody('{"ok":false,"error":"boom"}');
            } else if (path == '/conversations.info') {
                res.setBody('{"ok":true,"channel":{"is_archived":' + (channelArchived ? 'true' : 'false') + '}}');
            } else if (path == '/conversations.create') {
                res.setBody('{"ok":true,"channel":{"id":"C0DEAL1","name":"근본물산-rp"}}');
            } else if (path == '/users.lookupByEmail') {
                Boolean isRep = req.getEndpoint().contains(EncodingUtil.urlEncode(REP_EMAIL, 'UTF-8'));
                res.setBody(isRep ? '{"ok":true,"user":{"id":"UREP"}}' : '{"ok":false,"error":"users_not_found"}');
            } else if (path == '/chat.postMessage') {
                res.setBody('{"ok":true,"ts":"1700000000.000100"}');
            } else {
                res.setBody('{"ok":true}');
            }
            return res;
        }
    }

    @IsTest
    static void createChannels_createsInvitesPostsAndSavesFields() {
        SlackMock mock = new SlackMock();
        Test.setMock(HttpCalloutMock.class, mock);
        Opportunity opp = getOpp();

        Test.startTest();
        List<Id> done = OpportunityDealChannelService.createChannels(new List<Id>{ opp.Id });
        Test.stopTest();

        Assert.areEqual(1, done.size());
        Opportunity after = getOpp();
        Assert.areEqual('C0DEAL1', after.Slack_Channel_ID__c);
        Assert.isTrue(after.Slack_Channel_Link__c.endsWith('/archives/C0DEAL1'));
        Assert.areEqual('/conversations.create', mock.paths[0]);
        Assert.isTrue(mock.paths.contains('/users.lookupByEmail'), '담당자 이메일 조회');
        Assert.isTrue(mock.paths.contains('/conversations.invite'));
        Assert.isTrue(mock.paths.contains('/conversations.setPurpose'), '채널 설명에 레코드 링크');
        Integer posts = 0;
        for (String p : mock.paths) {
            if (p == '/chat.postMessage') {
                posts++;
            }
        }
        Assert.areEqual(2, posts, '미팅 요약 1건 + 조건 카드 1건');
    }

    @IsTest
    static void createChannels_postsMeetingSummaryIntoChannel() {
        OpportunityDealChannelService.summaryForTest =
            '핵심 니즈: 여유자금 단기 운용 희망\n추천 상품: RP 30일물\n다음 단계: 조건 확정 후 제안';
        SlackMock mock = new SlackMock();
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        OpportunityDealChannelService.createChannels(new List<Id>{ getOpp().Id });
        Test.stopTest();

        String summaryMsg = mock.postMessageBodies[0];
        Assert.isTrue(summaryMsg.contains('미팅 요약'), '요약 메시지 헤더');
        Assert.isTrue(summaryMsg.contains('핵심 니즈') && summaryMsg.contains('RP 30일물'), 'LLM 3줄 요약이 실린다: ' + summaryMsg);
        String cardMsg = mock.postMessageBodies[1];
        Assert.isFalse(cardMsg.contains('미팅 핵심'), '카드에 미팅 핵심 블록 없음(요약과 중복 제거)');
    }

    @IsTest
    static void createChannels_noMeetingNote_postsFallbackSummary() {
        SlackMock mock = new SlackMock();
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        OpportunityDealChannelService.createChannels(new List<Id>{ getOpp().Id });
        Test.stopTest();

        Assert.isTrue(mock.postMessageBodies[0].contains('생성하지 못했습니다'), '노트 없으면 폴백 문구');
    }

    @IsTest
    static void createChannels_skipsWhenChannelAliveExists() {
        Opportunity opp = getOpp();
        opp.Slack_Channel_ID__c = 'C0EXIST';
        update opp;
        SlackMock mock = new SlackMock();
        mock.channelArchived = false; // 살아있는 채널
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        List<Id> done = OpportunityDealChannelService.createChannels(new List<Id>{ opp.Id });
        Test.stopTest();

        Assert.areEqual(0, done.size(), '살아있는 채널이면 재생성 안 함');
        Assert.isTrue(mock.paths.contains('/conversations.info'), '채널 생존 확인');
        Assert.isFalse(mock.paths.contains('/conversations.create'), '새 채널 안 만든다');
        Assert.isFalse(mock.paths.contains('/conversations.invite'), '초대 반복 안 함');
        Assert.areEqual('C0EXIST', getOpp().Slack_Channel_ID__c, '기존 채널 유지');
        // 2026-08-30: 살아있는 채널엔 조건 카드만 재게시
        Assert.areEqual(1, mock.postMessageBodies.size(), '조건 카드 1장만 재게시(요약 없음)');
        Assert.isTrue(mock.postMessageBodies[0].contains('C0EXIST'), '기존 채널로 게시');
        Assert.isTrue(mock.postMessageBodies[0].contains('재전송'), '재전송 표시');
        Assert.isTrue(OpportunityDealChannelService.resentIds.contains(opp.Id), '재게시 기록');
    }

    @IsTest
    static void createChannels_recreatesWhenChannelArchived() {
        Opportunity opp = getOpp();
        opp.Slack_Channel_ID__c = 'C0OLD';
        update opp;
        SlackMock mock = new SlackMock();
        mock.channelArchived = true; // 아카이브된 채널
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        List<Id> done = OpportunityDealChannelService.createChannels(new List<Id>{ opp.Id });
        Test.stopTest();

        Assert.areEqual(1, done.size(), '아카이브면 새로 만든다');
        Assert.isTrue(mock.paths.contains('/conversations.create'), '새 채널 생성');
        Assert.areEqual('C0DEAL1', getOpp().Slack_Channel_ID__c, '새 채널 ID 로 교체');
    }

    @IsTest
    static void createChannels_repNotFound_stillCreatesChannel() {
        Product2 prod = [SELECT Id FROM Product2 LIMIT 1];
        prod.Product_Team_Rep__c = null;
        update prod;
        SlackMock mock = new SlackMock();
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        OpportunityDealChannelService.createChannels(new List<Id>{ getOpp().Id });
        Test.stopTest();

        Assert.areEqual('C0DEAL1', getOpp().Slack_Channel_ID__c, '담당자 없어도 채널은 만든다');
    }

    @IsTest
    static void createChannels_slackFailure_doesNotSaveChannel() {
        SlackMock mock = new SlackMock();
        mock.failPath = '/conversations.create';
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        List<Id> done = OpportunityDealChannelService.createChannels(new List<Id>{ getOpp().Id });
        Test.stopTest();

        Assert.areEqual(0, done.size());
        Assert.isNull(getOpp().Slack_Channel_ID__c);
    }

    private static Integer countInputs(List<Object> blocks) {
        Integer inputs = 0;
        for (Object b : blocks) {
            if (((Map<String, Object>) b).get('type') == 'input') {
                inputs++;
            }
        }
        return inputs;
    }

    @IsTest
    static void buildTermCardBlocks_hasFeeConditionNoInputs() {
        List<Object> blocks = OpportunityDealChannelService.buildTermCardBlocks(getOppFull());
        Assert.areEqual(0, countInputs(blocks), '상품팀은 Slack 만 보므로 입력칸을 두지 않는다');
        String json = JSON.serialize(blocks);
        Assert.isTrue(json.contains('수수료 조건'), '수수료 조건 섹션');
        Assert.isTrue(json.contains('거래 금액') && json.contains('제안 수익률') && json.contains('기간'), '수수료 조건 항목');
        Assert.isTrue(json.contains('증권사 수익'), '계산 결과 포함');
        Assert.isFalse(json.contains(OpportunityDealChannelService.ACTION_REPLY), '회신 제출 버튼 제거');
    }

    @IsTest
    static void buildTermCardBlocks_bond_showsGroupLabel() {
        makeBond();
        List<Object> blocks = OpportunityDealChannelService.buildTermCardBlocks(getOppFull());
        Assert.areEqual(0, countInputs(blocks), '입력칸 없음');
        Assert.isTrue(JSON.serialize(blocks).contains('회사채'), '헤더에 상품군');
    }

    @IsTest
    static void buildRepliedCardBlocks_showsAppliedYieldAndFee() {
        Opportunity opp = getOppFull();
        opp.RP_Yield__c = 3.8;
        opp.Fee_Rate__c = 0.1;
        List<Object> blocks = OpportunityDealChannelService.buildRepliedCardBlocks(opp, '이주연', 'https://example.my.salesforce.com');
        String json = JSON.serialize(blocks);
        Assert.isFalse(json.contains('"input"'), '회신 후엔 입력칸 없음');
        Assert.isTrue(json.contains('적용 약정수익률') && json.contains('적용 수수료율'), '적용 수익률·수수료율 표시');
        Assert.isTrue(json.contains('3.8') && json.contains('이주연'));
        Assert.isTrue(json.contains(String.valueOf(opp.Id)), '기회 링크');
    }

    @IsTest
    static void deriveChannelName_companyAndProductWithoutParens() {
        Opportunity opp = getOppFull();
        Assert.areEqual('근본물산-rp', OpportunityDealChannelService.deriveChannelName(opp));
    }

    @IsTest
    static void enqueue_onlyWhenMeetingLogChangedAndNoChannel() {
        Opportunity opp = getOpp();
        Opportunity oldOpp = new Opportunity(Id = opp.Id, Meeting_Log__c = null);
        Opportunity newOpp = new Opportunity(Id = opp.Id, Meeting_Log__c = '미팅함', Slack_Channel_ID__c = null);
        Opportunity withChannel = new Opportunity(Id = opp.Id, Meeting_Log__c = '미팅함', Slack_Channel_ID__c = 'C0X');

        Test.startTest();
        OpportunityDealChannelService.enqueueForOpportunities(new List<Opportunity>{ withChannel }, new Map<Id, Opportunity>{ opp.Id => oldOpp });
        Assert.areEqual(0, Limits.getQueueableJobs(), '채널 있으면 큐 안 넣음');
        OpportunityDealChannelService.enqueueForOpportunities(new List<Opportunity>{ newOpp }, new Map<Id, Opportunity>{ opp.Id => oldOpp });
        Integer jobs = Limits.getQueueableJobs();
        Test.stopTest();

        Assert.areEqual(1, jobs);
    }

    @IsTest
    static void buildTermCardBlocks_withCase_showsCaseInfoAndApprovalButton() {
        Opportunity opp = getOppFull();
        Case c = new Case(
            OwnerId = UserInfo.getUserId(),
            Opportunity__c = opp.Id,
            Subject = '판매 승인 요청',
            Agreed_Yield_Rate__c = 4.5,
            Description = '금리 상한 초과'
        );
        insert c;
        Case caseWithOwner = [SELECT Id, Opportunity__c, Owner.Name, Agreed_Yield_Rate__c, Contract_Term_Months__c, Description FROM Case WHERE Id = :c.Id];

        List<Object> blocks = OpportunityDealChannelService.buildTermCardBlocks(opp, caseWithOwner);
        String json = JSON.serialize(blocks);
        Assert.isTrue(json.contains('판매 승인 요청'), 'Case 정보 섹션');
        Assert.isTrue(json.contains('금리 상한 초과'), 'Case 사유 표시');
        Assert.isTrue(json.contains(OpportunityDealChannelService.ACTION_APPROVAL_APPROVE), '승인 버튼');
        Assert.isTrue(json.contains('"primary"'), '승인 버튼 스타일');
        Assert.isTrue(json.contains(OpportunityDealChannelService.ACTION_APPROVAL_REJECT), '반려 버튼');
        Assert.isTrue(json.contains('"danger"'), '반려 버튼 스타일');
        Assert.isTrue(json.contains(OpportunityDealChannelService.ACTION_APPROVAL_MANAGER), '매니저 결재 버튼');
    }

    @IsTest
    static void buildTermCardBlocks_withoutCase_stillShowsApprovalButton() {
        Opportunity opp = getOppFull(); // Pending_Yield__c 없음, Case 없음, 상한 이하
        List<Object> blocks = OpportunityDealChannelService.buildTermCardBlocks(opp, null);
        String json = JSON.serialize(blocks);
        Assert.isTrue(json.contains(OpportunityDealChannelService.ACTION_APPROVAL_APPROVE), 'Case 없어도 승인 버튼');
        Assert.isTrue(json.contains(OpportunityDealChannelService.ACTION_APPROVAL_REJECT), '반려 버튼');
        Assert.isTrue(json.contains(OpportunityDealChannelService.ACTION_APPROVAL_MANAGER), '매니저 결재 버튼');
        Assert.isFalse(json.contains('판매 승인 요청'), 'Case 없으니 Case 정보 섹션은 없음');
    }
}