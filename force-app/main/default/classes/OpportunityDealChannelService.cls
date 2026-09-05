/**
 * docs/58 Scene 3 — 미팅 로그 저장 시 딜 전용 Slack 비공개 채널을 만들고(RM + 상품팀 담당자),
 * 미팅 요약(LLM 프롬프트 템플릿 Meeting_Summary)과 조건 카드(상품별 입력칸 + 회신 제출)를 게시한 뒤 Opportunity 에 채널 정보를 저장한다.
 * SlackLeadChannelService 의 Opportunity 판. 그 클래스는 건드리지 않는다.
 *
 * - 채널 이름 = {회사명}-{상품명(괄호 제거)} 예: 동진쎄미켐-rp, 휴젤-외화-rp. 중복은 -2, -3 …
 * - 채널 설명(purpose) = Opportunity 링크 → Slack 에서 클릭 한 번에 딜로 이동.
 * - 상품팀 담당자 = Primary_Product__r.Product_Team_Rep__r.Email 로 Slack 사용자 조회(GET users.lookupByEmail —
 *   JSON POST 는 invalid_arguments, 2026-08-28 실측). 담당자를 못 찾아도 채널은 만든다(시연 중단 방지).
 * - Slack 실패 시 Opportunity 는 건드리지 않는다. 회신 처리는 DealTermReplyHandler.
 */
