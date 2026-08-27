/**
 * Syncs Recommendation__c.Status__c with the outcome of the linked Opportunity
 * (기회생성 → 수주 / 실패). Deliberately NOT an Opportunity trigger: called from the
 * radar load and the nightly schedule so no automation is added to shared objects.
 */
public with sharing class RecommendationOutcomeService {
    public static final String STATUS_CREATED = '기회생성';
    public static final String STATUS_WON = '수주';
    public static final String STATUS_LOST = '실패';

    /**
     * @param accountIds restrict to these accounts (null = all open linked recommendations)
     * @return number of recommendations updated
     */
    public static Integer syncOutcomes(Set<Id> accountIds) {
        List<Recommendation__c> linked = accountIds == null
            ? [SELECT Id, Opportunity__r.IsClosed, Opportunity__r.IsWon FROM Recommendation__c
               WHERE Status__c = :STATUS_CREATED AND Opportunity__c != null WITH USER_MODE LIMIT 10000]
            : [SELECT Id, Opportunity__r.IsClosed, Opportunity__r.IsWon FROM Recommendation__c
               WHERE Status__c = :STATUS_CREATED AND Opportunity__c != null AND Account__c IN :accountIds WITH USER_MODE LIMIT 10000];

        List<Recommendation__c> toUpdate = new List<Recommendation__c>();
        for (Recommendation__c recommendation : linked) {
            if (recommendation.Opportunity__r.IsClosed != true) {
                continue;
            }
            toUpdate.add(new Recommendation__c(
                Id = recommendation.Id,
                Status__c = recommendation.Opportunity__r.IsWon ? STATUS_WON : STATUS_LOST
            ));
        }
        if (toUpdate.isEmpty()) {
            return 0;
        }
        try {
            Database.update(toUpdate, true, AccessLevel.USER_MODE);
        } catch (DmlException e) {
            throw new RadarException('추천 결과 반영 실패: ' + e.getDmlMessage(0), e);
        }
        return toUpdate.size();
    }
}