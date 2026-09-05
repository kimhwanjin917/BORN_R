/**
 * docs/58 Scene 3 — LWC dealTermCollab 의 Apex. 상태 조회와 [계약서 생성].
 * 계약서 생성 = OpportunityReviewService.completeReview (승인·Contract·PDF·Task·Stage) 그대로 호출 후
 * 만들어진 PDF 를 딜 Slack 채널에 공유(SlackProposalShareService.shareContentDocumentToChannel).
 * 콜아웃(PDF 렌더링·Slack) 이 있으므로 이 클래스는 조회 전에 DML 을 하지 않는다.
 */
public with sharing class DealTermCollabController {

    /**
     * 상품팀 전달 허용 약정수익률 상한(연 %). RP_Yield__c 가 이 값을 넘으면 전달을 막고
     * 판매 승인 요청 Case 를 만들도록 안내한다(2026-09-01 요구). RP_Yield__c 는 Percent 필드라
     * 7% 는 7 로 저장된다.
     */
    @TestVisible private static final Decimal MAX_AGREED_YIELD = 7;

    public class State {
        @AuraEnabled public String stage;          // WAITING | REVIEWING | REPLIED | DONE
        @AuraEnabled public Decimal feeRate;
        @AuraEnabled public Decimal baseFeeRate;
        @AuraEnabled public String channelId;
        @AuraEnabled public String channelLink;
        @AuraEnabled public String repName;
        @AuraEnabled public Decimal rpYield;
        @AuraEnabled public Decimal couponRate;
        @AuraEnabled public String issuerName;
        @AuraEnabled public String replyBy;
        @AuraEnabled public Datetime replyAt;
        @AuraEnabled public String replyLink;
        @AuraEnabled public Id contractId;
        @AuraEnabled public String contractNumber;
        @AuraEnabled public Id contractDocumentId;
        @AuraEnabled public String message;
        /** 확정 조건서 PDF 가 없어 Slack 에 첨부하지 못한 경우 true — 호출자가 경고를 띄운다. */
        @AuraEnabled public Boolean termPdfMissing = false;
        /** 약정수익률이 상한(연 7%)을 넘어 전달을 막은 경우 true — 호출자가 사유 입력 모달을 띄운다. */
        @AuraEnabled public Boolean yieldExceeded = false;
        /** yieldExceeded 일 때 상한값(연 %). 모달 문구용. */
        @AuraEnabled public Decimal yieldCap;
    }

    @AuraEnabled(cacheable=false)
    public static State getState(Id opportunityId) {
        Opportunity opp = [
            SELECT Id, Fee_Rate__c, Slack_Channel_ID__c, Slack_Channel_Link__c, RP_Yield__c, Pending_Yield__c, Coupon_Rate__c, Issuer_Name__c,
                   Product_Team_Reply_By__c, Product_Team_Reply_At__c, Slack_Reply_Link__c, Approval_Status__c,
                   Primary_Product__r.Default_Fee_Rate__c, Primary_Product__r.Product_Team_Rep__r.Name
            FROM Opportunity
            WHERE Id = :opportunityId
            WITH USER_MODE
        ];
        State s = new State();
        s.feeRate = opp.Fee_Rate__c;
        s.baseFeeRate = opp.Primary_Product__r?.Default_Fee_Rate__c;
        s.channelId = opp.Slack_Channel_ID__c;
        s.channelLink = opp.Slack_Channel_Link__c;
        s.repName = opp.Primary_Product__r?.Product_Team_Rep__r?.Name;
        // 상한 초과로 승인 대기 중인 값(Pending_Yield__c)이 있으면 그것을, 없으면 적용값(RP_Yield__c)을 유효 수익률로 쓴다.
        // 이 유효값이 전달 게이트(sendToProductTeam)와 Slack 카드의 제안 수익률 판정 기준이 된다.
        s.rpYield = opp.Pending_Yield__c != null ? opp.Pending_Yield__c : opp.RP_Yield__c;
        s.couponRate = opp.Coupon_Rate__c;
        s.issuerName = opp.Issuer_Name__c;
        s.replyBy = opp.Product_Team_Reply_By__c;
        s.replyAt = opp.Product_Team_Reply_At__c;
        s.replyLink = opp.Slack_Reply_Link__c;

        if (opp.Approval_Status__c == OpportunityReviewService.APPROVED) {
            s.stage = 'DONE';
            List<Contract> cons = [
                SELECT Id, ContractNumber FROM Contract
                WHERE SourceOpportunityId = :opportunityId
                WITH USER_MODE
                ORDER BY CreatedDate DESC LIMIT 1
            ];
            if (!cons.isEmpty()) {
                s.contractId = cons[0].Id;
                s.contractNumber = cons[0].ContractNumber;
                List<ContentDocumentLink> links = [
                    SELECT ContentDocumentId FROM ContentDocumentLink
                    WHERE LinkedEntityId = :cons[0].Id
                    WITH USER_MODE
                    ORDER BY SystemModstamp DESC LIMIT 1
                ];
                if (!links.isEmpty()) {
                    s.contractDocumentId = links[0].ContentDocumentId;
                }
            }
        } else if (opp.Product_Team_Reply_At__c != null) {
            s.stage = 'REPLIED';
        } else if (String.isNotBlank(opp.Slack_Channel_ID__c)) {
            s.stage = 'REVIEWING';
        } else {
            s.stage = 'WAITING';
        }
        return s;
    }

    /**
     * [상품팀 전달] 버튼. 딜 Slack 채널 생성·초대·요약·조건 카드 게시(동기, 콜아웃).
     * 회신·계약 단계면 그대로 둔다. 그 전 단계면 createChannels 가 판단 — 살아있는 채널이 있으면 유지,
     * 아카이브·삭제된 채널이면 새로 판다(재전송). 확정 수수료율은 필수 아님.
     */
    @AuraEnabled
    public static State sendToProductTeam(Id opportunityId) {
        State before = getState(opportunityId);
        // 승인·계약 완료(DONE)면 그대로 둔다. 회신 완료(REPLIED)는 아래 yield 게이트를 먼저 통과시킨다 —
        // 회신된 딜이라도 상한 초과 + 승인 Case 없으면 사유 입력 모달을 띄워야 하므로(2026-09-01 요구).
        if (before.stage == 'DONE') {
            return before;
        }
        // 약정수익률이 상한(연 7%)을 넘으면 전달을 막고, 사유 입력 모달을 띄우도록 플래그만 돌려준다
        // (2026-09-01 요구). 예외로 막지 않는 건 호출자(LWC)가 모달을 열어 판매 승인 요청 Case 를
        // 만들 수 있게 하기 위함이다. 실제 Case 생성은 createApprovalCase 가 맡는다.
        // 단, 이미 판매 승인 요청 Case 가 만들어진 기회는 상한을 넘어도 그대로 상품팀 채널로 전달한다
        // (2026-09-01 요구: 상품팀은 Slack 만 보므로, Case 가 있으면 다시 전달 시 채널에 Case 정보를 실어 보낸다).
        if (before.rpYield != null && before.rpYield > MAX_AGREED_YIELD && !hasApprovalCase(opportunityId)) {
            before.yieldExceeded = true;
            before.yieldCap = MAX_AGREED_YIELD;
            return before;
        }
        // 회신 완료(REPLIED)이고 위 게이트를 통과한(상한 이하이거나 승인 Case 있음) 딜은 그대로 둔다.
        if (before.stage == 'REPLIED') {
            return before;
        }
        // [조건 확정하기] 로 만든 확정 조건서. 없어도 전달을 막지는 않는다 — 수수료 미정 상태로도 채널을 여는
        // 기존 동작(DealTermCollabControllerTest.sendToProductTeam_worksWithoutFee)을 그대로 지키고,
        // 대신 termPdfMissing 으로 호출자에게 알려 경고를 띄우게 한다. 빈 PDF 를 대신 만들지 않는다.
        Id termPdfId = RpTermConfirmController.findLatestTermPdfId(opportunityId);
        try {
            List<Id> done = OpportunityDealChannelService.createChannels(new List<Id>{ opportunityId });
            State after = getState(opportunityId);
            if (done.isEmpty()) {
                // 살아있는 채널이 이미 있어 재생성을 건너뛴 경우 → 기존 채널 유지, 조건 카드만 재게시됨
                if (String.isNotBlank(after.channelId)) {
                    // 카드를 재게시했든(resentIds) 살아있는 채널을 그대로 뒀든, 최신 확정 조건서는 항상 보낸다.
                    shareTermPdf(termPdfId, after.channelId);
                    after.termPdfMissing = (termPdfId == null);
                    if (OpportunityDealChannelService.resentIds.contains(opportunityId)) {
                        after.message = '기존 상품팀 채널에 조건을 다시 보냈습니다.' + termNote(termPdfId);
                    }
                    return after;
                }
                throw new AuraHandledException('Slack 채널을 만들지 못했습니다. 잠시 후 다시 시도하세요.');
            }
            shareTermPdf(termPdfId, after.channelId);
            after.termPdfMissing = (termPdfId == null);
            after.message = '상품팀 채널이 열렸습니다' + (String.isBlank(after.repName) ? '' : ' — 담당 ' + after.repName)
                + '.' + termNote(termPdfId);
            return after;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('상품팀 전달 실패: ' + e.getMessage());
        }
    }

    /**
     * Salesforce 화면에서의 상품팀 회신. Slack 카드 [회신 제출]과 같은 DealTermReplyHandler.applyReply 를 타므로
     * 필드 갱신·회신자·시각·이후 흐름이 동일하고, Slack 채널에는 회신 완료 카드가 새로 게시된다.
     * 검토 중(REVIEWING) 단계에서만 받는다. 값은 전부 선택.
     */
    @AuraEnabled
    public static State submitReply(Id opportunityId, Decimal rpYield, Decimal appliedFeeRate, Decimal couponRate, String issuerName) {
        State before = getState(opportunityId);
        if (before.stage != 'REVIEWING') {
            throw new AuraHandledException('상품팀 검토 중 단계에서만 회신할 수 있습니다.');
        }
        try {
            DealTermReplyHandler.applyReply(opportunityId, UserInfo.getName(), before.channelId, null,
                rpYield, appliedFeeRate, couponRate, issuerName);
            State after = getState(opportunityId);
            after.message = '회신을 기록하고 Slack 채널에 공유했습니다.';
            return after;
        } catch (Exception e) {
            throw new AuraHandledException('회신 실패: ' + e.getMessage());
        }
    }

    /**
     * 약정수익률이 상한을 넘어 전달이 막힌 딜을 판매 승인 요청 Case 로 올린다(2026-09-01 요구).
     * 사유 입력 모달의 [Case 생성] 이 호출한다. 기존 심사 Case 경로(DealCaseRequestHandler.create)를
     * 그대로 재사용하므로 같은 기회의 Case 는 중복 생성되지 않고 갱신된다.
     */
    @AuraEnabled
    public static State createApprovalCase(Id opportunityId, String reason, Decimal termMonths) {
        if (String.isBlank(reason)) {
            throw new AuraHandledException('Case 사유를 입력하세요.');
        }
        try {
            DealCaseRequestHandler.create(opportunityId, termMonths, reason);
            // 판매 승인 요청 Case 를 딜 전용 프라이빗 채널로도 전달한다(2026-09-01 요구) — 상품팀-검토 공용
            // 채널 알림(Flow)만으로는 딜별 프라이빗 채널이 안 열리므로 여기서 채널 생성을 연결한다.
            // Case DML 커밋 후 Slack 콜아웃해야 "uncommitted work pending" 을 피하므로 Queueable 로 비동기 실행한다.
            // createChannels 는 이 시점엔 Case 가 커밋돼 있어 조건 카드에 판매 승인 요청 Case 정보를 함께 싣는다.
            if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
                System.enqueueJob(new OpportunityDealChannelService(new List<Id>{ opportunityId }));
            }
            State after = getState(opportunityId);
            after.message = '판매 승인 요청 Case 를 생성했고, 딜 채널을 여는 중입니다. 심사 결과를 기다려 주세요.';
            return after;
        } catch (Exception e) {
            throw new AuraHandledException('Case 생성 실패: ' + e.getMessage());
        }
    }

    /** 이 기회에 판매 승인 요청 Case 가 이미 있는지. 있으면 수익률 상한 초과여도 상품팀 채널로 전달한다. */
    private static Boolean hasApprovalCase(Id opportunityId) {
        return [SELECT COUNT() FROM Case WHERE Opportunity__c = :opportunityId WITH USER_MODE] > 0;
    }

    @AuraEnabled
    public static State createContract(Id opportunityId) {
        State before = getState(opportunityId);
        if (before.stage == 'DONE') {
            return before;
        }
        if (before.stage != 'REPLIED') {
            throw new AuraHandledException('상품팀 회신이 도착한 뒤에 계약서를 만들 수 있습니다.');
        }
        try {
            OpportunityReviewService.completeReview(new List<Id>{ opportunityId });
            State after = getState(opportunityId);
            if (after.contractDocumentId != null && String.isNotBlank(after.channelId)) {
                // DML 뒤 같은 트랜잭션에서 콜아웃하면 "uncommitted work pending" → 비동기로 공유
                System.enqueueJob(new ContractShareJob(after.contractDocumentId, after.channelId));
                after.message = '계약서 ' + after.contractNumber + ' 생성 완료. Slack 채널에 PDF 를 공유하는 중입니다.';
            } else {
                after.message = '계약서 ' + after.contractNumber + ' 생성 완료.';
            }
            return after;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('계약서 생성 실패: ' + e.getMessage());
        }
    }

    /**
     * 메시지 꼬리말. 확정 조건서가 없을 때는 빈 문자열을 돌려주어 기존 안내 문구를 그대로 둔다
     * (경고는 State.termPdfMissing 으로 전달한다).
     */
    private static String termNote(Id termPdfId) {
        return termPdfId == null ? '' : ' 확정 조건서를 함께 보냈습니다.';
    }

    /**
     * 확정 조건서 PDF 를 딜 Slack 채널에 첨부. 기존 계약서 공유와 같은 경로(ContractShareJob →
     * SlackProposalShareService.shareContentDocumentToChannel)를 그대로 쓴다. createChannels 의 DML 뒤라
     * 같은 트랜잭션에서 콜아웃하면 "uncommitted work pending" 이 나므로 비동기로 보낸다.
     */
    private static void shareTermPdf(Id contentDocumentId, String channelId) {
        if (contentDocumentId == null || String.isBlank(channelId)) {
            return;
        }
        System.enqueueJob(new ContractShareJob(contentDocumentId, channelId));
    }

    /** 계약서 PDF 를 딜 Slack 채널에 공유(콜아웃). createContract 의 DML 과 분리하기 위해 비동기. */
    public class ContractShareJob implements Queueable, Database.AllowsCallouts {
        private final Id contentDocumentId;
        private final String channelId;
        public ContractShareJob(Id contentDocumentId, String channelId) {
            this.contentDocumentId = contentDocumentId;
            this.channelId = channelId;
        }
        public void execute(QueueableContext ctx) {
            try {
                SlackProposalShareService.shareContentDocumentToChannel(contentDocumentId, channelId);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, '계약서 Slack 공유 실패: ' + e.getMessage());
            }
        }
    }
}