/**
 * Boni_Slack_Event__e 구독.
 * 현재 REST(BoniSlackEventsRest)는 게스트 컨텍스트에서 BoniSlackEventHandler 를 직접 호출한다 —
 * 플랫폼 이벤트 트리거는 Automated Process 로 실행되어 Named Credential 접근이 불가했기 때문(2026-08-27 실측).
 * 단, 승인/반려/제출(딜 승인)은 게스트가 표준오브젝트 DML 을 못 해 이 이벤트를 발행하고 이 트리거가 대신 처리한다(콜아웃 없음).
 */
trigger BoniSlackEventTrigger on Boni_Slack_Event__e (after insert) {
    BoniSlackEventHandler.handle(Trigger.new);
}