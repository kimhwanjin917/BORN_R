/**
 * Boni_Slack_Event__e 구독 (예비 경로).
 * 현재 REST(BoniSlackEventsRest)는 게스트 컨텍스트에서 BoniSlackEventHandler 를 직접 호출한다 —
 * 플랫폼 이벤트 트리거는 Automated Process 로 실행되어 Named Credential 접근이 불가했기 때문(2026-08-27 실측).
 * 외부에서 이 이벤트를 발행하는 경우를 위해 트리거는 유지한다.
 */
trigger BoniSlackEventTrigger on Boni_Slack_Event__e (after insert) {
    BoniSlackEventHandler.handle(Trigger.new);
}