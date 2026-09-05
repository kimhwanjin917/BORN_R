/**
 * docs/58 Scene 3 — Slack 조건 카드 [회신 제출] 처리. BoniSlackEventsRest(게스트) → BoniSlackEventHandler 에서 호출.
 * 쓰는 필드: RP_Yield__c, Fee_Rate__c, Coupon_Rate__c, Issuer_Name__c, Product_Team_Reply_By__c, Product_Team_Reply_At__c, Slack_Reply_Link__c.
 * 승인(Approval_Status__c)은 건드리지 않는다 — 회신 ≠ 승인.
 * 회신값은 전부 선택 — 들어온 값만 기록하고, 비어 있어도 회신 완료로 처리한다(강제 입력·재제출 없음).
 *
 * DML 컨텍스트 (2026-08-31 실측으로 확정):
 *  - Site Guest User 는 표준 오브젝트 Edit 을 가질 수 없고, without sharing + 시스템 모드 DML 도
 *    "SecurityException: Access to entity 'Opportunity' denied" 가 난다. 그래서 게스트 경로에서는
 *    Boni_Slack_Event__e(EVENT_APPLY) 를 발행하고, BoniSlackEventTrigger(Automated Process) 가 applyFromEvent 로 갱신한다.
 *  - Salesforce 화면 경로(DealTermCollabController.submitReply, 사용자 컨텍스트)는 그대로 직접 DML.
 *  - 카드 교체(chat.update, Named Credential 필요)는 Automated Process 가 못 하므로 게스트 Worker 가 맡는다.
 *    Worker 는 DB 를 신뢰하지 않고 회신값을 직접 들고 카드를 그린다(트리거 처리 순서와 무관).
 * 어떤 예외도 REST 로 새지 않게 handle() 전체를 try 로 감싼다(Slack 은 200 을 기대).
 */
