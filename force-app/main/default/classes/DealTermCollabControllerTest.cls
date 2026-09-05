@IsTest
private class DealTermCollabControllerTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(Name = '근본물산', Business_Registration_Number__c = '1234567890');
        insert acc;
        insert new Contact(AccountId = acc.Id, LastName = '김담당', name_new__c = '김담당', Email = 'kim@example.com');
        Product2 prod = new Product2(Name = 'RP (환매조건부채권)', Family = 'RP', IsActive = true, Default_Fee_Rate__c = 0.15);
        insert prod;
        insert new Opportunity(Name = '근본물산 - RP', AccountId = acc.Id, StageName = 'Prospecting', CloseDate = Date.today().addMonths(1),
            Amount = 5000000000L, Primary_Product__c = prod.Id, Fee_Rate__c = 0.12, RP_Maturity_Date__c = Date.today().addYears(1));
    }

    private class Mock implements HttpCalloutMock {
        public List<String> paths = new List<String>();
        public HttpResponse respond(HttpRequest req) {
            String ep = req.getEndpoint();
            paths.add(ep);
            HttpResponse r = new HttpResponse();
            r.setStatusCode(200);
            if (ep.contains('getUploadURLExternal')) {
                r.setBody('{"ok":true,"upload_url":"https://files.slack.com/upload/x","file_id":"F1"}');
            } else if (ep.startsWith('https://files.slack.com')) {
                r.setBody('OK');
            } else {
                r.setBody('{"ok":true,"ts":"1.1"}');
            }
            return r;
        }
    }

    private static Opportunity getOpp() {
        return [SELECT Id FROM Opportunity LIMIT 1];
    }

    @IsTest
    static void getState_waiting_whenNoChannel() {
        DealTermCollabController.State s = DealTermCollabController.getState(getOpp().Id);
        Assert.areEqual('WAITING', s.stage);
        Assert.areEqual(0.12, s.feeRate);
        Assert.areEqual(0.15, s.baseFeeRate);
    }

    @IsTest
    static void getState_reviewing_thenReplied_thenDone() {
        Opportunity opp = getOpp();
        opp.Slack_Channel_ID__c = 'C0DEAL1';
        opp.Slack_Channel_Link__c = 'https://x/archives/C0DEAL1';
        update opp;
        Assert.areEqual('REVIEWING', DealTermCollabController.getState(opp.Id).stage);

        opp.RP_Yield__c = 3.8;
        opp.Coupon_Rate__c = 4.0;
        opp.Issuer_Name__c = '근본캐피탈';
        opp.Product_Team_Reply_At__c = Datetime.now();
        opp.Product_Team_Reply_By__c = '이주연';
        update opp;
        DealTermCollabController.State s = DealTermCollabController.getState(opp.Id);
        Assert.areEqual('REPLIED', s.stage);
        Assert.areEqual('이주연', s.replyBy);
        Assert.areEqual(3.8, s.rpYield);

        opp.Approval_Status__c = OpportunityReviewService.APPROVED;
        update opp;
        Assert.areEqual('DONE', DealTermCollabController.getState(opp.Id).stage);
    }

    @IsTest
    static void createContract_makesContractWithFeeRateAndSharesPdf() {
        Opportunity opp = getOpp();
        opp.Slack_Channel_ID__c = 'C0DEAL1';
        opp.RP_Yield__c = 3.8;
        opp.Coupon_Rate__c = 4.0;
        opp.Issuer_Name__c = '근본캐피탈';
        opp.Product_Team_Reply_At__c = Datetime.now();
        update opp;
        Mock m = new Mock();
        Test.setMock(HttpCalloutMock.class, m);

        Test.startTest();
        DealTermCollabController.State s = DealTermCollabController.createContract(opp.Id);
        Test.stopTest();

        Assert.areEqual('DONE', s.stage);
        Assert.isNotNull(s.contractId);
        Assert.isNotNull(s.contractDocumentId, 'PDF 첨부');
        Contract c = [SELECT Fee_Rate__c, Status FROM Contract WHERE Id = :s.contractId];
        Assert.areEqual(0.12, c.Fee_Rate__c, '확정 수수료가 상품 기본 요율(0.15)보다 우선');
        Assert.areEqual('Draft', c.Status);
        Boolean shared = false;
        for (String p : m.paths) {
            if (p.contains('completeUploadExternal')) {
                shared = true;
            }
        }
        Assert.isTrue(shared, 'PDF 를 딜 채널에 공유: ' + m.paths);
        Assert.isTrue(s.message.contains('생성 완료'), s.message);
    }

    /** Salesforce 화면 회신: REVIEWING → REPLIED, 필드 갱신, Slack 에 회신 완료 카드 게시. */
    @IsTest
    static void submitReply_inReviewing_movesToRepliedAndPostsCard() {
        Opportunity opp = getOpp();
        update new Opportunity(Id = opp.Id, Slack_Channel_ID__c = 'C0DEAL1', Slack_Channel_Link__c = 'https://x.slack.com/archives/C0DEAL1');
        Mock m = new Mock();
        Test.setMock(HttpCalloutMock.class, m);

        Test.startTest();
        DealTermCollabController.State s = DealTermCollabController.submitReply(opp.Id, 3.8, 0.2, 4.0, '근본캐피탈');
        Test.stopTest();

        Assert.areEqual('REPLIED', s.stage);
        Assert.areEqual(3.8, s.rpYield);
        Assert.areEqual(0.2, s.feeRate, '적용 수수료율 → Fee_Rate__c');
        Assert.areEqual(4.0, s.couponRate);
        Assert.areEqual('근본캐피탈', s.issuerName);
        Assert.areEqual(UserInfo.getName(), s.replyBy, '회신자 = 현재 사용자');
        Assert.isNotNull(s.replyAt);
        Assert.isNotNull(s.message);
        Boolean posted = false;
        for (String p : m.paths) { if (p.contains('chat.postMessage')) posted = true; }
        Assert.isTrue(posted, 'Slack 채널에 회신 완료 카드 게시: ' + m.paths);
    }

    @IsTest
    static void submitReply_rejectsOutsideReviewing() {
        Opportunity opp = getOpp(); // WAITING (채널 없음)
        Test.setMock(HttpCalloutMock.class, new Mock());
        try {
            DealTermCollabController.submitReply(opp.Id, 3.8, null, null, null);
            Assert.fail('REVIEWING 아니면 거부');
        } catch (AuraHandledException e) {
            Assert.isTrue(true);
        }
    }

    @IsTest
    static void createContract_rejectsBeforeReply() {
        try {
            DealTermCollabController.createContract(getOpp().Id);
            Assert.fail('회신 전에는 예외');
        } catch (AuraHandledException e) {
            Assert.isTrue(true);
        }
    }

    @IsTest
    static void createContract_isIdempotentWhenDone() {
        Opportunity opp = getOpp();
        opp.Approval_Status__c = OpportunityReviewService.APPROVED;
        update opp;
        DealTermCollabController.State s = DealTermCollabController.createContract(opp.Id);
        Assert.areEqual('DONE', s.stage);
        Assert.areEqual(0, [SELECT COUNT() FROM Contract WHERE SourceOpportunityId = :opp.Id], '이미 완료면 다시 만들지 않음');
    }

    private class ChannelMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            String ep = req.getEndpoint();
            HttpResponse r = new HttpResponse();
            r.setStatusCode(200);
            r.setBody(ep.contains('conversations.create') ? '{"ok":true,"channel":{"id":"C0NEW","name":"근본물산-rp"}}'
                : ep.contains('lookupByEmail') ? '{"ok":true,"user":{"id":"U0T"}}' : '{"ok":true,"ts":"1.1"}');
            return r;
        }
    }

    @IsTest
    static void sendToProductTeam_createsChannelAndMovesToReviewing() {
        Opportunity opp = getOpp();
        Test.setMock(HttpCalloutMock.class, new ChannelMock());
        Test.startTest();
        DealTermCollabController.State s = DealTermCollabController.sendToProductTeam(opp.Id);
        Test.stopTest();
        Assert.areEqual('REVIEWING', s.stage);
        Assert.areEqual('C0NEW', s.channelId);
        Assert.isTrue(s.message.contains('열렸습니다'), s.message);
    }

    @IsTest
    static void sendToProductTeam_worksWithoutFee() {
        Opportunity opp = getOpp();
        opp.Fee_Rate__c = null;
        update opp;
        Test.setMock(HttpCalloutMock.class, new ChannelMock());
        Test.startTest();
        DealTermCollabController.State s = DealTermCollabController.sendToProductTeam(opp.Id);
        Test.stopTest();
        Assert.areEqual('REVIEWING', s.stage, '수수료율 없어도 채널은 열린다(미정으로 전달)');
        Assert.areEqual('C0NEW', s.channelId);
    }

    @IsTest
    static void sendToProductTeam_pendingYieldOverCap_blocksWhenNoCase() {
        // 확정 시 상한 초과분은 Pending_Yield__c 에 저장된다 → 적용값(RP_Yield__c)이 비어 있어도 대기값으로 게이트가 막아야 한다.
        Opportunity opp = getOpp();
        opp.Pending_Yield__c = 10; // 상한(7) 초과, 적용값은 비어있음
        update opp;
        Test.setMock(HttpCalloutMock.class, new ChannelMock());
        Test.startTest();
        DealTermCollabController.State s = DealTermCollabController.sendToProductTeam(opp.Id);
        Test.stopTest();
        Assert.isTrue(s.yieldExceeded, '대기값(초과) + Case 없음 → 전달 막고 모달');
    }

    @IsTest
    static void sendToProductTeam_yieldExceeded_blocksWhenNoCase() {
        Opportunity opp = getOpp();
        opp.RP_Yield__c = 10; // 상한(7) 초과, Case 없음 → 전달 대신 모달 플래그
        update opp;
        Test.setMock(HttpCalloutMock.class, new ChannelMock());
        Test.startTest();
        DealTermCollabController.State s = DealTermCollabController.sendToProductTeam(opp.Id);
        Test.stopTest();
        Assert.isTrue(s.yieldExceeded, '상한 초과 + Case 없음 → 전달 막고 모달');
        Assert.isNull(s.channelId, '채널을 열지 않는다');
    }

    @IsTest
    static void createApprovalCase_createsCaseAndOpensPrivateChannel() {
        // 팝업 [Case 생성] → 판매 승인 요청 Case + 딜 전용 프라이빗 채널이 함께 열려야 한다(2026-09-01 요구).
        Opportunity opp = getOpp();
        opp.RP_Yield__c = 10; // 상한 초과 딜
        update opp;
        OpportunityDealChannelService.summaryForTest = '미팅 요약(테스트)'; // ConnectApi 콜 회피
        Test.setMock(HttpCalloutMock.class, new ChannelMock());
        Test.startTest();
        DealTermCollabController.State s = DealTermCollabController.createApprovalCase(opp.Id, '한도 초과 사유', null);
        Test.stopTest(); // enqueue 된 채널 생성 Queueable 이 여기서 실행된다
        Assert.areEqual(1, [SELECT COUNT() FROM Case WHERE Opportunity__c = :opp.Id], '판매 승인 요청 Case 생성');
        Opportunity after = [SELECT Slack_Channel_ID__c FROM Opportunity WHERE Id = :opp.Id];
        Assert.areEqual('C0NEW', after.Slack_Channel_ID__c, 'Case 생성 시 딜 프라이빗 채널이 열린다');
    }

    @IsTest
    static void createApprovalCase_requiresReason() {
        try {
            DealTermCollabController.createApprovalCase(getOpp().Id, '  ', null);
            Assert.fail('사유가 비면 예외');
        } catch (AuraHandledException e) {
            Assert.isTrue(true);
        }
    }

    @IsTest
    static void sendToProductTeam_yieldExceeded_blocksEvenWhenReplied() {
        // 회신 완료(REPLIED) 딜이라도 상한 초과 + 승인 Case 없으면 팝업을 띄운다(2026-09-01 요구, 게이트 순서 재배치).
        Opportunity opp = getOpp();
        opp.Slack_Channel_ID__c = 'C0DEAL1';
        opp.RP_Yield__c = 8; // 상한(7) 초과
        opp.Product_Team_Reply_At__c = Datetime.now();
        opp.Product_Team_Reply_By__c = '이주연';
        update opp;
        Test.setMock(HttpCalloutMock.class, new ChannelMock());
        Test.startTest();
        DealTermCollabController.State s = DealTermCollabController.sendToProductTeam(opp.Id);
        Test.stopTest();
        Assert.areEqual('REPLIED', s.stage);
        Assert.isTrue(s.yieldExceeded, '회신됐어도 상한 초과 + Case 없음 → 모달');
        Assert.areEqual(7, s.yieldCap);
    }

    @IsTest
    static void sendToProductTeam_replied_belowCap_noPopup() {
        // 상한 이하로 회신된 딜은 팝업 없이 그대로 둔다(REPLIED 조기반환 유지).
        Opportunity opp = getOpp();
        opp.Slack_Channel_ID__c = 'C0DEAL1';
        opp.RP_Yield__c = 3.8;
        opp.Product_Team_Reply_At__c = Datetime.now();
        opp.Product_Team_Reply_By__c = '이주연';
        update opp;
        Test.setMock(HttpCalloutMock.class, new ChannelMock());
        Test.startTest();
        DealTermCollabController.State s = DealTermCollabController.sendToProductTeam(opp.Id);
        Test.stopTest();
        Assert.areEqual('REPLIED', s.stage);
        Assert.isFalse(s.yieldExceeded, '상한 이하 회신 딜은 팝업 없음');
    }

    @IsTest
    static void sendToProductTeam_yieldExceeded_sendsWhenCaseExists() {
        Opportunity opp = getOpp();
        opp.RP_Yield__c = 10; // 상한(7) 초과
        update opp;
        insert new Case(Opportunity__c = opp.Id, Description = '판매 승인 요청'); // Case 이미 있음
        Test.setMock(HttpCalloutMock.class, new ChannelMock());
        Test.startTest();
        DealTermCollabController.State s = DealTermCollabController.sendToProductTeam(opp.Id);
        Test.stopTest();
        Assert.isFalse(s.yieldExceeded, 'Case 가 있으면 상한 초과여도 전달한다');
        Assert.areEqual('REVIEWING', s.stage);
        Assert.areEqual('C0NEW', s.channelId, '상품팀 채널을 연다');
    }

    @IsTest
    static void sendToProductTeam_keepsAliveChannel() {
        Opportunity opp = getOpp();
        opp.Slack_Channel_ID__c = 'C0EXIST';
        update opp;
        Test.setMock(HttpCalloutMock.class, new ChannelMock()); // conversations.info → 살아있음
        Test.startTest();
        DealTermCollabController.State s = DealTermCollabController.sendToProductTeam(opp.Id);
        Test.stopTest();
        Assert.areEqual('REVIEWING', s.stage);
        Assert.areEqual('C0EXIST', s.channelId, '살아있는 기존 채널이면 그대로 유지');
        Assert.areEqual('기존 상품팀 채널에 조건을 다시 보냈습니다.', s.message, '재전송 안내');
    }
}