public with sharing class OpportunityDealChannelService implements Queueable, Database.AllowsCallouts {

    public static final String ACTION_REPLY = 'deal_term_reply';
    public static final String BLOCK_YIELD = 'rp_yield';
    public static final String BLOCK_COUPON = 'coupon_rate';
    public static final String BLOCK_ISSUER = 'issuer';
    public static final String ACTION_YIELD = 'rp_yield_in';
    public static final String ACTION_COUPON = 'coupon_rate_in';
    public static final String ACTION_ISSUER = 'issuer_in';
    public static final String BLOCK_APPLIED_FEE = 'applied_fee';
    public static final String ACTION_APPLIED_FEE = 'applied_fee_in';
    // 승인/반려/매니저 결재 버튼
    public static final String ACTION_APPROVAL_APPROVE = 'deal_approval_approve';
    public static final String ACTION_APPROVAL_REJECT  = 'deal_approval_reject';
    public static final String ACTION_APPROVAL_MANAGER = 'deal_approval_manager';
    // 판매 승인 요청(심사 Case) 입력폼 — 계약 기간·사유를 받아 [판매 승인 요청(Case 생성)] 으로 심사 Case 를 만든다.
    public static final String ACTION_CASE_CREATE = 'deal_case_create';
    public static final String BLOCK_TERM_MONTHS = 'case_term_months';
    public static final String ACTION_TERM_MONTHS = 'case_term_months_in';
    public static final String BLOCK_CASE_REASON = 'case_reason';
    public static final String ACTION_CASE_REASON = 'case_reason_in';

    private static final String NC = 'callout:Slack';
    private static final String DEFAULT_WORKSPACE_URL = 'https://slack-demo-39110.enterprise.slack.com';
    private static final Integer TIMEOUT_MS = 20000;
    private static final Integer MAX_NAME_RETRIES = 9;
    private static final Integer SUMMARY_MAX = 2500;
    @TestVisible private static Boolean bypass = false;

    private final List<Id> oppIds;
    public OpportunityDealChannelService(List<Id> oppIds) { this.oppIds = oppIds; }

    /** 트리거 진입점: 미팅 로그가 바뀌었고 아직 채널이 없는 기회만 큐에 넣는다. */
    public static void enqueueForOpportunities(List<Opportunity> newOpps, Map<Id, Opportunity> oldMap) {
        if (bypass) {
            return;
        }
        List<Id> targets = new List<Id>();
        for (Opportunity opp : newOpps) {
            Opportunity old = oldMap == null ? null : oldMap.get(opp.Id);
            Boolean logChanged = old == null ? String.isNotBlank(opp.Meeting_Log__c) : old.Meeting_Log__c != opp.Meeting_Log__c;
            if (logChanged && String.isNotBlank(opp.Meeting_Log__c) && String.isBlank(opp.Slack_Channel_ID__c)) {
                targets.add(opp.Id);
            }
        }
        if (!targets.isEmpty() && Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
            System.enqueueJob(new OpportunityDealChannelService(targets));
        }
    }

    public void execute(QueueableContext ctx) {
        createChannels(oppIds);
    }

    /** 이번 실행에서 살아있는 기존 채널에 조건 카드를 재게시한 기회 Id (createChannels 호출자가 메시지 분기에 사용). */
    public static Set<Id> resentIds = new Set<Id>();

    /** 동기 본체. 채널 생성에 성공한 기회 Id 목록을 돌려준다(카드만 재게시한 건 resentIds 에 기록). */
    public static List<Id> createChannels(List<Id> ids) {
        List<Id> done = new List<Id>();
        List<Opportunity> opps = [
            SELECT Id, Name, Amount, Fee_Rate__c, RP_Yield__c, Pending_Yield__c, RP_Maturity_Date__c, Meeting_Log__c, Slack_Channel_ID__c,
                   Account.Name, Account.Industry, Account.AnnualRevenue, Account.Relationship_Grade__c,
                   Account.Priority_Rationale_Summary__c, Owner.Email, Owner.Name,
                   Primary_Product__r.Name, Primary_Product__r.Family, Primary_Product__r.Default_Fee_Rate__c,
                   Primary_Product__r.Product_Team_Rep__r.Email, Primary_Product__r.Product_Team_Rep__r.Name,
                   (SELECT Id, Sanitized_Content__c FROM Meeting_Notes__r ORDER BY CreatedDate DESC LIMIT 1)
            FROM Opportunity
            WHERE Id IN :ids
        ];
        // 판매 승인 요청 Case 를 기회별로 미리 모아 카드에 실을 정보를 채운다(상품팀은 Slack 에서 그대로 확인).
        // Case.Opportunity__c 는 커스텀 룩업이라 with sharing 컨텍스트에서 FLS 제한을 받을 수 있으므로
        // without sharing 이너 클래스를 통해 조회한다.
        Map<Id, Case> caseByOpp = new CaseReader().queryByOppIds(ids);
        List<Opportunity> updates = new List<Opportunity>();
        String runningEmail = UserInfo.getUserEmail();
        String orgUrl = URL.getOrgDomainUrl().toExternalForm();

        for (Opportunity opp : opps) {
            try {
                // 이미 살아있는 채널이 있으면 재생성하지 않고, 현재 값으로 조건 카드만 같은 채널에 다시 게시한다
                // (2026-08-30 결정: 수수료 수정 후 재전달 시 상품팀이 알 수 있게). 요약·초대는 반복하지 않는다.
                // 아카이브·삭제된 채널이면 새로 판다(아래에서 필드 덮어씀).
                if (String.isNotBlank(opp.Slack_Channel_ID__c) && !isChannelDead(opp.Slack_Channel_ID__c)) {
                    postBlocks(opp.Slack_Channel_ID__c, '조건 검토 요청(재전송) — ' + opp.Name, buildTermCardBlocks(opp, caseByOpp.get(opp.Id)));
                    resentIds.add(opp.Id);
                    continue;
                }
                String channelId = createChannel(deriveChannelName(opp));

                List<String> emails = new List<String>();
                addEmail(emails, runningEmail);
                addEmail(emails, opp.Owner?.Email);
                List<String> userIds = new List<String>();
                for (String e : emails) {
                    String u = lookupUserId(e);
                    if (u != null) {
                        userIds.add(u);
                    }
                }
                String repEmail = opp.Primary_Product__r?.Product_Team_Rep__r?.Email;
                Boolean repInvited = false;
                if (String.isNotBlank(repEmail)) {
                    String u = lookupUserId(repEmail);
                    if (u != null) {
                        userIds.add(u);
                        repInvited = true;
                    }
                }
                if (!userIds.isEmpty()) {
                    invite(channelId, userIds);
                }
                setPurpose(channelId, '<' + orgUrl + '/' + opp.Id + '|' + opp.Name + '>');
                postText(channelId, buildSummaryText(opp, repInvited, meetingSummary(opp)));
                postBlocks(channelId, '조건 검토 요청 — ' + opp.Name, buildTermCardBlocks(opp, caseByOpp.get(opp.Id)));
                // 표준 "Slack Channel" 카드에 이 채널이 뜨도록 레코드에 연결(실패해도 채널 생성엔 영향 없음).
                OpportunitySlackLinkService.link(channelId, opp.Id);

                updates.add(new Opportunity(Id = opp.Id, Slack_Channel_ID__c = channelId, Slack_Channel_Link__c = buildDeepLink(channelId)));
                done.add(opp.Id);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, '딜 채널 생성 실패 ' + opp.Id + ': ' + e.getMessage());
            }
        }
        if (!updates.isEmpty()) {
            bypass = true;
            try {
                update as user updates;
            } finally {
                bypass = false;
            }
        }
        return done;
    }

    // ─── 카드 ─────────────────────────────────────────────────────────

    /** 기존 호출부 호환용 — Case 정보 없이(정상 딜) 조건 카드를 만든다. */
    public static List<Object> buildTermCardBlocks(Opportunity opp) {
        return buildTermCardBlocks(opp, null);
    }

    public static List<Object> buildTermCardBlocks(Opportunity opp, Case approvalCase) {
        List<Object> blocks = new List<Object>();
        blocks.add(header(':bell: 조건 검토 요청 · ' + productGroupLabel(opp)));
        blocks.add(contextBlock(headerContext(opp) + '  ·  요청 ' + Datetime.now().format('M/d(E) HH:mm', 'Asia/Seoul')));
        blocks.add(section(':moneybag: *수수료 조건*'));
        blocks.add(dealFieldsSection(opp));
        blocks.add(computedSection(opp));
        String cust = customerContext(opp);
        if (String.isNotBlank(cust)) {
            blocks.add(contextBlock(cust));
        }
        // 승인 버튼: 딜 조건 카드엔 항상 붙인다(약정수익률 상한 이하·판매 승인 요청 Case 없어도).
        // Case 정보 섹션은 Case 가 있을 때만.
        blocks.add(new Map<String, Object>{ 'type' => 'divider' });
        if (approvalCase != null) {
            blocks.add(caseInfoSection(approvalCase));
        }
        blocks.add(approvalButtons(opp.Id));
        return blocks;
    }

    private static Map<String, Object> caseInfoSection(Case c) {
        List<String> lines = new List<String>{ ':card_index_dividers: *판매 승인 요청*' };
        if (String.isNotBlank(c.Owner?.Name)) {
            lines.add('*담당자* ' + c.Owner.Name);
        }
        if (String.isNotBlank(c.Description)) {
            lines.add('*사유* ' + c.Description);
        }
        return new Map<String, Object>{ 'type' => 'section', 'text' => mrkdwn(String.join(lines, '\n')) };
    }

    private static Map<String, Object> approvalButtons(Id oppId) {
        String v = String.valueOf(oppId);
        List<Object> elements = new List<Object>();
        elements.add(new Map<String, Object>{
            'type' => 'button', 'text' => plain('승인'),
            'style' => 'primary', 'action_id' => ACTION_APPROVAL_APPROVE, 'value' => v
        });
        elements.add(new Map<String, Object>{
            'type' => 'button', 'text' => plain('반려'),
            'style' => 'danger', 'action_id' => ACTION_APPROVAL_REJECT, 'value' => v
        });
        elements.add(new Map<String, Object>{
            'type' => 'button', 'text' => plain('매니저 결재'),
            'action_id' => ACTION_APPROVAL_MANAGER, 'value' => v
        });
        return new Map<String, Object>{ 'type' => 'actions', 'elements' => elements };
    }

    /** 회신 후 카드: 입력칸 제거, 적용 약정수익률·적용 수수료율·회신자·기회 링크 표시(DealTermReplyHandler 가 chat.update 로 교체). */
    public static List<Object> buildRepliedCardBlocks(Opportunity opp, String replyBy, String orgBaseUrl) {
        List<Object> blocks = new List<Object>();
        blocks.add(header(':bell: 조건 검토 요청 · ' + productGroupLabel(opp)));
        blocks.add(contextBlock(headerContext(opp)));
        blocks.add(section(':moneybag: *수수료 조건*'));
        blocks.add(dealFieldsSection(opp));
        blocks.add(computedSection(opp));
        blocks.add(new Map<String, Object>{ 'type' => 'divider' });
        String vals = '*적용 약정수익률* ' + fmt(opp.RP_Yield__c) + '% / *적용 수수료율* ' + fmt(opp.Fee_Rate__c) + '%';
        blocks.add(section(':white_check_mark: *회신 완료* · ' + replyBy + ' · ' + Datetime.now().format('HH:mm', 'Asia/Seoul')
            + '\n' + vals
            + '\nSalesforce에 반영됐습니다 → <' + orgBaseUrl + '/' + opp.Id + '|기회 열기>'));
        return blocks;
    }

    // ─── 카드 조각 ─────────────────────────────────────────────────────

    /** 헤더 밑 한 줄: *고객사* · 업종(축약) · 상품 · RM 이름. */
    private static String headerContext(Opportunity opp) {
        List<String> parts = new List<String>{ '*' + (opp.Account?.Name ?? opp.Name) + '*' };
        String ind = shortIndustry(opp.Account?.Industry);
        if (String.isNotBlank(ind)) {
            parts.add(ind);
        }
        parts.add(opp.Primary_Product__r?.Name ?? '—');
        parts.add('RM ' + (opp.Owner?.Name ?? '—'));
        return String.join(parts, '  ·  ');
    }

    /** 수수료 조건을 2열 fields 로(미팅화면 패널과 동일): 거래금액·제안수익률·수수료율·기간. */
    /** 카드 표시용 제안 수익률: 상한 초과로 승인 대기 중인 값(Pending_Yield__c)이 있으면 그것을, 없으면 적용값(RP_Yield__c). */
    private static Decimal proposedYield(Opportunity opp) {
        return opp.Pending_Yield__c != null ? opp.Pending_Yield__c : opp.RP_Yield__c;
    }

    private static Map<String, Object> dealFieldsSection(Opportunity opp) {
        Integer days = termDays(opp);
        List<Object> fields = new List<Object>{
            mrkdwn('*거래 금액*\n' + (opp.Amount == null ? '—' : fmtKrw(opp.Amount))),
            mrkdwn('*제안 수익률*\n' + (proposedYield(opp) == null ? '—' : fmt(proposedYield(opp)) + '%')),
            mrkdwn('*수수료율*\n' + (opp.Fee_Rate__c == null ? '—' : fmt(opp.Fee_Rate__c) + '%')),
            mrkdwn('*기간*\n' + (days == null ? '—' : days + '일'))
        };
        return new Map<String, Object>{ 'type' => 'section', 'fields' => fields };
    }

    /** 계산 결과(365일 단리): 증권사 수익만 표시(2026-09-01 요구로 상대기업 순이익·순수익률·증권사 수익률 제거). */
    private static Map<String, Object> computedSection(Opportunity opp) {
        Decimal principal = opp.Amount == null ? 0 : opp.Amount;
        Decimal f = opp.Fee_Rate__c == null ? 0 : opp.Fee_Rate__c;
        Integer days = termDays(opp);
        Integer d = (days == null || days < 0) ? 0 : days;
        Decimal firm = principal * f / 100 * d / 365;
        List<Object> fields = new List<Object>{
            mrkdwn('*증권사 수익*\n' + fmtKrw(firm.setScale(0)))
        };
        return new Map<String, Object>{ 'type' => 'section', 'fields' => fields };
    }

    /** 만기일 → 오늘부터 잔여 일수. 만기 없으면 null. */
    private static Integer termDays(Opportunity opp) {
        return opp.RP_Maturity_Date__c == null ? null : Date.today().daysBetween(opp.RP_Maturity_Date__c);
    }

    /** 긴 업종명을 카드용으로 축약(쉼표/가운뎃점 앞 첫 토막, 그래도 길면 자름). */
    private static String shortIndustry(String ind) {
        if (String.isBlank(ind)) {
            return '';
        }
        String first = ind.split('[,·/]')[0].trim();
        if (first.length() < 4) {
            first = ind.trim();
        }
        return first.abbreviate(14);
    }

    /** 관계등급·연매출·우선순위 요약 중 있는 것만 한 줄로. 없으면 빈 문자열. */
    private static String customerContext(Opportunity opp) {
        List<String> parts = new List<String>();
        if (String.isNotBlank(opp.Account?.Relationship_Grade__c)) {
            parts.add('관계등급 ' + opp.Account.Relationship_Grade__c);
        }
        if (opp.Account?.AnnualRevenue != null) {
            parts.add('연매출 ' + fmtKrw(opp.Account.AnnualRevenue));
        }
        if (String.isNotBlank(opp.Account?.Priority_Rationale_Summary__c)) {
            parts.add(opp.Account.Priority_Rationale_Summary__c);
        }
        return parts.isEmpty() ? '' : ':office: ' + String.join(parts, '  ·  ');
    }

    /**
     * 상품팀 전달용 미팅 요약 3줄. 기존 프롬프트 템플릿 Meeting_Summary(마스킹본 근거, docs 27/28)를 그대로 호출한다.
     * 입력: 최신 Meeting_Note__c(마스킹본) + 미팅 로그. 노트가 없거나 생성 실패면 null → 헤더만 있는 폴백.
     * summaryForTest 가 세팅되면 LLM 을 건너뛰고 그 값을 반환(테스트에서 콜아웃 회피).
     */
    @TestVisible private static String summaryForTest;
    private static final String SUMMARY_TEMPLATE = 'Meeting_Summary';

    private static String meetingSummary(Opportunity opp) {
        if (summaryForTest != null) {
            return summaryForTest;
        }
        List<Meeting_Note__c> notes = opp.Meeting_Notes__r;
        if (notes == null || notes.isEmpty() || String.isBlank(notes[0].Sanitized_Content__c)) {
            return null;
        }
        try {
            ConnectApi.EinsteinPromptTemplateGenerationsInput req = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
            req.isPreview = false;
            // applicationName 이 없으면 게이트웨이가 'Failed to generate ... response' 로 실패한다(2026-08-29 실측).
            ConnectApi.EinsteinLlmAdditionalConfigInput cfg = new ConnectApi.EinsteinLlmAdditionalConfigInput();
            cfg.applicationName = 'PromptTemplateGenerationsInvocable';
            cfg.enablePiiMasking = false; // 입력이 이미 마스킹본(Sanitized_Content__c)이라 이중 마스킹 방지
            req.additionalConfig = cfg;
            ConnectApi.WrappedValue note = new ConnectApi.WrappedValue();
            note.value = new Map<String, Object>{ 'id' => notes[0].Id };
            ConnectApi.WrappedValue log = new ConnectApi.WrappedValue();
            log.value = String.isBlank(opp.Meeting_Log__c) ? '' : opp.Meeting_Log__c.abbreviate(SUMMARY_MAX);
            req.inputParams = new Map<String, ConnectApi.WrappedValue>{ 'Input:MeetingNote' => note, 'Input:MeetingLog' => log };

            ConnectApi.EinsteinPromptTemplateGenerationsRepresentation res =
                ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(SUMMARY_TEMPLATE, req);
            if (res != null && res.generations != null && !res.generations.isEmpty()) {
                String text = res.generations[0].text;
                return String.isBlank(text) ? null : text.trim();
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '미팅 요약 생성 실패 ' + opp.Id + ': ' + e.getMessage());
        }
        return null;
    }

    private static Boolean isBond(Opportunity opp) {
        return opp.Primary_Product__r?.Family == '채권';
    }

    /** 헤더·회신 라벨용 상품군 이름. 채권→회사채, 그 외는 Family, 없으면 상품명. */
    private static String productGroupLabel(Opportunity opp) {
        String fam = opp.Primary_Product__r?.Family;
        if (fam == '채권') {
            return '회사채';
        }
        if (String.isNotBlank(fam)) {
            return fam;
        }
        return opp.Primary_Product__r?.Name ?? '딜';
    }

    private static String buildSummaryText(Opportunity opp, Boolean repInvited, String summary) {
        String rep = opp.Primary_Product__r?.Product_Team_Rep__r?.Name;
        String head = ':memo: *미팅 요약* | ' + (opp.Account?.Name ?? opp.Name) + ' | RM ' + (opp.Owner?.Name ?? '')
            + (repInvited ? ' | 상품팀 ' + rep : ' | :warning: 상품팀 담당자를 Slack에서 찾지 못해 초대하지 못했습니다');
        String body = String.isNotBlank(summary)
            ? summary
            : '_미팅 요약을 생성하지 못했습니다 — 아래 조건 카드를 참고해 주세요._';
        return head + '\n' + body;
    }

    // ─── Slack ────────────────────────────────────────────────────────

    private static String createChannel(String name) {
        Map<String, Object> body = new Map<String, Object>{ 'name' => name, 'is_private' => true };
        Map<String, Object> r = postJson('/conversations.create', body);
        Integer attempt = 2;
        while (r.get('ok') != true && String.valueOf(r.get('error')) == 'name_taken' && attempt <= MAX_NAME_RETRIES + 1) {
            body.put('name', truncate(name + '-' + attempt));
            r = postJson('/conversations.create', body);
            attempt++;
        }
        if (r.get('ok') != true) {
            throw new DealChannelException('채널 생성 실패: ' + r.get('error'));
        }
        return String.valueOf(((Map<String, Object>) r.get('channel')).get('id'));
    }

    /**
     * 저장된 채널이 아카이브됐거나 삭제됐으면 true(→ 새로 생성). 살아있거나 확인 실패면 false(기존 유지).
     * 확인 실패 시 false 로 두어 불필요한 중복 채널 생성을 막는다.
     */
    @TestVisible
    private static Boolean isChannelDead(String channelId) {
        if (String.isBlank(channelId)) {
            return true;
        }
        try {
            Map<String, Object> r = getForm('/conversations.info?channel=' + EncodingUtil.urlEncode(channelId, 'UTF-8'));
            if (r.get('ok') == true) {
                Map<String, Object> ch = (Map<String, Object>) r.get('channel');
                return ch != null && ch.get('is_archived') == true;
            }
            String err = String.valueOf(r.get('error'));
            return err == 'channel_not_found';
        } catch (Exception e) {
            return false;
        }
    }

    private static String lookupUserId(String email) {
        Map<String, Object> r = getForm('/users.lookupByEmail?email=' + EncodingUtil.urlEncode(email, 'UTF-8'));
        if (r.get('ok') == true) {
            Map<String, Object> userNode = (Map<String, Object>) r.get('user');
            return userNode == null ? null : String.valueOf(userNode.get('id'));
        }
        if (String.valueOf(r.get('error')) == 'users_not_found') {
            return null;
        }
        throw new DealChannelException('사용자 조회 실패(' + email + '): ' + r.get('error'));
    }

    private static void invite(String channelId, List<String> userIds) {
        Map<String, Object> r = postJson('/conversations.invite', new Map<String, Object>{ 'channel' => channelId, 'users' => String.join(userIds, ',') });
        String err = String.valueOf(r.get('error'));
        if (r.get('ok') != true && err != 'already_in_channel' && err != 'cant_invite_self') {
            throw new DealChannelException('초대 실패: ' + err);
        }
    }

    /** 채널 설명에 레코드 링크를 넣어 Slack 에서 딜을 찾을 수 있게 한다. 실패해도 진행. */
    private static void setPurpose(String channelId, String purpose) {
        try {
            postJson('/conversations.setPurpose', new Map<String, Object>{ 'channel' => channelId, 'purpose' => purpose.abbreviate(250) });
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'setPurpose 실패(무시): ' + e.getMessage());
        }
    }

    private static void postText(String channelId, String text) {
        Map<String, Object> r = postJson('/chat.postMessage', new Map<String, Object>{ 'channel' => channelId, 'text' => text });
        if (r.get('ok') != true) {
            throw new DealChannelException('요약 게시 실패: ' + r.get('error'));
        }
    }

    private static void postBlocks(String channelId, String fallback, List<Object> blocks) {
        Map<String, Object> r = postJson('/chat.postMessage', new Map<String, Object>{ 'channel' => channelId, 'text' => fallback, 'blocks' => blocks });
        if (r.get('ok') != true) {
            throw new DealChannelException('조건 카드 게시 실패: ' + r.get('error'));
        }
    }

    private static Map<String, Object> postJson(String path, Map<String, Object> body) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(NC + path);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json; charset=utf-8');
        req.setTimeout(TIMEOUT_MS);
        req.setBody(JSON.serialize(body));
        return send(req);
    }

    private static Map<String, Object> getForm(String pathWithQuery) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(NC + pathWithQuery);
        req.setMethod('GET');
        req.setHeader('Content-Type', 'application/x-www-form-urlencoded');
        req.setTimeout(TIMEOUT_MS);
        return send(req);
    }

    private static Map<String, Object> send(HttpRequest req) {
        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
            throw new DealChannelException('Slack HTTP ' + res.getStatusCode());
        }
        return (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
    }

    // ─── 이름·링크·포맷 ─────────────────────────────────────────────────

    public static String buildDeepLink(String channelId) {
        String base = DEFAULT_WORKSPACE_URL;
        Slack__mdt org = Slack__mdt.getInstance('Slack_Org');
        if (org != null && String.isNotBlank(org.Org_Url__c)) {
            base = org.Org_Url__c;
        }
        return base.removeEnd('/') + '/archives/' + channelId;
    }

    /** {회사명}-{상품명(괄호 내용 제거)}. 예: 동진쎄미켐-rp, 휴젤-외화-rp, 고영-rp-30일물. */
    @TestVisible
    private static String deriveChannelName(Opportunity opp) {
        String company = opp.Account?.Name;
        String product = opp.Primary_Product__r?.Name;
        if (String.isNotBlank(product)) {
            product = product.replaceAll('\\([^)]*\\)', ' ').trim();
        }
        List<String> parts = new List<String>();
        if (String.isNotBlank(company)) {
            parts.add(company);
        }
        if (String.isNotBlank(product)) {
            parts.add(product);
        }
        if (parts.isEmpty()) {
            parts.add(opp.Name);
        }
        return truncate(normalize(String.join(parts, ' ')));
    }

    private static String normalize(String raw) {
        String n = raw.trim().toLowerCase()
            .replaceAll('[\\s.]+', '-')
            .replaceAll('[^\\p{L}\\p{N}_-]', '')
            .replaceAll('-{2,}', '-')
            .removeStart('-').removeEnd('-');
        return String.isBlank(n) ? 'deal' : n;
    }

    private static String truncate(String s) {
        return s.length() > 80 ? s.substring(0, 80).removeEnd('-') : s;
    }

    private static void addEmail(List<String> emails, String email) {
        if (String.isBlank(email)) {
            return;
        }
        String e = email.trim().toLowerCase();
        if (!emails.contains(e)) {
            emails.add(e);
        }
    }

    private static String fmt(Decimal d) {
        return d == null ? '' : d.setScale(2).toPlainString().replaceAll('\\.?0+$', '');
    }

    private static String fmtKrw(Decimal amt) {
        if (amt == null) {
            return '—';
        }
        if (amt.abs() >= 100000000) {
            return (amt / 100000000).setScale(1).toPlainString().replaceAll('\\.0$', '') + '억 원';
        }
        return amt.setScale(0).format() + '원';
    }

    /** 퍼센트 2자리 고정(계산 결과용). 예: 3.68% */
    private static String fmtPct(Decimal d) {
        return (d == null ? Decimal.valueOf(0) : d).setScale(2).toPlainString() + '%';
    }

    private static Map<String, Object> header(String t) {
        return new Map<String, Object>{ 'type' => 'header', 'text' => plain(t.abbreviate(150)) };
    }

    private static Map<String, Object> section(String md) {
        return new Map<String, Object>{ 'type' => 'section', 'text' => mrkdwn(md) };
    }

    private static Map<String, Object> mrkdwn(String md) {
        return new Map<String, Object>{ 'type' => 'mrkdwn', 'text' => md };
    }

    private static Map<String, Object> contextBlock(String md) {
        return new Map<String, Object>{ 'type' => 'context', 'elements' => new List<Object>{ mrkdwn(md) } };
    }

    private static Map<String, Object> plain(String t) {
        return new Map<String, Object>{ 'type' => 'plain_text', 'text' => t };
    }

    public class DealChannelException extends Exception {}

    /** Case.Opportunity__c FLS 를 우회하기 위해 without sharing 으로 조회. */
    private without sharing class CaseReader {
        public Map<Id, Case> queryByOppIds(List<Id> oppIds) {
            Map<Id, Case> result = new Map<Id, Case>();
            for (Case c : [
                SELECT Id, Opportunity__c, Opportunity__r.Name, Account.Name, Owner.Name,
                       Agreed_Yield_Rate__c, Contract_Term_Months__c, Description
                FROM Case WHERE Opportunity__c IN :oppIds ORDER BY CreatedDate ASC
            ]) {
                result.put(c.Opportunity__c, c);
            }
            return result;
        }
    }
}