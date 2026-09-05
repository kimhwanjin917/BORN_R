/**
 * Team is resolved by role hierarchy: RMs whose UserRole.ParentRoleId is the
 * running manager's role. Users are setup objects and Opportunities are not, so
 * opportunity DML is wrapped in System.runAs to avoid MIXED_DML_OPERATION. All
 * test users use the System Administrator profile so WITH USER_MODE queries are
 * not blocked by field-level security on the custom fields the controller reads.
 *
 * Stage names are the org's own active stages (미팅 … 심사 … Closed Won); the
 * earlier English stages are inactive here.
 */
@isTest
private class TeamDashboardControllerTest {

    private static final Decimal FEE_RATE = 10; // percent — keeps the arithmetic readable
    private static final Decimal ONE_MILLION = 1000000;

    @TestSetup
    static void setup() {
        Profile admin = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        String stamp = String.valueOf(System.now().getTime()) + Crypto.getRandomInteger();

        // Roles and users are setup objects; isolating their DML in runAs keeps
        // it out of the Opportunity transaction that follows (MIXED_DML). The
        // opportunities themselves are inserted by the test-running admin, not a
        // freshly-minted user, so create-time automation does not trip field
        // access on the custom fields. Mirrors MyKpiControllerTest.
        User rmOne = buildUser(admin.Id, null, 'rm1', stamp);
        User rmTwo = buildUser(admin.Id, null, 'rm2', stamp);
        System.runAs(new User(Id = UserInfo.getUserId())) {
            UserRole managerRole = new UserRole(Name = 'TDC Manager ' + stamp);
            insert managerRole;
            UserRole rmRole = new UserRole(Name = 'TDC RM ' + stamp, ParentRoleId = managerRole.Id);
            insert rmRole;

            User manager = buildUser(admin.Id, managerRole.Id, 'mgr', stamp);
            rmOne.UserRoleId = rmRole.Id;
            rmTwo.UserRoleId = rmRole.Id;
            insert new List<User>{ manager, rmOne, rmTwo };

            // The controller reads Opportunity/Product custom fields WITH USER_MODE.
            // Field access for those lives on this permission set, not the profile,
            // so the running user needs it or the pipeline query throws — matching
            // how a real dashboard user is provisioned.
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
            // rm1: won 5M → fee 500,000
            closed('rm1 수주', 'Closed Won', ONE_MILLION * 5, product.Id, today, rmOne.Id),
            // rm1: open 미팅, fresh (met today), probability 50
            openOpp('rm1 진행', '미팅', ONE_MILLION, product.Id, today, rmOne.Id, 50),
            // rm1: lost — closes the conversion denominator
            closed('rm1 실주', 'Closed Lost', ONE_MILLION, product.Id, today, rmOne.Id),

            // rm2: won 3M → fee 300,000
            closed('rm2 수주', 'Closed Won', ONE_MILLION * 3, product.Id, today, rmTwo.Id),
            // rm2: open 심사, last contact 20 days ago (> 14) → at risk, probability 25
            openOpp('rm2 위험', '심사', ONE_MILLION * 2, product.Id, today.addDays(-20), rmTwo.Id, 25)
        };
    }

    @isTest
    static void shouldResolveTeamAndSumWonFee_WhenRunAsManager() {
        TeamDashboardController.TeamSummary summary = runAsManager();

        Assert.areEqual(2, summary.teamSize, '팀장 하위 역할 RM 2명');
        Assert.areEqual(800000, summary.teamAchievedFee, 'rm1 500,000 + rm2 300,000');
    }

    @isTest
    static void shouldCountOpenDealsAndNewOpps_WhenRunAsManager() {
        TeamDashboardController.TeamSummary summary = runAsManager();

        Assert.areEqual(2, summary.openDealCount, '진행 중 기회는 팀 전체 2건');
        Assert.areEqual(5, summary.newOppCount, '이번 반기 생성된 기회 5건(수주·실주 포함)');
    }

    @isTest
    static void shouldFlagAtRiskDeal_WhenContactOlderThanThreshold() {
        TeamDashboardController.TeamSummary summary = runAsManager();

        Assert.areEqual(1, summary.riskDealCount, '20일 경과 심사 건 1건만 리스크');
    }

    @isTest
    static void shouldWeightExpectedFeeByProbability_WhenRunAsManager() {
        Map<String, Decimal> probByName = new Map<String, Decimal>();
        for (Opportunity opp : [SELECT Name, Probability FROM Opportunity WHERE IsClosed = false]) {
            probByName.put(opp.Name, opp.Probability);
        }
        // fee(rm1 진행)=100,000 · fee(rm2 위험)=200,000
        Decimal expected = 100000 * probByName.get('rm1 진행') / 100
            + 200000 * probByName.get('rm2 위험') / 100;

        TeamDashboardController.TeamSummary summary = runAsManager();

        Assert.areEqual(expected, summary.expectedFee, '예상 수수료는 성공확률 가중합');
    }

