/**
 * 팀장 코칭 콘솔 LWC 의 진입점.
 * 설계: docs/superpowers/specs/2026-09-02-tableau-lwc-coaching-design.md
 *
 * 원칙 — "읽기는 Tableau, 쓰기는 LWC".
 * 이 컨트롤러는 숫자를 조회하거나 재계산하지 않는다. 화면에 이미 보이는 값을
 * 선택 컨텍스트로 받아 쓰기 동작만 수행한다.
 *
 * **Opportunity 를 단 한 건도 조회하지 않는다.** 팀장은 팀원의 개별 Opportunity 를
 * 읽을 권한이 없고(OWD Private), 그 경계를 코드로 우회하지 않는 것이 이 설계의 전제다.
 */
public with sharing class TeamCoachingController {

    /** 화면 스케일이 억 단위라 저장 직전에 원 단위로 되돌린다(User.Quota_Fee__c 는 원 단위). */
    private static final Decimal EOK = 100000000;

    /**
     * 목표는 정수 억이 아니다. Quota_Fee__c 는 수수료 목표라 2.5억 같은 값이 정상이고,
     * 반올림해 버리면 저장한 값과 화면 값이 어긋난다. 소수 둘째 자리까지 유지한다.
     */
    private static final Integer QUOTA_SCALE = 2;

    /**
     * 코칭 발송 — RM 과의 1:1 비공개 Slack 채널에 메시지를 보내고 Task 를 남긴다.
     * Slack 이 실패해도 Task 는 생성되며, 결과에 실패 사유가 그대로 담긴다.
     */
    @AuraEnabled
    public static TeamCoachingService.CoachingResult sendCoaching(String rmUserId, String rmName, String stageLabel, String message) {
        try {
            TeamCoachingService.CoachingRequest request = new TeamCoachingService.CoachingRequest();
            request.rmUserId = rmUserId;
            request.rmName = rmName;
            request.stageLabel = stageLabel;
            request.message = message;
            return TeamCoachingService.sendCoaching(request);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * 목표(Quota) 수정. 억 단위로 받아 원 단위로 저장한다.
     *
     * 새로고침을 여기서 같이 하지 않는 이유: Apex 는 DML 뒤에 콜아웃을 허용하지 않는다.
     * LWC 가 저장 → refreshDashboard() 순서로 두 번 호출한다(그래야 화면이 진행 상태를
     * 보여줄 수 있고, 새로고침이 실패해도 저장은 확정된 채로 남는다).
     */
    @AuraEnabled
    public static QuotaResult updateQuota(String rmUserId, Decimal quotaEok) {
        try {
            if (String.isBlank(rmUserId)) {
                throw new TeamCoachingService.TeamCoachingException('RM 을 특정할 수 없습니다.');
            }
            if (quotaEok == null || quotaEok < 0) {
                throw new TeamCoachingService.TeamCoachingException('목표는 0 이상의 숫자여야 합니다.');
            }

            Decimal rounded = quotaEok.setScale(QUOTA_SCALE, System.RoundingMode.HALF_UP);
            User rm = new User(Id = rmUserId, Quota_Fee__c = rounded * EOK);
            update rm;

            QuotaResult result = new QuotaResult();
            result.rmUserId = rmUserId;
            result.quotaEok = rounded;
            // stripTrailingZeros() 만 쓰면 480.00 이 "4.8E+2" 로 나온다. 화면 문구라 평문이어야 한다.
            result.message = '목표를 ' + rounded.stripTrailingZeros().toPlainString() + '억으로 저장했습니다.';
            return result;
        } catch (DmlException e) {
            // 팀장 프로필에 User.Quota_Fee__c 편집 권한(FLS)이 없으면 여기로 온다.
            throw new AuraHandledException('목표 저장에 실패했습니다: ' + e.getDmlMessage(0));
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * Tableau 추출 새로고침을 요청한다. 202 가 즉시 돌아오고 실제 작업은 큐에서 이어진다
     * (실측: 요청 후 14초에 시작, 28초에 완료 — 2026-09-02).
     * 실패해도 예외를 던지지 않는다 — 저장은 이미 끝났고 다음 정시에 어차피 갱신된다.
     */
    @AuraEnabled
    public static TableauRefreshService.RefreshResult refreshDashboard() {
        return TableauRefreshService.refreshTeamDatasource();
    }

    /**
     * 새로고침 작업이 끝났는지 확인한다. LWC 가 완료될 때까지 주기적으로 부른다.
     * 고정 대기로는 큐 지연을 맞출 수 없어 폴링으로 간다.
     */
    @AuraEnabled
    public static TableauRefreshService.JobStatus getRefreshStatus(String jobId) {
        return TableauRefreshService.getJobStatus(jobId);
    }

    /**
     * RM 이름으로 User Id 를 찾는다 — 마크에 RMId 가 실려 오지 않는 시트를 위한 보조 경로.
     *
     * 워크북의 `c1_quota`/`c1_fc`/`c1_won` 시트에는 RMId 를 숨은 필드로 넣지 못했다
     * (넣으려면 워크북을 다시 게시해야 하는데, 완성된 대시보드의 정렬이 틀어질 위험이 있어
     *  2026-09-02 Tableau 쪽을 동결하기로 했다 — docs/68). 그 시트를 클릭해도 조치가 나가야 한다.
     *
     * 스펙 4·9장은 "이름으로 추측 매칭하지 않는다"고 못박았고, 그 이유는 동명이인과 표기 차이다.
     * 그래서 **정확히 한 명일 때만** 쓴다. 0명이거나 2명 이상이면 null 을 돌려주고, LWC 가 조치를 막는다.
     * 즉 애매하면 절대 보내지 않는다 — 금지의 취지는 지키면서 막힌 경로만 연다.
     */
    @AuraEnabled(cacheable=true)
    public static String resolveRmId(String rmName) {
        if (String.isBlank(rmName)) {
            return null;
        }
        String name = rmName.trim();
        List<User> users = [SELECT Id FROM User WHERE Name = :name AND IsActive = true LIMIT 2];
        return users.size() == 1 ? String.valueOf(users[0].Id) : null;
    }

    /** 목표 편집 패널이 현재 저장된 값을 보여주기 위한 조회. User 만 읽는다. */
    @AuraEnabled(cacheable=true)
    public static Decimal getQuotaEok(String rmUserId) {
        if (String.isBlank(rmUserId)) {
            return null;
        }
        List<User> users = [SELECT Quota_Fee__c FROM User WHERE Id = :rmUserId LIMIT 1];
        if (users.isEmpty() || users[0].Quota_Fee__c == null) {
            return null;
        }
        return (users[0].Quota_Fee__c / EOK).setScale(QUOTA_SCALE, System.RoundingMode.HALF_UP);
    }

    public class QuotaResult {
        @AuraEnabled public String rmUserId { get; set; }
        @AuraEnabled public Decimal quotaEok { get; set; }
        @AuraEnabled public String message { get; set; }
    }
}