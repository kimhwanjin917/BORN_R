/**
 * docs/60 별건(보니) — 홈 보니 배너용 집계. 로그인 사용자가 소유한 진행 중 기회 수.
 * 격리 컴포넌트: 다른 클래스·오브젝트 로직을 건드리지 않는다.
 */
public with sharing class BoniBannerController {
    @AuraEnabled(cacheable=true)
    public static Integer getOpenOpportunityCount() {
        return [
            SELECT COUNT()
            FROM Opportunity
            WHERE OwnerId = :UserInfo.getUserId() AND IsClosed = false
            WITH USER_MODE
        ];
    }
}