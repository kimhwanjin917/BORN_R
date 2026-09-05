/**
 * IB_Deal__c 의 Apex 관리 공유를 딜팀 멤버 기준으로 재계산한다.
 *
 * 공유 사유: IB_Deal_Team__c ("IB 딜팀 접근")
 * 이 사유로 만든 공유만 지우고 다시 만든다. 수동 공유나 다른 사유의 공유는 건드리지 않는다.
 *
 * without sharing 인 이유: 공유 재계산은 실행자의 접근 권한과 무관하게 딜 전체를 대상으로
 * 동작해야 한다. 사용자 승인을 받은 예외다 (AGENTS.md 2단계).
 */
public without sharing class IBDealSharingService {

    private static final String REASON = Schema.IB_Deal__Share.RowCause.IB_Deal_Team__c;

    public static final String DELETE_BLOCKED_MESSAGE =
        '딜팀 멤버는 삭제할 수 없습니다. 접근을 끝내려면 삭제 대신 [접근 종료 일시]를 채우세요. ' +
        '채운 뒤에도 레코드는 남습니다 — 누가 언제부터 언제까지 이 딜을 알았는지가 감사 근거이기 때문입니다.';

    /**
     * 지금 트랜잭션에서 삭제 중인 딜의 Id. 마스터-디테일 연쇄 삭제에서 자식까지 막으면
     * 딜 자체를 지울 수 없게 되므로, IBDealTrigger 가 여기에 담아 그 딜의 자식만 통과시킨다.
     *
     * 참/거짓 플래그가 아니라 Id 집합인 이유: 한 트랜잭션에서 딜 A 를 지우면서 딜 B 의
     * 멤버를 함께 지우려 하면, 플래그 방식은 B 의 멤버까지 통과시켜 버린다.
     */
    public static Set<Id> dealsBeingDeleted = new Set<Id>();

    /**
     * 월크로스 일시가 비어 있으면 등록 시각으로 채운다.
     * 기입을 잊어도 "언제 명단에 들어왔는지"가 반드시 남게 하기 위한 것이다.
     * 값을 직접 넣은 경우에는 그대로 두므로, 미래 일시로 접근을 미루는 동작은 유지된다.
     */
    public static void stampWallCrossing(List<IB_Deal_Team_Member__c> members) {
        if (members == null) {
            return;
        }
        Datetime now = Datetime.now();
        for (IB_Deal_Team_Member__c m : members) {
            if (m.Wall_Crossed_At__c == null) {
                m.Wall_Crossed_At__c = now;
            }
        }
    }

    /**
     * 딜팀 멤버 삭제를 막는다. 명단에서 지우는 대신 기간을 끝내야 이력이 보존된다.
     * 부모 딜이 함께 삭제되는 연쇄 삭제는 통과시킨다.
     */
    public static void blockDeletion(List<IB_Deal_Team_Member__c> members) {
        if (members == null) {
            return;
        }
        for (IB_Deal_Team_Member__c m : members) {
            // 자기 부모 딜이 함께 지워지는 중일 때만 통과
            if (dealsBeingDeleted.contains(m.IB_Deal__c)) {
                continue;
            }
            m.addError(DELETE_BLOCKED_MESSAGE);
        }
    }

    /** 딜팀 멤버 기준으로 공유를 다시 만든다. */
    public static void recalculate(Set<Id> dealIds) {
        if (dealIds == null || dealIds.isEmpty()) {
            return;
        }

        delete [
            SELECT Id
            FROM IB_Deal__Share
            WHERE ParentId IN :dealIds
              AND RowCause = :REASON
        ];

        Datetime now = Datetime.now();

        Map<Id, Id> ownerByDeal = new Map<Id, Id>();
        Set<Id> barrierEnded = new Set<Id>();
        for (IB_Deal__c d : [SELECT Id, OwnerId, Barrier_End_At__c FROM IB_Deal__c WHERE Id IN :dealIds]) {
            ownerByDeal.put(d.Id, d.OwnerId);
            // 차단벽 종료일시가 지나면 딜팀 임기가 끝난 것으로 본다.
            // 멤버별 Access_Ended_At__c 와 무관하게 딜 단위 상한선으로 작동한다.
            if (d.Barrier_End_At__c != null && d.Barrier_End_At__c <= now) {
                barrierEnded.add(d.Id);
            }
        }

        Map<String, IB_Deal__Share> shares = new Map<String, IB_Deal__Share>();

        for (IB_Deal_Team_Member__c m : [
            SELECT IB_Deal__c, User__c, Access_Level__c, Wall_Crossed_At__c, Access_Ended_At__c
            FROM IB_Deal_Team_Member__c
            WHERE IB_Deal__c IN :dealIds
              AND User__c != null
              AND Access_Level__c IN ('Read', 'Full')
        ]) {
            // 딜의 차단 기간이 끝났으면 그 딜은 전원 회수
            if (barrierEnded.contains(m.IB_Deal__c)) {
                continue;
            }
            // 기간 만료 → 접근 없음
            if (m.Access_Ended_At__c != null && m.Access_Ended_At__c <= now) {
                continue;
            }
            // 월크로스 예정일이 미래면 아직 접근 없음. 값이 비어 있으면 즉시 부여로 본다.
            if (m.Wall_Crossed_At__c != null && m.Wall_Crossed_At__c > now) {
                continue;
            }
            // 소유자에게는 공유를 만들 수 없다 (이미 전체 권한)
            if (m.User__c == ownerByDeal.get(m.IB_Deal__c)) {
                continue;
            }

            String level = (m.Access_Level__c == 'Full') ? 'Edit' : 'Read';
            String key = m.IB_Deal__c + '|' + m.User__c;

            // 같은 사람이 여러 줄이면 넓은 권한이 이긴다
            IB_Deal__Share existing = shares.get(key);
            if (existing != null && existing.AccessLevel == 'Edit') {
                continue;
            }

            shares.put(key, new IB_Deal__Share(
                ParentId      = m.IB_Deal__c,
                UserOrGroupId = m.User__c,
                AccessLevel   = level,
                RowCause      = REASON
            ));
        }

        if (!shares.isEmpty()) {
            insert shares.values();
        }
    }

    /** 트리거용 — 멤버 레코드에서 딜 Id를 모은다. */
    public static Set<Id> dealIdsOf(List<IB_Deal_Team_Member__c> members) {
        Set<Id> ids = new Set<Id>();
        if (members == null) {
            return ids;
        }
        for (IB_Deal_Team_Member__c m : members) {
            if (m.IB_Deal__c != null) {
                ids.add(m.IB_Deal__c);
            }
        }
        return ids;
    }
}