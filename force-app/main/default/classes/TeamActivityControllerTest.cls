/**
 * Dwell-and-activity analysis is a snapshot over the running manager's team,
 * resolved by role hierarchy exactly like TeamDashboardControllerTest and
 * TeamFunnelControllerTest: RMs whose UserRole.ParentRoleId is the manager's
 * role. Users are setup objects while Opportunity/Task/Event are not, so all
 * non-setup DML is inserted by the test-running admin (outside System.runAs) to
 * avoid MIXED_DML_OPERATION. Every test user uses the System Administrator
 * profile plus the Priority_Dashboard_Access permission set so WITH USER_MODE
 * queries clear field-level security on the custom fields the controller reads.
 *
 * The org's active, not-yet-closed stages, in order, are 미팅 · 상품 확정 ·
 * 수수료 협의 · 심사 · 계약 체결 — these are the heatmap columns (closed stages
 * are excluded). Two RMs are seeded: rm1 wins 5M and carries two open deals plus
 * three activities; rm2 wins 3M and carries one open deal plus one activity, so
 * fee, open counts, and activity counts are fully determined.
 *
 * Every open deal is inserted today, so LastStageChangeDate/CreatedDate equal
 * today and every current-stage dwell span is zero. That exercises the dwell
 * heatmap paths deterministically; the arithmetic itself is covered by the
 * non-zero spans in production data.
 *
 * Per-RM target is asserted against the returned team target rather than a
 * literal, because KPI_Target__mdt is org configuration this test cannot insert.
 */
@isTest
private class TeamActivityControllerTest {

    private static final Decimal FEE_RATE = 10; // percent — keeps the arithmetic readable
    private static final Decimal ONE_MILLION = 1000000;

    @TestSetup
    static void setup() {
        Profile admin = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        String stamp = String.valueOf(System.now().getTime()) + Crypto.getRandomInteger();

        User rmOne = buildUser(admin.Id, null, 'rm1', stamp);
        User rmTwo = buildUser(admin.Id, null, 'rm2', stamp);
        System.runAs(new User(Id = UserInfo.getUserId())) {
            UserRole managerRole = new UserRole(Name = 'TAC Manager ' + stamp);
            insert managerRole;
            UserRole rmRole = new UserRole(Name = 'TAC RM ' + stamp, ParentRoleId = managerRole.Id);
            insert rmRole;

            User manager = buildUser(admin.Id, managerRole.Id, 'mgr', stamp);
            rmOne.UserRoleId = rmRole.Id;
            rmTwo.UserRoleId = rmRole.Id;
            insert new List<User>{ manager, rmOne, rmTwo };

            // The controller reads Opportunity/Product custom fields WITH USER_MODE;
            // field access lives on this permission set, not the profile, so the
            // running user needs it or the queries throw.
            PermissionSet dashboardAccess = [
                SELECT Id FROM PermissionSet WHERE Name = 'Priority_Dashboard_Access' LIMIT 1
            ];
            insert new List<PermissionSetAssignment>{
                new PermissionSetAssignment(AssigneeId = manager.Id, PermissionSetId = dashboardAccess.Id),
                new PermissionSetAssignment(AssigneeId = rmOne.Id, PermissionSetId = dashboardAccess.Id),
                new PermissionSetAssignment(AssigneeId = rmTwo.Id, PermissionSetId = dashboardAccess.Id)
            };
        }

        Product2 product = new Product2(Name = 'RP', IsActive = true, Default_Fee_Rate__c = FEE_RATE);
        insert product;

        Date today = Date.today();
        insert new List<Opportunity>{
            // rm1: this half-year's win → fee 500,000, one won deal
            closed('rm1 수주', 'Closed Won', ONE_MILLION * 5, product.Id, today, rmOne.Id),
            // rm1: two open deals in distinct stages → openDeals 2, dwell 0
            openOpp('rm1 미팅', '미팅', ONE_MILLION, product.Id, rmOne.Id),
            openOpp('rm1 심사', '심사', ONE_MILLION, product.Id, rmOne.Id),

            // rm2: this half-year's win → fee 300,000, one won deal
            closed('rm2 수주', 'Closed Won', ONE_MILLION * 3, product.Id, today, rmTwo.Id),
            // rm2: one open deal → openDeals 1, dwell 0
            openOpp('rm2 상품확정', '상품 확정', ONE_MILLION, product.Id, rmTwo.Id)
        };

        // Activity is counted in-period: tasks by due date, events by start.
        // rm1 → 2 tasks + 1 event = 3 · rm2 → 1 task = 1.
        insert new List<Task>{
            task('rm1 할일 A', today, rmOne.Id),
            task('rm1 할일 B', today, rmOne.Id),
            task('rm2 할일 A', today, rmTwo.Id)
        };
        insert new List<Event>{
            event('rm1 미팅 일정', rmOne.Id)
        };
    }

