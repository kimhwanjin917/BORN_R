/**
 * 전환된 Lead 에서 생성된 Opportunity 에 기본값(RecordType·기준 상품·이름)을 채운다.
 *
 * LeadConvertService 는 Invocable 이라 「미팅 확정」 Flow 와 LeadEventConvertTrigger
 * 에서만 돌았고, 표준 Convert 버튼·API 전환은 그대로 지나갔다. Lead 전환은 어느
 * 경로로 하든 Lead 의 after update 를 거치므로 여기서 한 번에 잡는다.
 */
trigger LeadConvertedTrigger on Lead (after update) {
    LeadConvertService.applyDefaultsForConvertedLeads(Trigger.new, Trigger.oldMap);
}