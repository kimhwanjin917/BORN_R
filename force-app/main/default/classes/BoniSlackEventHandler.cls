/** 플랫폼 이벤트 소비. Automated Process 사용자 컨텍스트 → Queueable 로 콜아웃. */
public with sharing class BoniSlackEventHandler {

    public static void handle(List<Boni_Slack_Event__e> events) {
        Set<String> refreshUsers = new Set<String>();
        List<Reply> replies = new List<Reply>();
        for (Boni_Slack_Event__e ev : events) {
            Map<String, Object> p;
            try { p = (Map<String, Object>) JSON.deserializeUntyped(ev.Payload__c); } catch (Exception e) { continue; }
            if (ev.Event_Type__c == DealTermReplyHandler.EVENT_APPLY) {
                DealTermReplyHandler.applyFromEvent(p); // docs/58 게스트가 발행 → 트리거(Automated Process)가 Opportunity 갱신
            } else if (ev.Event_Type__c == DealCaseRequestHandler.EVENT_CREATE) {
                DealCaseRequestHandler.createFromEvent(p); // 게스트가 발행 → 트리거가 심사 Case 생성
            } else if (ev.Event_Type__c == DealApprovalHandler.EVENT_APPROVE) {
                DealApprovalHandler.approveFromEvent(p);
            } else if (ev.Event_Type__c == DealApprovalHandler.EVENT_MANAGER) {
                DealApprovalHandler.managerFromEvent(p);
            } else if (ev.Event_Type__c == 'app_home_opened') {
                Map<String, Object> e = (Map<String, Object>) p.get('event');
                if (e != null && String.valueOf(e.get('tab')) == 'home') refreshUsers.add(String.valueOf(e.get('user')));
            } else if (ev.Event_Type__c == 'block_actions') {
                String user = String.valueOf(((Map<String, Object>) p.get('user')).get('id'));
                String channel = p.get('channel') instanceof Map<String, Object> ? String.valueOf(((Map<String, Object>) p.get('channel')).get('id')) : null;
                for (Object a : (List<Object>) p.get('actions')) {
                    String actionId = String.valueOf(((Map<String, Object>) a).get('action_id'));
                    String value = String.valueOf(((Map<String, Object>) a).get('value'));
                    if (actionId == BoniBlockKitBuilder.ACTION_REFRESH) refreshUsers.add(user);
                    else if (actionId == BoniBlockKitBuilder.ACTION_PREP) replies.add(new Reply(user, channel, '미팅 준비카드는 준비 중이에요. 곧 여기서 바로 볼 수 있어요. (' + value + ') :boni_tablet:'));
                    else if (actionId == BoniBlockKitBuilder.ACTION_ROLLOVER) replies.add(new Reply(user, channel, '롤오버 제안 흐름은 준비 중이에요. 운용데스크 조건조회와 함께 연결됩니다. (' + value + ') :boni_chart:'));
                    else if (actionId == OpportunityDealChannelService.ACTION_APPROVAL_APPROVE) DealApprovalHandler.handle(p); // 딜 카드 승인 버튼
                    else if (actionId == OpportunityDealChannelService.ACTION_APPROVAL_REJECT) replies.add(new Reply(user, channel, ':no_entry_sign: 반려 처리는 준비 중입니다.'));
                    else if (actionId == OpportunityDealChannelService.ACTION_APPROVAL_MANAGER) DealApprovalHandler.handleManager(p); // 처리중 카드 + 토픽 표식 → DealApprovalPoller 가 완료
                    else if (actionId == OpportunityDealChannelService.ACTION_REPLY) DealTermReplyHandler.handle(p); // docs/58 상품팀 조건 회신
                    else if (actionId == OpportunityDealChannelService.ACTION_CASE_CREATE) {
                        DealCaseRequestHandler.handle(p); // 게스트 → 이벤트 발행 → 트리거가 심사 Case 생성(내부에서 예외 삼킴)
                        replies.add(new Reply(user, channel, ':card_index_dividers: 판매 승인 요청 Case를 생성했습니다.'));
                    }
                }
            }
        }
        if (!refreshUsers.isEmpty() || !replies.isEmpty()) System.enqueueJob(new Worker(new List<String>(refreshUsers), replies));
    }

    public class Reply { public String user; public String channel; public String text;
        public Reply(String u, String c, String t) { user = u; channel = c; text = t; } }

    public class Worker implements Queueable, Database.AllowsCallouts {
        private List<String> users; private List<Reply> replies;
        public Worker(List<String> users, List<Reply> replies) { this.users = users; this.replies = replies; }
        public void execute(QueueableContext ctx) {
            for (String u : users) {
                try { BoniPublisher.publishNow(BoniPublisher.Mode.HOME, u); }
                catch (Exception e) { System.debug(LoggingLevel.ERROR, 'home refresh 실패 ' + u + ': ' + e.getMessage()); }
            }
            for (Reply r : replies) {
                try {
                    if (String.isNotBlank(r.channel)) BoniSlackClient.postEphemeral(r.channel, r.user, r.text);
                    else BoniSlackClient.postBlocks(r.user, r.text, new List<Object>{ new Map<String, Object>{ 'type' => 'section', 'text' => new Map<String, Object>{ 'type' => 'mrkdwn', 'text' => r.text } } });
                } catch (Exception e) { System.debug(LoggingLevel.ERROR, 'reply 실패 ' + r.user + ': ' + e.getMessage()); }
            }
        }
    }
}