    @isTest
    static void shouldResolveTeamAndReturnPeriod_WhenRunAsManager() {
        TeamActivityController.ActivityAnalysis analysis = runAsManager();

        Assert.areEqual(2, analysis.teamSize, '팀장 하위 역할 RM 2명');
        Assert.areEqual(periodLabelToday(), analysis.periodLabel, '오늘이 속한 반기 라벨');
        Assert.areEqual(2, analysis.rows.size(), 'RM 2명 모두 행으로 노출');
    }

    @isTest
    static void shouldExposeActiveOpenStagesAsHeatmapColumns_ExcludingClosed() {
        TeamActivityController.ActivityAnalysis analysis = runAsManager();

        Assert.areEqual(
            new List<String>{ '미팅', '상품 확정', '수수료 협의', '심사', '계약 체결' },
            analysis.stageNames,
            '마감 단계를 제외한 활성 단계가 정렬 순서대로'
        );
    }

    @isTest
    static void shouldSumWonFeePerRm_FromProductRate() {
        TeamActivityController.ActivityAnalysis analysis = runAsManager();
        Map<Id, TeamActivityController.RmActivityRow> byRm = rowsByRmId(analysis);

        Assert.areEqual(500000, byRm.get(rmId('rm1')).achievedFee, 'rm1 5M × 10%');
        Assert.areEqual(1, byRm.get(rmId('rm1')).wonDeals, 'rm1 수주 1건');
        Assert.areEqual(300000, byRm.get(rmId('rm2')).achievedFee, 'rm2 3M × 10%');
    }

    @isTest
    static void shouldCountOpenDealsPerRm_ExcludingClosed() {
        TeamActivityController.ActivityAnalysis analysis = runAsManager();
        Map<Id, TeamActivityController.RmActivityRow> byRm = rowsByRmId(analysis);

        Assert.areEqual(2, byRm.get(rmId('rm1')).openDeals, 'rm1 진행 2건');
        Assert.areEqual(1, byRm.get(rmId('rm2')).openDeals, 'rm2 진행 1건');
    }

    @isTest
    static void shouldSplitTeamTargetEvenlyPerRm_AndDeriveAchievement() {
        TeamActivityController.ActivityAnalysis analysis = runAsManager();
        Map<Id, TeamActivityController.RmActivityRow> byRm = rowsByRmId(analysis);

        Decimal expectedTarget = analysis.teamTargetFee <= 0
            ? 0
            : (analysis.teamTargetFee / analysis.teamSize).setScale(2, System.RoundingMode.HALF_UP);
        Integer expectedPercent = expectedTarget <= 0
            ? 0
            : (500000 / expectedTarget * 100).setScale(0, System.RoundingMode.HALF_UP).intValue();

        Assert.areEqual(expectedTarget, byRm.get(rmId('rm1')).targetFee, 'RM 목표는 팀 목표 ÷ 팀원 수');
        Assert.areEqual(expectedPercent, byRm.get(rmId('rm1')).achievementPercent, '달성률 = 실적 ÷ RM 목표');
    }

    @isTest
    static void shouldCountActivityPerRm_FromTasksAndEvents() {
        TeamActivityController.ActivityAnalysis analysis = runAsManager();
        Map<Id, TeamActivityController.RmActivityRow> byRm = rowsByRmId(analysis);

        Assert.areEqual(3, byRm.get(rmId('rm1')).activityCount, 'rm1 할일 2 + 일정 1');
        Assert.areEqual(1, byRm.get(rmId('rm2')).activityCount, 'rm2 할일 1');
    }

