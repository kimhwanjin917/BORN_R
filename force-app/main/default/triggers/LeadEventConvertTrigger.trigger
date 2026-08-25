/**
 * Lead에 미팅 Event가 등록되면(예: Slackbot AI 경유) 해당 Lead를
 * 자동으로 Opportunity로 전환하는 진입점.
 * 실제 판별·전환은 LeadEventConvertHandler가 수행한다.
 */
trigger LeadEventConvertTrigger on Event(after insert) {
    LeadEventConvertHandler.handleAfterInsert(Trigger.new);
}