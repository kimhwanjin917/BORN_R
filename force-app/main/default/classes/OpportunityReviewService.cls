/**
 * docs/52 · ADR-0003 — 22번 "심사". 시연은 RM 시점이라 상품팀 액션 없이,
 * 미팅 로그 저장(28번 상품팀 Slack 전송과 같은 트리거 조건) 직후 비동기로
 *   1) Opportunity.Approval_Status__c = Approved
 *   2) 심사 완료 벨 알림(CustomNotificationType Review_Completed) + Task "계약서 확인·고객 서명 요청"
 *   3) ContractDocumentService: 표준 Contract + 계약서 PDF 자동 생성(Contract·Opp 첨부)
 *   4) Opportunity.StageName = 계약 체결
 * 을 수행한다. 이미 Approved 인 기회는 건너뛴다(한 번만).
 */
public with sharing class OpportunityReviewService implements Queueable {

    public static final String APPROVED = 'Approved';
    public static final String STAGE_DEAL_CLOSED = '계약 체결';
    public static final String NOTIFICATION_TYPE = 'Review_Completed';
    public static final String TASK_SUBJECT = '계약서 확인·고객 서명 요청';
    @TestVisible
    private static Boolean bypass = false;

    private final List<Id> opportunityIds;

    public OpportunityReviewService(List<Id> opportunityIds) {
        this.opportunityIds = opportunityIds;
    }

    /** 트리거 진입점: 미팅 로그가 바뀐 미승인 기회만 큐에 넣는다. */
    public static void enqueueForOpportunities(List<Opportunity> newOpps, Map<Id, Opportunity> oldMap) {
        if (bypass) {
            return;
        }
        List<Id> targets = new List<Id>();
        for (Opportunity opp : newOpps) {
            Opportunity old = oldMap == null ? null : oldMap.get(opp.Id);
            Boolean logChanged = old == null ? !String.isBlank(opp.Meeting_Log__c) : old.Meeting_Log__c != opp.Meeting_Log__c;
            if (logChanged && !String.isBlank(opp.Meeting_Log__c) && opp.Approval_Status__c != APPROVED) {
                targets.add(opp.Id);
            }
        }
        if (!targets.isEmpty() && Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
            System.enqueueJob(new OpportunityReviewService(targets));
        }
    }

    public void execute(QueueableContext ctx) {
        completeReview(opportunityIds);
    }

    /** 동기 실행 본체(테스트·재실행용). 처리한 기회 Id 목록을 돌려준다. */
    public static List<Id> completeReview(List<Id> oppIds) {
        List<Opportunity> opps = [
            SELECT Id, Name, OwnerId, Account.Name, Approval_Status__c, StageName, IsClosed,
                   Primary_Product__r.Name, Product_Family__c
            FROM Opportunity
            WHERE Id IN :oppIds AND Approval_Status__c != :APPROVED AND IsClosed = false
        ];
        if (opps.isEmpty()) {
            return new List<Id>();
        }

        // 3) 계약서 — PDF 렌더링(콜아웃 취급)이 있어 이 트랜잭션의 어떤 DML 보다 먼저 호출한다
        Map<Id, ContractDocumentService.Result> contractByOpp = ContractDocumentService.createContracts(opps);

        // 1) 승인 상태 + 4) 단계 (계약서 생성 성공 여부와 무관하게 심사는 완료로 본다)
        List<Opportunity> updates = new List<Opportunity>();
        for (Opportunity opp : opps) {
            updates.add(new Opportunity(Id = opp.Id, Approval_Status__c = APPROVED, StageName = STAGE_DEAL_CLOSED));
        }
        bypass = true;
        try {
            update as user updates;
        } finally {
            bypass = false;
        }

        // 2) 알림 + Task
        List<Task> tasks = new List<Task>();
        List<Id> done = new List<Id>();
        for (Opportunity opp : opps) {
            ContractDocumentService.Result cr = contractByOpp.get(opp.Id);
            String product = opp.Primary_Product__r == null ? (String.isBlank(opp.Product_Family__c) ? '' : opp.Product_Family__c) : opp.Primary_Product__r.Name;
            String company = opp.Account == null ? opp.Name : opp.Account.Name;
            String title = company + ' ' + product + ' 심사 완료';
            String body = cr != null && cr.isSuccess
                ? '계약서가 생성되었습니다: ' + cr.fileName
                : '계약서 생성에 실패했습니다' + (cr == null ? '' : ' — ' + cr.errorMessage);
            sendBellNotification(title.trim(), body, opp.OwnerId, opp.Id);
            tasks.add(new Task(
                Subject = TASK_SUBJECT,
                WhatId = opp.Id,
                OwnerId = opp.OwnerId,
                Status = 'Not Started',
                Priority = 'High',
                ActivityDate = Date.today().addDays(3),
                Description = body + (cr != null && cr.contractId != null ? '\n계약: ' + URL.getOrgDomainUrl().toExternalForm() + '/' + cr.contractId : '')
            ));
            done.add(opp.Id);
        }
        insert as user tasks;
        return done;
    }

    @TestVisible
    private static void sendBellNotification(String title, String body, Id recipientId, Id targetId) {
        List<CustomNotificationType> types = [SELECT Id FROM CustomNotificationType WHERE DeveloperName = :NOTIFICATION_TYPE LIMIT 1];
        if (types.isEmpty()) {
            System.debug(LoggingLevel.WARN, 'CustomNotificationType 없음: ' + NOTIFICATION_TYPE);
            return;
        }
        try {
            Messaging.CustomNotification n = new Messaging.CustomNotification();
            n.setTitle(title.abbreviate(250));
            n.setBody(body.abbreviate(750));
            n.setNotificationTypeId(types[0].Id);
            n.setTargetId(targetId);
            n.send(new Set<String>{ String.valueOf(recipientId) });
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, '벨 알림 전송 실패(무시): ' + e.getMessage());
        }
    }
}