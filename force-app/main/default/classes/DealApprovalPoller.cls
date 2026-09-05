/**
 * Slack [매니저 결재] 후처리 폴러(2026-09-02). 이 org 의 플랫폼 이벤트 버스가 구독을 소비하지 못하는 문제를 우회한다.
 * 클릭(게스트)은 "처리 중" 카드 교체와 채널 토픽 표식만 남기고, 이 폴러가 표식을 찾아
 * 완료 카드·새 메시지 게시 → "(심사 완료)" 조건서 렌더·Slack 직접 업로드 → Case 승인·수익률 승격을 실행한다.
 * 콜아웃을 전부 끝낸 뒤 DML 을 하는 순서라(콜아웃→DML 제약) 조건서는 저장 없이 렌더링만 해서 올린다.
 *
 * 구동 방식: 30초 간격 1회성 스케줄 핑퐁(스케줄 턴이 다음 턴을 예약하고 폴 큐어블을 실행) + 큐어블 쪽 자가 복구.
 * 큐어블 자가 체인은 이 org(트라이얼)의 체인 깊이 5 제한으로 죽고("Maximum stack depth" 실측), 반복 크론은
 * 초·분 와일드카드 불가로 못 쓴다(둘 다 2026-09-02 실측).
 * 실행 사용자: start() 를 호출한 내부 사용자 — Case/Opportunity 접근 + Slack 자격증명 필요(예: 강윤지).
 * 시작(익명 Apex): System.debug(DealApprovalPoller.start());   중지: DealApprovalPoller.stopAll();
 */
