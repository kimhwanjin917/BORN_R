/**
 * Scene 3 · CASE B — 매니저 승인 흐름의 진입 오케스트레이션 (상품팀 담당자가 Case에서 클릭하는 "딸깍" 2개).
 *
 *  딸깍① requestManagerApproval(caseId)
 *    - 상품팀 전용 Slack 채널(이름=Case No. 기반)을 확보(없으면 생성·상품팀 초대)
 *    - 이미 만들어진 확정조건서 PDF(RpTermConfirmController.findLatestTermPdfId)를 채널에 첨부
 *    - 승인 카드([승인]/[반려]) 게시 — 버튼 value = 연결된 Opportunity Id (기존 BoniSlackEventHandler 라우팅 재사용)
 *    - Case 를 Approval Process(Deal_Manager_Approval)에 제출(DealApprovalHandler.submitForApproval)
 *
 *  딸깍② sendResultToRM(caseId)
 *    - Case 가 '승인' 상태인지 확인
 *    - RM(연결된 Opportunity 의 Owner)에게 Slack DM 으로 승인 완료 통보 + 확정조건서 PDF 전달
 *
 * 컨텍스트: 두 메서드 모두 상품팀 담당자(실사용자) 컨텍스트에서 LWC 퀵액션이 호출한다.
 *   실사용자라 표준오브젝트 DML·Approval·VF/콜아웃이 모두 가능(게스트 우회 불필요).
 *   콜아웃(Slack) → DML 순서를 지켜 "uncommitted work pending" 을 피한다.
 *
 * 재사용: RpTermConfirmController(PDF 위치), SlackProposalShareService(PDF 공유),
 *         BoniSlackClient(게시·DM), DealApprovalHandler(승인 제출), OpportunityDealChannelService(상수·딥링크).
 */
