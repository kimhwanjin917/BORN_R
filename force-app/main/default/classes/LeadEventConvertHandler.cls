/**
 * Event after-insert에서 "미전환 Lead에 걸린 Event"를 찾아
 * 기존 LeadConvertService(13번 미팅 확정의 전환 엔진)를 통해
 * Lead → Account/Contact/Opportunity 전환을 비동기로 실행한다.
 *
 * 동작 규칙:
 *  - WhoId가 Lead(00Q)인 Event만 대상. Contact에 걸린 Event는 무시
 *    (LeadConvertService가 전환 후 만드는 "고객 미팅" Event가 여기 해당 → 재귀 없음).
 *  - 이미 전환된 Lead는 건너뛴다. 같은 트랜잭션에 같은 Lead의 Event가
 *    여러 건 들어오면 첫 Event 하나만 사용한다.
 *  - createMeetingEvent=false로 호출해 서비스의 "고객 미팅" Event 중복 생성을 막고,
 *    봇이 만든 원본 Event를 유일한 미팅 기록으로 유지한다(전환이 WhoId를 Contact로
 *    자동 이전, 본 핸들러가 WhatId를 새 Opportunity로 연결).
 *  - 전환(DML 다량 + 재연결)은 Slackbot 등 외부 API의 Event insert 트랜잭션과
 *    분리하기 위해 Queueable로 실행한다.
 */
public with sharing class LeadEventConvertHandler {

    /**
     * Trigger.new의 Event 중 미전환 Lead에 걸린 것을 골라 전환 작업을 큐에 넣는다.
     * @param newEvents Trigger.new
     */
    public static void handleAfterInsert(List<Event> newEvents) {
        Map<Id, Event> firstEventByLeadId = new Map<Id, Event>();
        for (Event ev : newEvents) {
            if (ev.WhoId == null || ev.WhoId.getSobjectType() != Lead.SObjectType) {
                continue;
            }
            if (!firstEventByLeadId.containsKey(ev.WhoId)) {
                firstEventByLeadId.put(ev.WhoId, ev);
            }
        }
        if (firstEventByLeadId.isEmpty()) {
            return;
        }

        // 이미 전환된 Lead 제외 (전환 여부 최종 판정은 Queueable에서 한 번 더 한다)
        Map<Id, Lead> openLeads = new Map<Id, Lead>([
            SELECT Id FROM Lead
            WHERE Id IN :firstEventByLeadId.keySet() AND IsConverted = false
            WITH USER_MODE
        ]);
        if (openLeads.isEmpty()) {
            return;
        }

        List<ConversionInput> inputs = new List<ConversionInput>();
        for (Id leadId : openLeads.keySet()) {
            Event source = firstEventByLeadId.get(leadId);
            Datetime meetingDateTime = source.StartDateTime != null
                ? source.StartDateTime
                : source.ActivityDateTime;
            inputs.add(new ConversionInput(leadId, source.Id, meetingDateTime));
        }
        System.enqueueJob(new ConvertQueueable(inputs));
    }

    /** Lead 1건의 전환에 필요한 최소 정보 */
    public class ConversionInput {
        public Id leadId;
        public Id sourceEventId;
        public Datetime meetingDateTime;

        public ConversionInput(Id leadId, Id sourceEventId, Datetime meetingDateTime) {
            this.leadId = leadId;
            this.sourceEventId = sourceEventId;
            this.meetingDateTime = meetingDateTime;
        }
    }

    /** LeadConvertService 호출과 원본 Event 정리를 트리거 트랜잭션 밖에서 수행 */
    public class ConvertQueueable implements Queueable {
        private List<ConversionInput> inputs;

        public ConvertQueueable(List<ConversionInput> inputs) {
            this.inputs = inputs;
        }

        public void execute(QueueableContext context) {
            // enqueue 시점과 실행 시점 사이에 전환됐을 수 있으므로(예: 13번 미팅 확정) 재확인
            Set<Id> leadIds = new Set<Id>();
            for (ConversionInput input : inputs) {
                leadIds.add(input.leadId);
            }
            Map<Id, Lead> openLeads = new Map<Id, Lead>([
                SELECT Id FROM Lead
                WHERE Id IN :leadIds AND IsConverted = false
                WITH USER_MODE
            ]);

            List<LeadConvertService.Request> requests = new List<LeadConvertService.Request>();
            List<ConversionInput> submitted = new List<ConversionInput>();
            for (ConversionInput input : inputs) {
                if (!openLeads.containsKey(input.leadId) || input.meetingDateTime == null) {
                    continue;
                }
                LeadConvertService.Request req = new LeadConvertService.Request();
                req.leadId = input.leadId;
                req.meetingDateTime = input.meetingDateTime;
                req.createMeetingEvent = false; // 원본 Event가 이미 미팅 기록이므로 중복 생성 방지
                requests.add(req);
                submitted.add(input);
            }
            if (requests.isEmpty()) {
                return;
            }

            List<LeadConvertService.Response> responses = LeadConvertService.convertLeads(requests);

            // 성공 건은 원본 Event를 새 Opportunity에 연결(WhoId는 전환이 Contact로 자동 이전)
            List<Event> eventsToRelink = new List<Event>();
            List<SlackAlertService.LeadConvertFailure> failures = new List<SlackAlertService.LeadConvertFailure>();
            for (Integer i = 0; i < responses.size(); i++) {
                LeadConvertService.Response res = responses[i];
                if (res.isSuccess == true && res.opportunityId != null) {
                    eventsToRelink.add(new Event(
                        Id = submitted[i].sourceEventId,
                        WhatId = res.opportunityId
                    ));
                } else if (res.isSuccess != true) {
                    failures.add(new SlackAlertService.LeadConvertFailure(
                        submitted[i].leadId, submitted[i].sourceEventId, res.errorType, res.errorMessage));
                    System.debug(LoggingLevel.WARN, 'Lead 자동 전환 실패 Lead=' + submitted[i].leadId
                        + ' type=' + res.errorType + ' msg=' + res.errorMessage);
                }
            }
            if (!eventsToRelink.isEmpty()) {
                // 연결 실패가 전환 자체를 되돌릴 이유는 아니므로 개별 실패 허용
                Database.update(eventsToRelink, false, AccessLevel.USER_MODE);
            }
            // 실패 건은 담당자가 보는 Slack 채널(#crm-처리요청)로 알린다.
            // SlackAlertService 는 내부에서 모든 예외를 삼키므로 전환 결과에 영향을 주지 않는다.
            if (!failures.isEmpty()) {
                SlackAlertService.notifyLeadConvertFailures(failures);
            }
        }
    }
}