public with sharing class DealApprovalPoller implements Schedulable {

    /** 폴 간격(초). Salesforce 크론은 초·분 와일드카드가 안 돼 반복 크론 대신 1회성 스케줄 핑퐁으로 돈다. */
    @TestVisible private static Integer INTERVAL_SECONDS = 30;
    @TestVisible private static final String JOB_PREFIX = 'DealApprovalPoller';

    /** 폴링 시작(이미 예약된 턴이 있으면 건너뜀). 익명 Apex 로 1회 호출. */
    public static String start() {
        if (hasPendingTick()) {
            return '폴러가 이미 실행 중입니다.';
        }
        scheduleTick(5);
        return '폴러 시작: ' + INTERVAL_SECONDS + '초 간격 (1회성 스케줄 핑퐁 + 자가 복구).';
    }

    /** 폴링 중지 — 예약된 턴을 내린다. 실행 중이던 큐어블이 직후 재예약할 수 있으니 필요하면 한 번 더 호출. */
    public static String stopAll() {
        Integer aborted = 0;
        for (CronTrigger c : [
            SELECT Id FROM CronTrigger WHERE CronJobDetail.Name LIKE :JOB_PREFIX + '%'
        ]) {
            try {
                System.abortJob(c.Id);
                aborted++;
            } catch (Exception ignore) {}
        }
        return '크론 ' + aborted + '건 중지.';
    }

    private static Boolean hasPendingTick() {
        return [
            SELECT COUNT() FROM CronTrigger
            WHERE CronJobDetail.Name LIKE :JOB_PREFIX + '%' AND State IN ('WAITING', 'ACQUIRED', 'EXECUTING')
        ] > 0;
    }

    private static void scheduleTick(Integer delaySeconds) {
        Datetime runAt = Datetime.now().addSeconds(delaySeconds);
        String cron = runAt.second() + ' ' + runAt.minute() + ' ' + runAt.hour() + ' '
            + runAt.day() + ' ' + runAt.month() + ' ? ' + runAt.year();
        System.schedule(JOB_PREFIX + '-' + runAt.getTime(), cron, new DealApprovalPoller());
    }

    /** 스케줄 턴: 스스로 정리 → 다음 턴 예약 → 폴 큐어블 실행(콜아웃은 스케줄 컨텍스트 불가라 위임). */
    public void execute(SchedulableContext sc) {
        try {
            System.abortJob(sc.getTriggerId());
        } catch (Exception ignore) {}
        try {
            scheduleTick(INTERVAL_SECONDS);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '폴러 다음 턴 예약 실패: ' + e.getMessage());
        }
        if (!Test.isRunningTest() && Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
            System.enqueueJob(new PollJob());
        }
    }

    /**
     * 폴 실행 본체(한 클래스가 Schedulable·Queueable 을 겸할 수 없어 이너 클래스로 분리 — 2026-09-02 실측).
     * 어떤 실패도 다음 턴 재시도로 넘긴다(표식이 토픽에 남아 있어 유실 없음).
     * 스케줄 쪽이 죽었어도 여기서 재예약해 살린다(이중 안전).
     */
    public class PollJob implements Queueable, Database.AllowsCallouts {
        public void execute(QueueableContext ctx) {
            try {
                processOnePending();
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, '결재 폴러 틱 실패: ' + e.getMessage() + '\n' + e.getStackTraceString());
            }
            try {
                if (!hasPendingTick()) {
                    scheduleTick(INTERVAL_SECONDS);
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, '폴러 자가 복구 예약 실패: ' + e.getMessage());
            }
        }
    }

    /**
     * 판매 승인 Case 가 있는 딜의 채널 토픽을 확인해, 충분히 기다린 표식 1건을 처리한다(틱당 1건 — 콜아웃 한도 보호).
     * 이미 승인된 딜도 후보에 남긴다 — 재클릭(재시연) 표식도 처리해야 하며, 처리 후 토픽을 지우므로 중복 루프는 없다.
     */
    @TestVisible
    private static void processOnePending() {
        // LIMIT 은 콜아웃 한도(틱당 채널 수만큼 conversations.info) 보호용 — 후보가 이보다 많아지면 올릴 것.
        // 정렬 없이 LIMIT 10 이던 시절, 후보 15건 중 클릭된 딜이 조회 목록에서 빠져 영영 미처리된 사례(2026-09-02).
        List<Opportunity> candidates = [
            SELECT Id, Slack_Channel_ID__c FROM Opportunity
            WHERE Slack_Channel_ID__c != null
              AND Id IN (SELECT Opportunity__c FROM Case WHERE Opportunity__c != null)
            ORDER BY LastModifiedDate DESC
            LIMIT 50
        ];
        for (Opportunity cand : candidates) {
            List<String> marker = DealApprovalHandler.readApprovalMarker(cand.Slack_Channel_ID__c);
            if (marker == null || marker.isEmpty()) {
                continue;
            }
            // 최소 대기 없이 즉시 처리 — "처리 중" 카드는 다음 틱까지(0~30초)만 보인다(2026-09-02 요구).
            processDeal(cand.Id, cand.Slack_Channel_ID__c, marker[0]);
            break;
        }
    }

    /** 순서 중요: 콜아웃(카드·메시지·PDF·토픽 정리) 전부 → 마지막에 DML(Case 승인·수익률 승격). */
    private static void processDeal(Id oppId, String channelId, String ts) {
        // 완료 카드 재료 — 원본 블록은 게스트 쪽에만 있었으므로 딜 데이터로 조건 카드를 다시 만든다.
        Opportunity opp = [
            SELECT Id, Name, Amount, Fee_Rate__c, RP_Yield__c, Pending_Yield__c, RP_Maturity_Date__c,
                   Slack_Channel_ID__c, Account.Name, Account.Industry, Account.AnnualRevenue,
                   Account.Relationship_Grade__c, Account.Priority_Rationale_Summary__c,
                   Owner.Email, Owner.Name,
                   Primary_Product__r.Name, Primary_Product__r.Family, Primary_Product__r.Default_Fee_Rate__c,
                   Primary_Product__r.Product_Team_Rep__r.Name
            FROM Opportunity WHERE Id = :oppId
        ];
        List<Case> cases = [
            SELECT Id, Opportunity__c, Owner.Name, Description, Agreed_Yield_Rate__c, Contract_Term_Months__c
            FROM Case WHERE Opportunity__c = :oppId ORDER BY CreatedDate DESC LIMIT 1
        ];
        List<Object> cardBase = OpportunityDealChannelService.buildTermCardBlocks(opp, cases.isEmpty() ? null : cases[0]);
        List<Object> blocks = DealApprovalHandler.approvedBlocksFromOriginal(cardBase, oppId, null, true);

        BoniSlackClient.updateBlocks(channelId, ts, '매니저 결재 승인', blocks);
        BoniSlackClient.postBlocks(channelId, '매니저 결재 승인', blocks);

        // "(심사 완료)" 조건서: 렌더링만 해서 Slack 에 직접 업로드(저장 없음). 조건서가 없는 딜이면 생략.
        try {
            RpTermConfirmController.ReviewedPdf pdf = RpTermConfirmController.buildReviewedTermPdf(oppId);
            if (pdf != null) {
                uploadToChannel(pdf.body, pdf.fileName, channelId);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '심사완료 조건서 업로드 실패 ' + oppId + ': ' + e.getMessage());
        }

        DealApprovalHandler.clearApprovalTopic(channelId);

        // 콜아웃이 모두 끝난 뒤 레코드 갱신
        DealApprovalHandler.applyApprovalRecords(oppId);
    }

    /** Slack 3단계 외부 업로드 — SlackProposalShareService.uploadAndShareFile 과 같은 절차의 블롭 입력판. */
    private static void uploadToChannel(Blob body, String fileName, String channelId) {
        Map<String, Object> urlResult = slackGet('/files.getUploadURLExternal?filename='
            + EncodingUtil.urlEncode(fileName, 'UTF-8') + '&length=' + body.size());
        if (urlResult.get('ok') != true) {
            throw new PollerException('업로드 URL 발급 실패: ' + urlResult.get('error'));
        }
        HttpRequest up = new HttpRequest();
        up.setEndpoint(String.valueOf(urlResult.get('upload_url')));
        up.setMethod('POST');
        up.setHeader('Content-Type', 'application/octet-stream');
        up.setTimeout(60000);
        up.setBodyAsBlob(body);
        HttpResponse upRes = new Http().send(up);
        if (upRes.getStatusCode() < 200 || upRes.getStatusCode() >= 300) {
            throw new PollerException('파일 업로드 HTTP ' + upRes.getStatusCode());
        }
        Map<String, Object> completeResult = slackPost('/files.completeUploadExternal', new Map<String, Object>{
            'files' => new List<Object>{ new Map<String, Object>{
                'id' => String.valueOf(urlResult.get('file_id')), 'title' => fileName } },
            'channel_id' => channelId
        });
        if (completeResult.get('ok') != true) {
            throw new PollerException('채널 공유 실패: ' + completeResult.get('error'));
        }
    }

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

    public class PollerException extends Exception {}
}