public without sharing class DealTermReplyHandler {

    /** Boni_Slack_Event__e.Event_Type__c — 게스트가 발행, 트리거가 Opportunity 갱신. */
    public static final String EVENT_APPLY = 'deal_term_apply';

    /** 테스트용: true 면 게스트가 아니어도 이벤트 경로를 탄다. */
    @TestVisible private static Boolean forceEventPath = false;

    public static void handle(Map<String, Object> p) {
        try {
            handleInternal(p);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DealTermReplyHandler 실패: ' + e.getMessage() + '\n' + e.getStackTraceString());
        }
    }

    private static void handleInternal(Map<String, Object> p) {
        Map<String, Object> user = (Map<String, Object>) p.get('user');
        String slackUserId = String.valueOf(user.get('id'));
        String replyBy = user.get('name') != null && String.isNotBlank(String.valueOf(user.get('name')))
            ? String.valueOf(user.get('name'))
            : String.valueOf(user.get('username'));
        String channelId = String.valueOf(((Map<String, Object>) p.get('channel')).get('id'));
        String ts = String.valueOf(((Map<String, Object>) p.get('message')).get('ts'));

        Id oppId;
        for (Object a : (List<Object>) p.get('actions')) {
            Map<String, Object> am = (Map<String, Object>) a;
            if (String.valueOf(am.get('action_id')) == OpportunityDealChannelService.ACTION_REPLY) {
                oppId = parseId(String.valueOf(am.get('value')));
            }
        }
        if (oppId == null) {
            System.debug(LoggingLevel.WARN, 'deal_term_reply: value 가 Opportunity Id 가 아님 — 무시');
            return;
        }

        String yieldRaw = stateValue(p, OpportunityDealChannelService.BLOCK_YIELD, OpportunityDealChannelService.ACTION_YIELD);
        String appliedFeeRaw = stateValue(p, OpportunityDealChannelService.BLOCK_APPLIED_FEE, OpportunityDealChannelService.ACTION_APPLIED_FEE);
        String couponRaw = stateValue(p, OpportunityDealChannelService.BLOCK_COUPON, OpportunityDealChannelService.ACTION_COUPON);
        String issuer = stateValue(p, OpportunityDealChannelService.BLOCK_ISSUER, OpportunityDealChannelService.ACTION_ISSUER);

        // 회신값은 전부 선택. 숫자로 파싱되는 값·비어있지 않은 종목만 기록하고, 다 비어도 회신 완료로 넘어간다.
        // 게스트는 Opportunity 를 읽지 못하므로(2026-08-31 실측 QueryException) 원본 카드 블록을 Worker 에 넘겨 조회 없이 카드를 교체한다.
        List<Object> originalBlocks;
        Object mb = ((Map<String, Object>) p.get('message')).get('blocks');
        if (mb instanceof List<Object>) {
            originalBlocks = (List<Object>) mb;
        }
        apply(build(oppId, replyBy, channelId, ts, parseDecimal(yieldRaw), parseDecimal(appliedFeeRaw), parseDecimal(couponRaw), issuer), originalBlocks);
    }

    /**
     * 회신 반영 공용 진입점 — Slack 카드 [회신 제출]과 Salesforce 화면(DealTermCollabController.submitReply)이 같이 쓴다.
     * 게스트면 이벤트를 발행해 트리거가 갱신하고, 아니면 직접 갱신한다. 이어서 Worker 를 큐에 넣는다.
     * ts 가 있으면(Slack 경로) 그 카드를 "회신 완료"로 교체하고, 없으면(Salesforce 경로) 채널에 회신 완료 카드를 새로 게시한다.
     */
    public static void applyReply(Id oppId, String replyBy, String channelId, String ts,
                                  Decimal yieldVal, Decimal appliedFeeVal, Decimal couponVal, String issuer) {
        apply(build(oppId, replyBy, channelId, ts, yieldVal, appliedFeeVal, couponVal, issuer), null);
    }

    private static Apply build(Id oppId, String replyBy, String channelId, String ts,
                               Decimal yieldVal, Decimal appliedFeeVal, Decimal couponVal, String issuer) {
        Apply a = new Apply();
        a.oppId = oppId; a.replyBy = replyBy; a.channelId = channelId; a.ts = ts;
        a.yieldVal = yieldVal; a.appliedFeeVal = appliedFeeVal; a.couponVal = couponVal; a.issuer = issuer;
        return a;
    }

    private static void apply(Apply a, List<Object> originalBlocks) {
        if (forceEventPath || UserInfo.getUserType() == 'Guest') {
            Database.SaveResult sr = EventBus.publish(new Boni_Slack_Event__e(Event_Type__c = EVENT_APPLY, Payload__c = JSON.serialize(a)));
            if (!sr.isSuccess()) {
                throw new DealTermReplyException('회신 이벤트 발행 실패: ' + sr.getErrors()[0].getMessage());
            }
        } else {
            update buildUpdate(a); // 사용자 컨텍스트 — 직접 갱신
        }
        System.enqueueJob(new Worker(a, originalBlocks));
    }

    /**
     * 원본 카드 블록에서 입력칸(input)·버튼(actions)·'상품팀 회신' 안내 섹션을 제거하고
     * "회신 완료" 섹션을 붙인다 — 게스트가 Opportunity 를 조회하지 않고 카드를 교체하기 위한 변환.
     */
    @TestVisible
    private static List<Object> repliedBlocksFromOriginal(List<Object> originalBlocks, Apply a) {
        List<Object> blocks = new List<Object>();
        for (Object o : originalBlocks) {
            Map<String, Object> b = (Map<String, Object>) o;
            String t = String.valueOf(b.get('type'));
            if (t == 'input' || t == 'actions') {
                continue;
            }
            if (t == 'section' && JSON.serialize(b.get('text')).contains('상품팀 회신')) {
                continue;
            }
            blocks.add(b);
        }
        String vals = '*적용 약정수익률* ' + fmt(a.yieldVal) + '% / *적용 수수료율* ' + fmt(a.appliedFeeVal) + '%';
        blocks.add(new Map<String, Object>{ 'type' => 'section', 'text' => new Map<String, Object>{ 'type' => 'mrkdwn',
            'text' => ':white_check_mark: *회신 완료* · ' + a.replyBy + ' · ' + Datetime.now().format('HH:mm', 'Asia/Seoul')
                + '\n' + vals
                + '\nSalesforce에 반영됐습니다 → <' + URL.getOrgDomainUrl().toExternalForm() + '/' + a.oppId + '|기회 열기>' } });
        return blocks;
    }

    private static String fmt(Decimal d) {
        if (d == null) {
            return '—';
        }
        return String.valueOf(d.stripTrailingZeros().toPlainString());
    }

    /** BoniSlackEventTrigger(Automated Process) 에서 호출 — EVENT_APPLY 페이로드로 Opportunity 갱신. */
    public static void applyFromEvent(Map<String, Object> p) {
        Apply a = (Apply) JSON.deserialize(JSON.serialize(p), Apply.class);
        update buildUpdate(a); // 시스템 컨텍스트 DML (게스트 대신 트리거가 수행)
    }

    private static Opportunity buildUpdate(Apply a) {
        Opportunity opp = new Opportunity(
            Id = a.oppId,
            Product_Team_Reply_By__c = a.replyBy,
            Product_Team_Reply_At__c = Datetime.now()
        );
        if (String.isNotBlank(a.ts)) {
            opp.Slack_Reply_Link__c = OpportunityDealChannelService.buildDeepLink(a.channelId) + '/p' + a.ts.replace('.', '');
        }
        if (a.yieldVal != null) {
            opp.RP_Yield__c = a.yieldVal;
        }
        if (a.appliedFeeVal != null) {
            opp.Fee_Rate__c = a.appliedFeeVal; // 상품팀이 확정한 적용 수수료율
        }
        if (a.couponVal != null) {
            opp.Coupon_Rate__c = a.couponVal;
        }
        if (String.isNotBlank(a.issuer)) {
            opp.Issuer_Name__c = a.issuer.trim();
        }
        return opp;
    }

    /** 회신 1건의 값 묶음 — 이벤트 페이로드이자 Worker 의 상태. */
    public class Apply {
        public Id oppId;
        public String replyBy;
        public String channelId;
        public String ts;
        public Decimal yieldVal;
        public Decimal appliedFeeVal;
        public Decimal couponVal;
        public String issuer;
    }

    public class DealTermReplyException extends Exception {}

    private static Id parseId(String raw) {
        try {
            Id candidate = (Id) raw;
            return candidate.getSobjectType() == Opportunity.SObjectType ? candidate : null;
        } catch (Exception e) {
            return null;
        }
    }

    private static String stateValue(Map<String, Object> p, String blockId, String actionId) {
        try {
            Map<String, Object> values = (Map<String, Object>) ((Map<String, Object>) p.get('state')).get('values');
            Map<String, Object> block = (Map<String, Object>) values.get(blockId);
            Map<String, Object> el = (Map<String, Object>) block.get(actionId);
            Object v = el.get('value');
            return v == null ? null : String.valueOf(v);
        } catch (Exception e) {
            return null;
        }
    }

    private static Decimal parseDecimal(String raw) {
        if (String.isBlank(raw)) {
            return null;
        }
        try {
            return Decimal.valueOf(raw.trim().replace('%', '').replace(',', ''));
        } catch (Exception e) {
            return null;
        }
    }

    /**
     * 콜아웃 담당. Opp 을 읽되 회신값은 들고 온 것으로 덮어써서(트리거 반영 전이어도 정확) 카드를 "회신 완료"로 교체(chat.update).
     * ts 가 없으면(Salesforce 화면 회신) 채널에 회신 완료 카드를 새로 게시하고 그 링크를 Slack_Reply_Link__c 에 남긴다.
     */
    public class Worker implements Queueable, Database.AllowsCallouts {
        private final Apply a;
        private final List<Object> originalBlocks;

        public Worker(Apply a, List<Object> originalBlocks) {
            this.a = a;
            this.originalBlocks = originalBlocks;
        }

        public void execute(QueueableContext ctx) {
            try {
                if (originalBlocks != null && String.isNotBlank(a.ts)) {
                    // Slack 카드 경로(게스트): 조회 없이 원본 블록을 변환해 교체
                    BoniSlackClient.updateBlocks(a.channelId, a.ts, '회신 완료', repliedBlocksFromOriginal(originalBlocks, a));
                    return;
                }
                Opportunity opp = [
                    SELECT Id, Name, Amount, Fee_Rate__c, RP_Maturity_Date__c, RP_Yield__c, Coupon_Rate__c, Issuer_Name__c,
                           Account.Name, Account.Industry, Owner.Name, Primary_Product__r.Name, Primary_Product__r.Family,
                           Primary_Product__r.Default_Fee_Rate__c
                    FROM Opportunity WHERE Id = :a.oppId
                ];
                if (a.yieldVal != null) opp.RP_Yield__c = a.yieldVal;
                if (a.appliedFeeVal != null) opp.Fee_Rate__c = a.appliedFeeVal;
                if (a.couponVal != null) opp.Coupon_Rate__c = a.couponVal;
                if (String.isNotBlank(a.issuer)) opp.Issuer_Name__c = a.issuer.trim();

                List<Object> blocks = OpportunityDealChannelService.buildRepliedCardBlocks(opp, a.replyBy, URL.getOrgDomainUrl().toExternalForm());
                if (String.isNotBlank(a.ts)) {
                    BoniSlackClient.updateBlocks(a.channelId, a.ts, '회신 완료 — ' + opp.Name, blocks);
                } else {
                    String newTs = BoniSlackClient.postBlocks(a.channelId, '회신 완료 — ' + opp.Name, blocks);
                    if (String.isNotBlank(newTs) && newTs != 'null') {
                        update new Opportunity(Id = a.oppId,
                            Slack_Reply_Link__c = OpportunityDealChannelService.buildDeepLink(a.channelId) + '/p' + newTs.replace('.', ''));
                    }
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, '회신 카드 갱신 실패: ' + e.getMessage());
            }
        }
    }
}