    @isTest
    static void shouldReportZeroDwell_WhenOpenDealsEnteredStageToday() {
        TeamActivityController.ActivityAnalysis analysis = runAsManager();
        Map<Id, TeamActivityController.RmActivityRow> byRm = rowsByRmId(analysis);

        TeamActivityController.RmActivityRow rmOneRow = byRm.get(rmId('rm1'));
        // rm1 has an open deal in 미팅 and 심사; both entered today → dwell 0.
        Assert.areEqual(0, rmOneRow.dwellByStage[stageIndex(analysis, '미팅')], '오늘 진입한 미팅 체류 0');
        Assert.areEqual(0, rmOneRow.dwellByStage[stageIndex(analysis, '심사')], '오늘 진입한 심사 체류 0');
        // rm1 has nothing in 상품 확정 → column stays 0.
        Assert.areEqual(0, rmOneRow.dwellByStage[stageIndex(analysis, '상품 확정')], '해당 단계 진행 건 없으면 0');
        Assert.areEqual(analysis.stageNames.size(), rmOneRow.dwellByStage.size(), '체류 배열은 단계 수와 정렬');
    }

    @isTest
    static void shouldFallBackToSelf_WhenUserHasNoSubordinateRoles() {
        User rmOne = [SELECT Id FROM User WHERE Alias = 'rm1' AND LastName = 'TAC' LIMIT 1];

        Test.startTest();
        System.runAs(rmOne) {
            TeamActivityController.ActivityAnalysis analysis = TeamActivityController.getActivityAnalysis();
            Assert.areEqual(1, analysis.teamSize, '하위 역할이 없으면 본인만');
            Assert.areEqual(1, analysis.rows.size(), '본인 행만');
            Assert.areEqual(500000, analysis.rows[0].achievedFee, '본인 수주 수수료만');
            Assert.areEqual(2, analysis.rows[0].openDeals, '본인 진행 2건');
        }
        Test.stopTest();
    }

    // ── helpers ──────────────────────────────────────────────

    private static TeamActivityController.ActivityAnalysis runAsManager() {
        User manager = [SELECT Id FROM User WHERE Alias = 'mgr' AND LastName = 'TAC' LIMIT 1];
        TeamActivityController.ActivityAnalysis analysis;
        Test.startTest();
        System.runAs(manager) {
            analysis = TeamActivityController.getActivityAnalysis();
        }
        Test.stopTest();
        return analysis;
    }

    private static Id rmId(String alias) {
        return [SELECT Id FROM User WHERE Alias = :alias AND LastName = 'TAC' LIMIT 1].Id;
    }

    private static String periodLabelToday() {
        Date d = Date.today();
        return String.valueOf(d.year()) + (d.month() <= 6 ? ' 상반기' : ' 하반기');
    }

    private static Integer stageIndex(TeamActivityController.ActivityAnalysis analysis, String stageName) {
        return analysis.stageNames.indexOf(stageName);
    }

    private static Map<Id, TeamActivityController.RmActivityRow> rowsByRmId(
        TeamActivityController.ActivityAnalysis analysis
    ) {
        Map<Id, TeamActivityController.RmActivityRow> byRm =
            new Map<Id, TeamActivityController.RmActivityRow>();
        for (TeamActivityController.RmActivityRow row : analysis.rows) {
            byRm.put(row.rmId, row);
        }
        return byRm;
    }

    private static User buildUser(Id profileId, Id roleId, String alias, String stamp) {
        return new User(
            ProfileId = profileId,
            UserRoleId = roleId,
            LastName = 'TAC',
            Alias = alias,
            Email = alias + '.tac@example.com',
            Username = alias + '.tac.' + stamp + '@example.com.invalid',
            TimeZoneSidKey = 'Asia/Seoul',
            LocaleSidKey = 'ko_KR',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
    }

    private static Opportunity openOpp(String name, String stage, Decimal amount, Id productId, Id ownerId) {
        return new Opportunity(
            Name = name,
            StageName = stage,
            Amount = amount,
            CloseDate = Date.today().addDays(60),
            Primary_Product__c = productId,
            OwnerId = ownerId
        );
    }

    private static Opportunity closed(String name, String stage, Decimal amount, Id productId, Date closeDate, Id ownerId) {
        return new Opportunity(
            Name = name,
            StageName = stage,
            Amount = amount,
            CloseDate = closeDate,
            Primary_Product__c = productId,
            OwnerId = ownerId
        );
    }

    private static Task task(String subject, Date dueDate, Id ownerId) {
        return new Task(
            Subject = subject,
            ActivityDate = dueDate,
            Status = 'Not Started',
            Priority = 'Normal',
            OwnerId = ownerId
        );
    }

    private static Event event(String subject, Id ownerId) {
        return new Event(
            Subject = subject,
            StartDateTime = Datetime.now(),
            DurationInMinutes = 60,
            OwnerId = ownerId
        );
    }
}