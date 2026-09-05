/**
 * 주력 상품이 IPO 상품군인 영업기회에 대해 IB_Deal__c 를 자동 생성한다.
 *
 * 레코드 유형 대신 상품군(Product2.Family)으로 판별한다. 이번 프로젝트에서는
 * 회사채 발행 주선용 레코드 유형을 만들지 않기로 해서, IPO 같은 대형 딜만 대상으로 한다.
 *
 * 원본 영업기회의 소유자는 바꾸지 않는다. 담당 RM 이 자기 딜을 계속 보게 하고,
 * 차단벽은 IB_Deal__c 쪽 딜팀 멤버로 통제한다.
 *
 * 비용: IPO 가 아닌 저장은 SOQL 1회(트랜잭션 내 캐시)만 쓰고 즉시 빠져나온다.
 * 상품이 없거나 바뀌지 않은 저장은 SOQL 0회다.
 */
public with sharing class IBDealAutoCreateService {

    /** 대상 상품군. 늘리려면 여기에 추가한다. */
    public static final Set<String> TARGET_FAMILIES = new Set<String>{ 'IPO' };

    private static Set<Id> cachedTargetProductIds;

    /** 대상 상품군에 속한 상품 Id. 트랜잭션당 1회만 조회한다. */
    private static Set<Id> targetProductIds() {
        if (cachedTargetProductIds == null) {
            cachedTargetProductIds = new Set<Id>();
            List<String> familyList = new List<String>(TARGET_FAMILIES);
            for (Product2 p : [SELECT Id FROM Product2 WHERE Family IN :familyList]) {
                cachedTargetProductIds.add(p.Id);
            }
        }
        return cachedTargetProductIds;
    }

    /** 트리거 진입점. */
    public static void handle(List<Opportunity> newList, Map<Id, Opportunity> oldMap) {
        // 1단계 — SOQL 없이 거른다. 상품이 없거나 그대로면 여기서 끝.
        List<Opportunity> changed = withProductSetOrChanged(newList, oldMap);
        if (changed.isEmpty()) {
            return;
        }

        // 2단계 — 대상 상품군인 것만 남긴다. IPO 가 아니면 여기서 끝.
        Set<Id> targets = targetProductIds();
        List<Opportunity> candidates = new List<Opportunity>();
        for (Opportunity o : changed) {
            if (targets.contains(o.Primary_Product__c)) {
                candidates.add(o);
            }
        }
        if (candidates.isEmpty()) {
            return;
        }

        create(candidates);
    }

    /** 상품이 지정되었거나 바뀐 영업기회만 고른다. SOQL 을 쓰지 않는다. */
    public static List<Opportunity> withProductSetOrChanged(List<Opportunity> newList, Map<Id, Opportunity> oldMap) {
        List<Opportunity> result = new List<Opportunity>();
        if (newList == null) {
            return result;
        }
        for (Opportunity o : newList) {
            if (o.Primary_Product__c == null) {
                continue;
            }
            if (oldMap == null) {
                result.add(o);
            } else {
                Opportunity prior = oldMap.get(o.Id);
                if (prior == null || prior.Primary_Product__c != o.Primary_Product__c) {
                    result.add(o);
                }
            }
        }
        return result;
    }

    /** 실제 생성. 이미 딜이 있는 영업기회는 건너뛴다. */
    private static void create(List<Opportunity> candidates) {
        Set<Id> oppIds = new Map<Id, Opportunity>(candidates).keySet();

        Set<Id> alreadyHasDeal = new Set<Id>();
        for (IB_Deal__c d : [
            SELECT Source_Opportunity__c FROM IB_Deal__c WHERE Source_Opportunity__c IN :oppIds
        ]) {
            alreadyHasDeal.add(d.Source_Opportunity__c);
        }

        Datetime now = Datetime.now();
        List<IB_Deal__c> newDeals = new List<IB_Deal__c>();
        List<Id> ownerByIndex = new List<Id>();

        for (Opportunity o : candidates) {
            if (alreadyHasDeal.contains(o.Id)) {
                continue;
            }
            // 발행사는 IB_Deal__c 의 필수 항목이다. 없으면 만들 수 없다.
            if (o.AccountId == null) {
                continue;
            }

            newDeals.add(new IB_Deal__c(
                Source_Opportunity__c         = o.Id,
                Issuer_Account__c             = o.AccountId,
                Issue_Amount__c               = o.Amount,
                Status__c                     = 'Pipeline',
                Confidentiality_Level__c      = 'High',
                Information_Barrier_Status__c = 'Active',
                Barrier_Start_At__c           = now
            ));
            ownerByIndex.add(o.OwnerId);
        }

        if (newDeals.isEmpty()) {
            return;
        }

        insert newDeals;

        // 원 담당 RM 을 딜팀 멤버로 남긴다. 월크로스 기록 목적이며,
        // 소유자인 경우 공유 레코드는 만들어지지 않는다(이미 전체 권한).
        List<IB_Deal_Team_Member__c> members = new List<IB_Deal_Team_Member__c>();
        for (Integer i = 0; i < newDeals.size(); i++) {
            members.add(new IB_Deal_Team_Member__c(
                IB_Deal__c         = newDeals[i].Id,
                User__c            = ownerByIndex[i],
                Role__c            = 'Lead',
                Access_Level__c    = 'Full',
                Wall_Crossed_At__c = now
            ));
        }
        insert members;
    }
}