public with sharing class DealApprovalService {

    private static final String NC = 'callout:Slack';
    private static final Integer TIMEOUT_MS = 20000;

    public class DealApprovalServiceException extends Exception {}

    /** LWC 로 돌려줄 결과. */
    public class Result {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String message;
        @AuraEnabled public String channelId;
        public Result() { this.success = false; }
    }

    // ─── 딸깍① 매니저 승인 요청 ─────────────────────────────────────────

    @AuraEnabled
    public static Result requestManagerApproval(Id caseId) {
        Result r = new Result();
        if (caseId == null) { r.message = 'Case 를 찾을 수 없습니다.'; return r; }
        Case c = loadCase(caseId);
        if (c == null) { r.message = 'Case 를 찾을 수 없거나 접근 권한이 없습니다.'; return r; }
        if (c.Opportunity__c == null) { r.message = '이 Case 에 연결된 영업기회(Opportunity__c)가 없습니다.'; return r; }

        // 1) 상품팀 채널 확보 (콜아웃) — 없으면 생성·초대. 모든 콜아웃을 DML 앞에서 끝낸다.
        String channelId = c.Deal_Slack_Channel__c;
        try {
            if (String.isBlank(channelId)) {
                channelId = createTeamChannel(c);
            }
        } catch (Exception e) {
            r.message = '상품팀 Slack 채널 생성 실패: ' + e.getMessage();
            return r;
        }

        // 2) 확정조건서 PDF 공유 (있으면) — 실패해도 승인 흐름은 계속.
        Id pdfDocId = safePdfId(c.Opportunity__c);
        if (pdfDocId != null) {
            try {
                SlackProposalShareService.shareContentDocumentToChannel(pdfDocId, channelId);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, '확정조건서 PDF 공유 실패(무시): ' + e.getMessage());
            }
        }

        // 3) 승인 카드 게시 (콜아웃)
        try {
            BoniSlackClient.postBlocks(channelId, '매니저 승인 요청 — Case ' + c.CaseNumber,
                buildApprovalCardBlocks(c, pdfDocId != null));
        } catch (Exception e) {
            r.message = '승인 카드 게시 실패: ' + e.getMessage();
            return r;
        }

        // 4) DML: 채널 id 저장 + Approval Process 제출 (콜아웃 이후)
        try {
            if (c.Deal_Slack_Channel__c != channelId) {
                update as user new Case(Id = caseId, Deal_Slack_Channel__c = channelId);
            }
            DealApprovalHandler.submitForApproval(caseId, '상품팀 ' + UserInfo.getName() + ' 매니저 승인 요청');
        } catch (Exception e) {
            r.message = '승인 제출 실패: ' + e.getMessage();
            return r;
        }

        r.success = true;
        r.channelId = channelId;
        r.message = '매니저 승인 요청을 상품팀 채널에 올리고 승인 프로세스에 제출했습니다.';
        return r;
    }

    // ─── 딸깍② RM 에게 승인 결과 전달 ───────────────────────────────────

    @AuraEnabled
    public static Result sendResultToRM(Id caseId) {
        Result r = new Result();
        if (caseId == null) { r.message = 'Case 를 찾을 수 없습니다.'; return r; }
        Case c = loadCase(caseId);
        if (c == null) { r.message = 'Case 를 찾을 수 없거나 접근 권한이 없습니다.'; return r; }
        if (c.Approval_Status__c != DealApprovalHandler.STATUS_APPROVED) {
            r.message = '아직 승인되지 않았습니다(현재: ' + c.Approval_Status__c + '). 매니저 승인 후 다시 시도하세요.';
            return r;
        }
        String rmEmail = c.Opportunity__r == null || c.Opportunity__r.Owner == null ? null : c.Opportunity__r.Owner.Email;
        if (String.isBlank(rmEmail)) { r.message = 'RM(영업기회 소유자) 이메일을 찾을 수 없습니다.'; return r; }

        // RM Slack DM 통보 (콜아웃)
        String dmChannel;
        try {
            String rmSlackId = BoniSlackClient.lookupUserIdByEmail(rmEmail);
            if (String.isBlank(rmSlackId)) { r.message = 'RM 의 Slack 사용자를 찾지 못했습니다: ' + rmEmail; return r; }
            dmChannel = BoniSlackClient.openDm(rmSlackId);
            BoniSlackClient.postBlocks(dmChannel,
                '조건 승인 완료 — ' + (c.Opportunity__r != null ? c.Opportunity__r.Name : c.CaseNumber),
                buildRmResultBlocks(c));
        } catch (Exception e) {
            r.message = 'RM 통보 실패: ' + e.getMessage();
            return r;
        }

        // 확정조건서 PDF 전달 (있으면) — 실패해도 통보는 성공으로 본다.
        Id pdfDocId = safePdfId(c.Opportunity__c);
        if (pdfDocId != null) {
            try {
                SlackProposalShareService.shareContentDocumentToChannel(pdfDocId, dmChannel);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'RM 확정조건서 전달 실패(무시): ' + e.getMessage());
            }
        }

        r.success = true;
        r.channelId = dmChannel;
        r.message = 'RM 에게 승인 결과와 확정 조건서를 전달했습니다.';
        return r;
    }

    // ─── 조회 ───────────────────────────────────────────────────────────

    private static Case loadCase(Id caseId) {
        List<Case> cs = [
            SELECT Id, CaseNumber, Opportunity__c, Deal_Slack_Channel__c, Approval_Status__c,
                   Opportunity__r.Name, Opportunity__r.Owner.Email, Opportunity__r.Owner.Name,
                   Opportunity__r.Primary_Product__r.Product_Team_Rep__r.Email
            FROM Case
            WHERE Id = :caseId
            WITH USER_MODE
            LIMIT 1
        ];
        return cs.isEmpty() ? null : cs[0];
    }

    /** 확정조건서 PDF 문서Id — 접근 불가·미존재면 null(흐름은 계속). */
    private static Id safePdfId(Id opportunityId) {
        try {
            return RpTermConfirmController.findLatestTermPdfId(opportunityId);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, '확정조건서 PDF 조회 실패(무시): ' + e.getMessage());
            return null;
        }
    }

    // ─── 카드 블록 ──────────────────────────────────────────────────────

    /** 승인 카드: 헤더 + 요청자·시각 + 안내/딜 링크 + [승인]/[반려](value=Opportunity Id, 기존 라우팅 재사용). */
    @TestVisible
    private static List<Object> buildApprovalCardBlocks(Case c, Boolean hasPdf) {
        String orgUrl = URL.getOrgDomainUrl().toExternalForm();
        String requestedAt = Datetime.now().format('M/d(E) HH:mm', 'Asia/Seoul');
        String oppName = c.Opportunity__r != null ? c.Opportunity__r.Name : ('Case ' + c.CaseNumber);
        List<Object> blocks = new List<Object>();
        blocks.add(header(':lock: 매니저 승인 요청 · Case ' + c.CaseNumber));
        blocks.add(contextBlock('요청자 *' + UserInfo.getName() + '*  ·  ' + requestedAt + (hasPdf ? '  ·  :page_facing_up: 확정조건서 첨부' : '')));
        blocks.add(section('상품팀이 *' + oppName + '* 딜 조건에 대해 매니저 승인을 요청했습니다.\n'
            + '첨부된 확정조건서를 확인하고 승인 또는 반려해 주세요.\n'
            + ':link: <' + orgUrl + '/' + c.Opportunity__c + '|Salesforce에서 딜 열기>'));
        blocks.add(new Map<String, Object>{
            'type' => 'actions', 'block_id' => 'deal_approval_decision',
            'elements' => new List<Object>{
                button(OpportunityDealChannelService.ACTION_APPROVAL_APPROVE, '승인', 'primary', String.valueOf(c.Opportunity__c)),
                button(OpportunityDealChannelService.ACTION_APPROVAL_REJECT, '반려', 'danger', String.valueOf(c.Opportunity__c))
            }
        });
        return blocks;
    }

    /** RM 통보 카드: 승인 완료 안내 + 딜 링크. */
    @TestVisible
    private static List<Object> buildRmResultBlocks(Case c) {
        String orgUrl = URL.getOrgDomainUrl().toExternalForm();
        String oppName = c.Opportunity__r != null ? c.Opportunity__r.Name : ('Case ' + c.CaseNumber);
        List<Object> blocks = new List<Object>();
        blocks.add(header(':white_check_mark: 조건 승인 완료'));
        blocks.add(section('*' + oppName + '* 딜 조건이 매니저 승인되었습니다. 확정 조건서를 전달드립니다.\n'
            + ':link: <' + orgUrl + '/' + c.Opportunity__c + '|딜 열기>'));
        return blocks;
    }

    private static Map<String, Object> button(String actionId, String text, String style, String value) {
        return new Map<String, Object>{
            'type' => 'button', 'action_id' => actionId, 'style' => style,
            'text' => plain(text), 'value' => value
        };
    }
    private static Map<String, Object> header(String t) {
        return new Map<String, Object>{ 'type' => 'header', 'text' => plain(t.abbreviate(150)) };
    }
    private static Map<String, Object> section(String md) {
        return new Map<String, Object>{ 'type' => 'section', 'text' => new Map<String, Object>{ 'type' => 'mrkdwn', 'text' => md } };
    }
    private static Map<String, Object> contextBlock(String md) {
        return new Map<String, Object>{ 'type' => 'context', 'elements' => new List<Object>{ new Map<String, Object>{ 'type' => 'mrkdwn', 'text' => md } } };
    }
    private static Map<String, Object> plain(String t) {
        return new Map<String, Object>{ 'type' => 'plain_text', 'text' => t };
    }

    // ─── 상품팀 전용 채널 생성 (콜아웃) ─────────────────────────────────
    //
    // 이름 = deal-approval-{CaseNumber} (정규화). 상품팀만 초대(상품 담당 rep + 실행한 상품팀 담당자).
    // OpportunityDealChannelService 의 딜 채널(RM 포함)과 별개 — 승인은 상품팀 내부에서만 논의한다.

    private static String createTeamChannel(Case c) {
        String name = normalizeChannelName('deal-approval-' + c.CaseNumber);
        String channelId = createPrivateChannel(name);

        List<String> emails = new List<String>();
        addEmail(emails, UserInfo.getUserEmail()); // 실행한 상품팀 담당자
        addEmail(emails, c.Opportunity__r == null || c.Opportunity__r.Primary_Product__r == null || c.Opportunity__r.Primary_Product__r.Product_Team_Rep__r == null
            ? null : c.Opportunity__r.Primary_Product__r.Product_Team_Rep__r.Email); // 상품 담당 rep
        List<String> userIds = new List<String>();
        for (String em : emails) {
            String u = lookupUserId(em);
            if (u != null) { userIds.add(u); }
        }
        if (!userIds.isEmpty()) {
            invite(channelId, userIds);
        }
        String orgUrl = URL.getOrgDomainUrl().toExternalForm();
        setPurpose(channelId, '<' + orgUrl + '/' + c.Id + '|Case ' + c.CaseNumber + '> 매니저 승인');
        return channelId;
    }

    private static String createPrivateChannel(String name) {
        Map<String, Object> body = new Map<String, Object>{ 'name' => name, 'is_private' => true };
        Map<String, Object> res = postJson('/conversations.create', body);
        Integer attempt = 2;
        while (res.get('ok') != true && String.valueOf(res.get('error')) == 'name_taken' && attempt <= 10) {
            body.put('name', truncate(name + '-' + attempt));
            res = postJson('/conversations.create', body);
            attempt++;
        }
        if (res.get('ok') != true) {
            throw new DealApprovalServiceException('채널 생성 실패: ' + res.get('error'));
        }
        return String.valueOf(((Map<String, Object>) res.get('channel')).get('id'));
    }

    private static String lookupUserId(String email) {
        if (String.isBlank(email)) { return null; }
        Map<String, Object> res = getForm('/users.lookupByEmail?email=' + EncodingUtil.urlEncode(email, 'UTF-8'));
        if (res.get('ok') == true) {
            Map<String, Object> u = (Map<String, Object>) res.get('user');
            return u == null ? null : String.valueOf(u.get('id'));
        }
        return null; // 못 찾아도 채널 생성은 진행(시연 중단 방지)
    }

    private static void invite(String channelId, List<String> userIds) {
        Map<String, Object> res = postJson('/conversations.invite',
            new Map<String, Object>{ 'channel' => channelId, 'users' => String.join(userIds, ',') });
        String err = String.valueOf(res.get('error'));
        if (res.get('ok') != true && err != 'already_in_channel' && err != 'cant_invite_self') {
            throw new DealApprovalServiceException('초대 실패: ' + err);
        }
    }

    private static void setPurpose(String channelId, String purpose) {
        try {
            postJson('/conversations.setPurpose', new Map<String, Object>{ 'channel' => channelId, 'purpose' => purpose.abbreviate(250) });
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'setPurpose 실패(무시): ' + e.getMessage());
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
            throw new DealApprovalServiceException('Slack HTTP ' + res.getStatusCode());
        }
        return (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
    }

    private static String normalizeChannelName(String raw) {
        String n = raw.trim().toLowerCase()
            .replaceAll('[\\s.]+', '-')
            .replaceAll('[^\\p{L}\\p{N}_-]', '')
            .replaceAll('-{2,}', '-')
            .removeStart('-').removeEnd('-');
        return truncate(String.isBlank(n) ? 'deal-approval' : n);
    }
    private static String truncate(String s) {
        return s.length() > 80 ? s.substring(0, 80).removeEnd('-') : s;
    }
    private static void addEmail(List<String> emails, String email) {
        if (String.isBlank(email)) { return; }
        String e = email.trim().toLowerCase();
        if (!emails.contains(e)) { emails.add(e); }
    }
}