    @isTest
    static void shouldComputeConversionRate_FromClosedDeals() {
        TeamDashboardController.TeamSummary summary = runAsManager();

        // 수주 2건 / (수주 2 + 실주 1) = 67%
        Assert.areEqual(67, summary.avgConversionPercent, '수주 2 ÷ 마감 3 = 67%');
    }

    @isTest
    static void shouldComputeAchievementPercent_FromReturnedTarget() {
        TeamDashboardController.TeamSummary summary = runAsManager();

        Integer expected = summary.teamTargetFee <= 0
            ? 0
            : (800000 / summary.teamTargetFee * 100).setScale(0, System.RoundingMode.HALF_UP).intValue();
        Assert.areEqual(expected, summary.achievementPercent, '달성률 = 실적 ÷ 목표');
    }

    @isTest
    static void shouldRankRmsByAchievedFeeDescending_WhenRunAsManager() {
        TeamDashboardController.TeamSummary summary = runAsManager();

        Assert.areEqual(2, summary.rmRanking.size(), 'RM 2명 모두 랭킹에 노출');
        Assert.areEqual(500000, summary.rmRanking[0].achievedFee, '실적이 큰 RM이 먼저');
        Assert.areEqual(300000, summary.rmRanking[1].achievedFee, '실적이 작은 RM이 나중');
    }

    @isTest
    static void shouldBuildStageDonut_WithOpenPlusThisQuartersWins() {
        TeamDashboardController.TeamSummary summary = runAsManager();

        Map<String, TeamDashboardController.StageSlice> byStage = slicesOf(summary);
        Assert.areEqual(1, byStage.get('미팅').count, '미팅 진행 1건');
        Assert.areEqual(1, byStage.get('심사').count, '심사 진행 1건');
        Assert.areEqual(2, byStage.get('Closed Won').count, '이번 분기 수주 2건');
        Assert.areEqual(800000, byStage.get('Closed Won').feeRevenue, '수주 수수료 합');
        Assert.isFalse(byStage.containsKey('Closed Lost'), '실주 단계는 도넛에서 제외');
    }

    @isTest
    static void shouldFallBackToSelf_WhenUserHasNoSubordinateRoles() {
        User rmOne = [SELECT Id FROM User WHERE Alias = 'rm1' AND LastName = 'TDC' LIMIT 1];

        Test.startTest();
        System.runAs(rmOne) {
            TeamDashboardController.TeamSummary summary = TeamDashboardController.getTeamSummary();
            Assert.areEqual(1, summary.teamSize, '하위 역할이 없으면 본인만');
            Assert.areEqual(500000, summary.teamAchievedFee, '본인 수주 수수료만');
        }
        Test.stopTest();
    }

    // ── helpers ──────────────────────────────────────────────

    private static TeamDashboardController.TeamSummary runAsManager() {
        User manager = [SELECT Id FROM User WHERE Alias = 'mgr' AND LastName = 'TDC' LIMIT 1];
        TeamDashboardController.TeamSummary summary;
        Test.startTest();
        System.runAs(manager) {
            summary = TeamDashboardController.getTeamSummary();
        }
        Test.stopTest();
        return summary;
    }

    private static User buildUser(Id profileId, Id roleId, String alias, String stamp) {
        return new User(
            ProfileId = profileId,
            UserRoleId = roleId,
            LastName = 'TDC',
            Alias = alias,
            Email = alias + '.tdc@example.com',
            Username = alias + '.tdc.' + stamp + '@example.com.invalid',
            TimeZoneSidKey = 'Asia/Seoul',
            LocaleSidKey = 'ko_KR',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
    }

    private static Opportunity openOpp(
        String name,
        String stage,
        Decimal amount,
        Id productId,
        Date lastMeeting,
        Id ownerId,
        Integer probability
    ) {
        return new Opportunity(
            Name = name,
            StageName = stage,
            Amount = amount,
            CloseDate = Date.today().addDays(60),
            Primary_Product__c = productId,
            Last_Meeting_Date__c = lastMeeting,
            OwnerId = ownerId,
            Probability = probability
        );
    }

    private static Opportunity closed(
        String name,
        String stage,
        Decimal amount,
        Id productId,
        Date closeDate,
        Id ownerId
    ) {
        return new Opportunity(
            Name = name,
            StageName = stage,
            Amount = amount,
            CloseDate = closeDate,
            Primary_Product__c = productId,
            Last_Meeting_Date__c = closeDate,
            OwnerId = ownerId
        );
    }

    private static Map<String, TeamDashboardController.StageSlice> slicesOf(
        TeamDashboardController.TeamSummary summary
    ) {
        Map<String, TeamDashboardController.StageSlice> byStage =
            new Map<String, TeamDashboardController.StageSlice>();
        for (TeamDashboardController.StageSlice slice : summary.stageSlices) {
            byStage.put(slice.stageName, slice);
        }
        return byStage;
    }
}