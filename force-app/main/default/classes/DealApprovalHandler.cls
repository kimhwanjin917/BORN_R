/**
 * Slack 딜 카드 [승인] 버튼 처리.
 * BoniSlackEventsRest(게스트) → BoniSlackEventHandler → handle() 호출.
 *
 * DML 컨텍스트 (DealTermReplyHandler / DealCaseRequestHandler 와 동일):
 *  - Site Guest User 는 표준 오브젝트(Case, Opportunity) DML 불가 →
 *    게스트면 Boni_Slack_Event__e(EVENT_APPROVE) 를 발행하고,
 *    BoniSlackEventTrigger(Automated Process) 가 approveFromEvent 로 Case + Opportunity 갱신.
 *  - 카드 교체(chat.update)는 Named Credential 이 필요하므로 게스트 쪽 Queueable Worker 가 처리.
 */
public without sharing class DealApprovalHandler {

    public static final String EVENT_APPROVE = 'deal_approval_approve';
    public static final String ACTION_APPROVE = 'deal_approval_approve';
    public static final String EVENT_MANAGER = 'deal_manager_apply';
    // 채널 토픽에 남기는 매니저 결재 대기 표식. DealApprovalPoller 가 이 문구로 대기 딜을 찾는다.
    // 저장 형태: ':hourglass_flowing_sand: ' + TOPIC_MARKER_TEXT + <원본메시지 ts> + '/' + <클릭시각 ms> + ')'
    public static final String TOPIC_MARKER_TEXT = '매니저 결재 대기(';

    @TestVisible private static Boolean forceEventPath = false;

    // ─── Slack block_actions 진입점 ──────────────────────────────────

    public static void handle(Map<String, Object> p) {
        try {
            handleInternal(p);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DealApprovalHandler 실패: ' + e.getMessage() + '\n' + e.getStackTraceString());
        }
    }

    private static void handleInternal(Map<String, Object> p) {
        String channelId = p.get('channel') instanceof Map<String, Object>
            ? String.valueOf(((Map<String, Object>) p.get('channel')).get('id')) : null;
        String ts = String.valueOf(((Map<String, Object>) p.get('message')).get('ts'));

        String approverName;
        if (p.get('user') instanceof Map<String, Object>) {
            Map<String, Object> u = (Map<String, Object>) p.get('user');
            approverName = u.containsKey('name') ? String.valueOf(u.get('name')) : null;
        }

        Id oppId;
        for (Object a : (List<Object>) p.get('actions')) {
            Map<String, Object> am = (Map<String, Object>) a;
            if (String.valueOf(am.get('action_id')) == ACTION_APPROVE) {
                oppId = parseId(String.valueOf(am.get('value')));
            }
        }
        if (oppId == null) {
            System.debug(LoggingLevel.WARN, 'deal_approval_approve: value 가 Opportunity Id 가 아님 — 무시');
            return;
        }

        List<Object> originalBlocks;
        Object mb = ((Map<String, Object>) p.get('message')).get('blocks');
        if (mb instanceof List<Object>) {
            originalBlocks = (List<Object>) mb;
        }

        approve(oppId, channelId, ts, originalBlocks, approverName);
    }

    // ─── 승인 실행 ──────────────────────────────────────────────────

    private static void approve(Id oppId, String channelId, String ts, List<Object> originalBlocks, String approverName) {
        Map<String, Object> payload = new Map<String, Object>{
            'oppId' => String.valueOf(oppId),
            'channelId' => channelId,
            'ts' => ts
        };
        if (forceEventPath || UserInfo.getUserType() == 'Guest') {
            Database.SaveResult sr = EventBus.publish(
                new Boni_Slack_Event__e(Event_Type__c = EVENT_APPROVE, Payload__c = JSON.serialize(payload)));
            if (!sr.isSuccess()) {
                throw new DealApprovalException('승인 이벤트 발행 실패: ' + sr.getErrors()[0].getMessage());
            }
        } else {
            approveFromPayload(payload);
        }
        System.enqueueJob(new Worker(oppId, channelId, ts, originalBlocks, approverName));
    }

    // ─── 트리거(Automated Process) 진입점 ──────────────────────────

    public static void approveFromEvent(Map<String, Object> p) {
        approveFromPayload(p);
    }

    private static void approveFromPayload(Map<String, Object> p) {
        Id oppId = (Id) String.valueOf(p.get('oppId'));

        Opportunity opp = [
            SELECT Id, Pending_Yield__c, RP_Yield__c
            FROM Opportunity WHERE Id = :oppId
        ];

        List<Case> cases = [
            SELECT Id, Agreed_Yield_Rate__c
            FROM Case WHERE Opportunity__c = :oppId
            ORDER BY CreatedDate DESC LIMIT 1
        ];

        // Case 승인 상태 갱신
        if (!cases.isEmpty()) {
            cases[0].Approval_Status__c = '승인';
            update cases[0];
        }

        // 수익률 승격: Pending_Yield__c → RP_Yield__c (없으면 Case.Agreed_Yield_Rate__c → RP_Yield__c)
        Decimal promotedYield = opp.Pending_Yield__c;
        if (promotedYield == null && !cases.isEmpty()) {
            promotedYield = cases[0].Agreed_Yield_Rate__c;
        }
        if (promotedYield != null) {
            opp.RP_Yield__c = promotedYield;
            opp.Pending_Yield__c = null;
            update opp;
        } else if (opp.Pending_Yield__c != null) {
            opp.Pending_Yield__c = null;
            update opp;
        }
    }

    // ─── 카드 교체 Worker ───────────────────────────────────────────

    public class Worker implements Queueable, Database.AllowsCallouts {
        private final Id oppId;
        private final String channelId;
        private final String ts;
        private final List<Object> originalBlocks;
        private final String approverName;

        public Worker(Id oppId, String channelId, String ts, List<Object> originalBlocks, String approverName) {
            this.oppId = oppId;
            this.channelId = channelId;
            this.ts = ts;
            this.originalBlocks = originalBlocks;
            this.approverName = approverName;
        }

        public void execute(QueueableContext ctx) {
            try {
                if (String.isBlank(channelId) || String.isBlank(ts)) return;
                List<Object> blocks = approvedBlocksFromOriginal(originalBlocks, oppId, approverName);
                BoniSlackClient.updateBlocks(channelId, ts, '승인 완료', blocks);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, '승인 카드 갱신 실패: ' + e.getMessage());
            }
        }
    }

    @TestVisible
    private static List<Object> approvedBlocksFromOriginal(List<Object> originalBlocks, Id oppId, String approverName) {
        return approvedBlocksFromOriginal(originalBlocks, oppId, approverName, false);
    }

    /** reviewed=true 면 매니저 결재 완료("(심사 완료)") 문구로 카드를 마감한다(DealApprovalPoller 가 호출). */
    public static List<Object> approvedBlocksFromOriginal(List<Object> originalBlocks, Id oppId, String approverName, Boolean reviewed) {
        List<Object> blocks = new List<Object>();
        if (originalBlocks != null) {
            for (Object o : originalBlocks) {
                Map<String, Object> b = (Map<String, Object>) o;
                String t = String.valueOf(b.get('type'));
                if (t == 'actions') continue;
                blocks.add(b);
            }
        }
        String doneText = reviewed
            ? ':white_check_mark: *매니저 결재 완료 — 조건이 승인되었습니다. (심사 완료)* · '
            : ':white_check_mark: *상품팀 검토 완료 — 조건이 승인되었습니다.* · ';
        blocks.add(new Map<String, Object>{ 'type' => 'divider' });
        blocks.add(new Map<String, Object>{ 'type' => 'section', 'text' => new Map<String, Object>{ 'type' => 'mrkdwn',
            'text' => doneText + Datetime.now().format('M/d HH:mm', 'Asia/Seoul') } });
        String oppUrl = URL.getOrgDomainUrl().toExternalForm() + '/' + oppId;
        blocks.add(new Map<String, Object>{ 'type' => 'actions', 'elements' => new List<Object>{
            new Map<String, Object>{
                'type' => 'button',
                'text' => new Map<String, Object>{ 'type' => 'plain_text', 'text' => '계약서 작성하러 가기' },
                'url' => oppUrl,
                'action_id' => 'open_opportunity'
            }
        } });
        return blocks;
    }

    // ─── 매니저 결재 (2026-09-02 재구성) ─────────────────────────────
    //
    // 클릭(게스트)은 DML 을 못 하므로 "처리 중" 카드 교체 + 채널 토픽 표식만 남긴다.
    // 실제 승인(Case '승인' + 수익률 승격)과 완료 카드·조건서 게시는 DealApprovalPoller 가 수행한다.

    /** Slack [매니저 결재] 클릭 진입점 — 콜아웃 워커를 큐잉(카드=처리중, 토픽=표식). DML 없음. */
    public static void handleManager(Map<String, Object> p) {
        try {
            String channelId = p.get('channel') instanceof Map<String, Object>
                ? String.valueOf(((Map<String, Object>) p.get('channel')).get('id')) : null;
            String ts = p.get('message') instanceof Map<String, Object>
                ? String.valueOf(((Map<String, Object>) p.get('message')).get('ts')) : null;
            Id oppId;
            if (p.get('actions') instanceof List<Object>) {
                for (Object a : (List<Object>) p.get('actions')) {
                    Map<String, Object> am = (Map<String, Object>) a;
                    if (String.valueOf(am.get('action_id')) == OpportunityDealChannelService.ACTION_APPROVAL_MANAGER) {
                        oppId = parseId(String.valueOf(am.get('value')));
                    }
                }
            }
            List<Object> originalBlocks;
            if (p.get('message') instanceof Map<String, Object>) {
                Object mb = ((Map<String, Object>) p.get('message')).get('blocks');
                if (mb instanceof List<Object>) originalBlocks = (List<Object>) mb;
            }
            if (oppId == null || String.isBlank(channelId) || String.isBlank(ts)) {
                System.debug(LoggingLevel.WARN, 'handleManager: oppId/channel/ts 누락 — 무시');
                return;
            }
            System.enqueueJob(new ManagerWorker(oppId, channelId, ts, originalBlocks));
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'handleManager 실패: ' + e.getMessage() + '\n' + e.getStackTraceString());
        }
    }

    /** EVENT_MANAGER 플랫폼 이벤트 경로 — 레코드 승인만 수행. */
    public static void managerFromEvent(Map<String, Object> p) {
        Id oppId = parseId(String.valueOf(p.get('oppId')));
        if (oppId != null) applyApprovalRecords(oppId);
    }

    /** 처리 중 카드 교체 + 토픽 표식 기록 콜아웃 워커. */
    public class ManagerWorker implements Queueable, Database.AllowsCallouts {
        private final Id oppId; private final String channelId; private final String ts;
        private final List<Object> originalBlocks;
        public ManagerWorker(Id oppId, String channelId, String ts, List<Object> originalBlocks) {
            this.oppId = oppId; this.channelId = channelId; this.ts = ts; this.originalBlocks = originalBlocks;
        }
        public void execute(QueueableContext ctx) {
            try {
                BoniSlackClient.updateBlocks(channelId, ts, '매니저 결재 처리 중', processingBlocks(originalBlocks));
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, '처리중 카드 교체 실패: ' + e.getMessage());
            }
            try {
                writeApprovalMarker(channelId, ts);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, '토픽 표식 기록 실패: ' + e.getMessage());
            }
        }
    }

    private static List<Object> processingBlocks(List<Object> originalBlocks) {
        List<Object> blocks = new List<Object>();
        if (originalBlocks != null) {
            for (Object o : originalBlocks) {
                Map<String, Object> b = (Map<String, Object>) o;
                if (String.valueOf(b.get('type')) == 'actions') continue;
                blocks.add(b);
            }
        }
        blocks.add(new Map<String, Object>{ 'type' => 'divider' });
        blocks.add(new Map<String, Object>{ 'type' => 'section', 'text' => new Map<String, Object>{ 'type' => 'mrkdwn',
            'text' => ':hourglass_flowing_sand: *매니저 결재 요청 접수 — 심사 처리 중입니다.* · '
                + Datetime.now().format('M/d HH:mm', 'Asia/Seoul') } });
        return blocks;
    }

    // ─── 채널 토픽 표식 I/O (DealApprovalPoller 가 read/clear 를 호출) ──

    /** 처리 중 표식을 채널 토픽에 기록: ':hourglass_flowing_sand: ' + TOPIC_MARKER_TEXT + ts + '/' + 클릭ms + ')' */
    private static void writeApprovalMarker(String channelId, String ts) {
        String topic = ':hourglass_flowing_sand: ' + TOPIC_MARKER_TEXT + ts + '/' + System.currentTimeMillis() + ')';
        slackPost('/conversations.setTopic', new Map<String, Object>{ 'channel' => channelId, 'topic' => topic });
    }

    /** 채널 토픽에서 대기 표식을 읽어 [원본메시지 ts, 클릭ms] 를 돌려준다. 표식 없으면 빈 리스트. */
    public static List<String> readApprovalMarker(String channelId) {
        List<String> result = new List<String>();
        if (String.isBlank(channelId)) return result;
        Map<String, Object> info = slackGet('/conversations.info?channel=' + EncodingUtil.urlEncode(channelId, 'UTF-8'));
        if (info.get('ok') != true) return result;
        Object ch = info.get('channel');
        if (!(ch instanceof Map<String, Object>)) return result;
        Object topicObj = ((Map<String, Object>) ch).get('topic');
        String topic = topicObj instanceof Map<String, Object>
            ? String.valueOf(((Map<String, Object>) topicObj).get('value')) : null;
        if (String.isBlank(topic) || !topic.contains(TOPIC_MARKER_TEXT)) return result;
        String rest = topic.substringAfter(TOPIC_MARKER_TEXT).substringBefore(')');
        String ts = rest.substringBefore('/');
        String clickedAt = rest.substringAfter('/');
        if (String.isNotBlank(ts)) result.add(ts);
        if (String.isNotBlank(clickedAt)) result.add(clickedAt);
        return result;
    }

    /** 처리 완료 후 토픽 표식 제거. */
    public static void clearApprovalTopic(String channelId) {
        if (String.isBlank(channelId)) return;
        slackPost('/conversations.setTopic', new Map<String, Object>{ 'channel' => channelId, 'topic' => '' });
    }

    // ─── 레코드 승인 (Case '승인' + Pending→RP 승격) ─────────────────

    /** oppId 로 최신 Case 를 '승인' 처리하고 대기 수익률을 RP_Yield__c 로 승격한다. */
    public static void applyApprovalRecords(Id oppId) {
        if (oppId == null) return;
        List<Case> cases = [
            SELECT Id, Approval_Status__c, Agreed_Yield_Rate__c
            FROM Case WHERE Opportunity__c = :oppId
            ORDER BY CreatedDate DESC LIMIT 1
        ];
        if (!cases.isEmpty()) {
            cases[0].Approval_Status__c = '승인';
            update cases[0];
        }
        Opportunity opp = [SELECT Id, Pending_Yield__c, RP_Yield__c FROM Opportunity WHERE Id = :oppId];
        Decimal promotedYield = opp.Pending_Yield__c;
        if (promotedYield == null && !cases.isEmpty()) {
            promotedYield = cases[0].Agreed_Yield_Rate__c;
        }
        if (promotedYield != null) {
            opp.RP_Yield__c = promotedYield;
            opp.Pending_Yield__c = null;
            update opp;
        } else if (opp.Pending_Yield__c != null) {
            opp.Pending_Yield__c = null;
            update opp;
        }
    }

    // ─── Slack 저수준 콜아웃 (DealApprovalPoller 의 것과 동일 절차) ────

    private static Map<String, Object> slackPost(String path, Map<String, Object> body) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:Slack' + path);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json; charset=utf-8');
        req.setTimeout(20000);
        req.setBody(JSON.serialize(body));
        return (Map<String, Object>) JSON.deserializeUntyped(new Http().send(req).getBody());
    }

    private static Map<String, Object> slackGet(String pathWithQuery) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:Slack' + pathWithQuery);
        req.setMethod('GET');
        req.setTimeout(20000);
        return (Map<String, Object>) JSON.deserializeUntyped(new Http().send(req).getBody());
    }

    public class DealApprovalException extends Exception {}

    private static Id parseId(String raw) {
        try {
            Id candidate = (Id) raw;
            return candidate.getSobjectType() == Opportunity.SObjectType ? candidate : null;
        } catch (Exception e) {
            return null;
        }
    }
}