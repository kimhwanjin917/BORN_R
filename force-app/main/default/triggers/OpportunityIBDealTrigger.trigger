/**
 * 주력 상품이 IPO 상품군인 영업기회에 IB_Deal__c 를 자동 생성한다.
 * IPO 가 아니면 서비스가 즉시 반환한다. 기존 OpportunityReviewTrigger 는 건드리지 않는다.
 */
trigger OpportunityIBDealTrigger on Opportunity (after insert, after update) {
    IBDealAutoCreateService.handle(
        Trigger.new,
        Trigger.isUpdate ? Trigger.oldMap : null
    );
}