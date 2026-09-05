/**
 * Funnel analysis is a snapshot over the running manager's team, resolved by
 * role hierarchy exactly like TeamDashboardControllerTest: RMs whose
 * UserRole.ParentRoleId is the manager's role. Users are setup objects and
 * Opportunities are not, so opportunity DML is wrapped in System.runAs to avoid
 * MIXED_DML_OPERATION. All test users use the System Administrator profile plus
 * the Priority_Dashboard_Access permission set so WITH USER_MODE queries clear
 * field-level security on the custom fields the controller reads.
 *
 * The org's active stages, in order, are 미팅 · 상품 확정 · 수수료 협의 · 심사 ·
 * 계약 체결 · Closed Won (Closed Lost is inactive-in-funnel and excluded). One
 * open deal is seeded in each pre-close stage plus one win and one loss, so the
 * cumulative "reached" counts and stage conversions are fully determined.
 *
 * Dwell figures are 0 here: CreatedDate and LastStageChangeDate are stamped at
 * insert (today) and the closed deals use today as CloseDate, so every dwell
 * span is zero. That exercises the dwell code paths deterministically; the
 * arithmetic itself is covered by the non-zero spans in production data.
 */
@isTest
private class TeamFunnelControllerTest {

    private static final Decimal FEE_RATE = 10; // percent — keeps the arithmetic readable
    private static final Decimal ONE_MILLION = 1000000;

    @TestSetup
    static void setup() {
        Profile admin = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        String stamp = String.valueOf(System.now().getTime()) + Crypto.getRandomInteger();

        User rmOne = buildUser(admin.Id, null, 'rm1', stamp);
        User rmTwo = buildUser(admin.Id, null, 'rm2', stamp);
        System.runAs(new User(Id = UserInfo.getUserId())) {
            UserRole managerRole = new UserRole(Name = 'TFC Manager ' + stamp);
            insert managerRole;
            UserRole rmRole = new UserRole(Name = 'TFC RM ' + stamp, ParentRoleId = managerRole.Id);
            insert rmRole;

            User manager = buildUser(admin.Id, managerRole.Id, 'mgr', stamp);
            rmOne.UserRoleId = rmRole.Id;
            rmTwo.UserRoleId = rmRole.Id;
            insert new List<User>{ manager, rmOne, rmTwo };

            // The controller reads Opportunity/Product custom fields WITH USER_MODE;
            // field access lives on this permission set, not the profile, so the
            // running user needs it or the funnel query throws.
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
            // one open deal in each pre-close active stage (fee = amount × 10%)
            openOpp('미팅 건', '미팅', ONE_MILLION, product.Id, rmOne.Id),           // 100,000 · Pipeline
            openOpp('상품확정 건', '상품 확정', ONE_MILLION * 2, product.Id, rmTwo.Id), // 200,000 · Best Case
            openOpp('수수료협의 건', '수수료 협의', ONE_MILLION, product.Id, rmOne.Id), // 100,000 · Pipeline
            openOpp('심사 건', '심사', ONE_MILLION, product.Id, rmTwo.Id),           // 100,000 · Best Case
            openOpp('계약체결 건', '계약 체결', ONE_MILLION, product.Id, rmOne.Id),   // 100,000 · Commit
            // this half-year's win → lands in the Closed Won stage (fee 300,000)
            closed('수주 건', 'Closed Won', ONE_MILLION * 3, product.Id, today, rmOne.Id),
            // this half-year's loss → leakage, no stage slot
            closed('실주 건', 'Closed Lost', ONE_MILLION * 2, product.Id, today, rmTwo.Id)
        };
    }

    @isTest
    static void shouldResolveTeamAndReturnPeriod_WhenRunAsManager() {
        TeamFunnelController.FunnelAnalysis analysis = runAsManager();

        Assert.areEqual(2, analysis.teamSize, '팀장 하위 역할 RM 2명');
        Assert.areEqual(periodLabelToday(), analysis.periodLabel, '오늘이 속한 반기 라벨');
    }

    @isTest
    static void shouldCountEachActiveStage_ExcludingClosedLost() {
        TeamFunnelController.FunnelAnalysis analysis = runAsManager();
        Map<String, TeamFunnelController.FunnelStage> byStage = stagesOf(analysis);

        Assert.areEqual(1, byStage.get('미팅').count, '미팅 1건');
        Assert.areEqual(1, byStage.get('상품 확정').count, '상품 확정 1건');
        Assert.areEqual(1, byStage.get('수수료 협의').count, '수수료 협의 1건');
        Assert.areEqual(1, byStage.get('심사').count, '심사 1건');
        Assert.areEqual(1, byStage.get('계약 체결').count, '계약 체결 1건');
        Assert.areEqual(1, byStage.get('Closed Won').count, '이번 반기 수주 1건');
        Assert.isFalse(byStage.containsKey('Closed Lost'), '실주 단계는 퍼널에서 제외');
    }

    @isTest
    static void shouldSumStageFeeRevenue_FromProductRate() {
        TeamFunnelController.FunnelAnalysis analysis = runAsManager();
        Map<String, TeamFunnelController.FunnelStage> byStage = stagesOf(analysis);

        Assert.areEqual(100000, byStage.get('미팅').feeRevenue, '1M × 10%');
        Assert.areEqual(200000, byStage.get('상품 확정').feeRevenue, '2M × 10%');
        Assert.areEqual(300000, byStage.get('Closed Won').feeRevenue, '3M × 10%');
    }

    @isTest
    static void shouldAccumulateReachedFromLastStageBackwards() {
        TeamFunnelController.FunnelAnalysis analysis = runAsManager();
        Map<String, TeamFunnelController.FunnelStage> byStage = stagesOf(analysis);

        // counts are 1 each across 6 stages → reached counts up from the end
        Assert.areEqual(6, byStage.get('미팅').reached, '전 단계를 거친 누적 6');
        Assert.areEqual(5, byStage.get('상품 확정').reached, '누적 5');
        Assert.areEqual(2, byStage.get('계약 체결').reached, '누적 2');
        Assert.areEqual(1, byStage.get('Closed Won').reached, '마지막 단계 누적 1');
    }

    @isTest
    static void shouldComputeStageConversionToNextStage() {
        TeamFunnelController.FunnelAnalysis analysis = runAsManager();
        Map<String, TeamFunnelController.FunnelStage> byStage = stagesOf(analysis);

        Assert.areEqual(83, byStage.get('미팅').conversionPercent, '5/6');
        Assert.areEqual(80, byStage.get('상품 확정').conversionPercent, '4/5');
        Assert.areEqual(50, byStage.get('계약 체결').conversionPercent, '1/2');
        Assert.areEqual(100, byStage.get('Closed Won').conversionPercent, '마지막 단계는 100');
    }

    @isTest
    static void shouldComputeDropFromPreviousStage() {
        TeamFunnelController.FunnelAnalysis analysis = runAsManager();
        Map<String, TeamFunnelController.FunnelStage> byStage = stagesOf(analysis);

        Assert.areEqual(0, byStage.get('미팅').dropFromPrevPercent, '첫 단계는 감소 없음');
        Assert.areEqual(17, byStage.get('상품 확정').dropFromPrevPercent, '100 - 5/6');
        Assert.areEqual(50, byStage.get('Closed Won').dropFromPrevPercent, '100 - 1/2');
    }

    @isTest
    static void shouldSplitForecastByCategory() {
        TeamFunnelController.FunnelAnalysis analysis = runAsManager();

        Assert.areEqual(100000, analysis.forecast.committed, '계약 체결(Commit)');
        Assert.areEqual(300000, analysis.forecast.bestCase, '상품 확정 + 심사(Best Case)');
        Assert.areEqual(200000, analysis.forecast.pipeline, '미팅 + 수수료 협의(Pipeline)');
    }

    @isTest
    static void shouldComputeOverallConversionAndLeakage() {
        TeamFunnelController.FunnelAnalysis analysis = runAsManager();

        Assert.areEqual(1, analysis.leakageCount, '반기 실주 1건');
        Assert.areEqual(50, analysis.overallConversionPercent, '수주 1 ÷ 마감 2 = 50%');
    }

    @isTest
    static void shouldReportZeroDwell_WhenAllSpansSameDay() {
        TeamFunnelController.FunnelAnalysis analysis = runAsManager();
        Map<String, TeamFunnelController.FunnelStage> byStage = stagesOf(analysis);

        Assert.areEqual(0, analysis.avgDealDwellDays, '같은 날 마감이면 사이클 0');
        Assert.areEqual(0, byStage.get('미팅').avgDwellDays, '오늘 진입한 단계 체류 0');
    }

    @isTest
    static void shouldBuildSixMonthTrend_WithNewOppsInCurrentMonth() {
        TeamFunnelController.FunnelAnalysis analysis = runAsManager();

        Assert.areEqual(6, analysis.monthlyTrend.size(), '반기 6개월');

        TeamFunnelController.MonthlyPoint thisMonth = pointFor(analysis, Date.today().month() + '월');
        Assert.areEqual(7, thisMonth.newCount, '이번 달 생성 7건');
        // fee: 100k+200k+100k+100k+100k(open) + 300k(won) + 200k(lost) = 1,100,000
        Assert.areEqual(1100000, thisMonth.feeRevenue, '이번 달 생성 기회 수수료 합');
    }

    @isTest
    static void shouldFallBackToSelf_WhenUserHasNoSubordinateRoles() {
        User rmOne = [SELECT Id FROM User WHERE Alias = 'rm1' AND LastName = 'TFC' LIMIT 1];

        Test.startTest();
        System.runAs(rmOne) {
            TeamFunnelController.FunnelAnalysis analysis = TeamFunnelController.getFunnelAnalysis();
            Assert.areEqual(1, analysis.teamSize, '하위 역할이 없으면 본인만');
            Map<String, TeamFunnelController.FunnelStage> byStage = stagesOf(analysis);
            // rm1 owns 미팅·수수료 협의·계약 체결 open deals plus the win
            Assert.areEqual(1, byStage.get('계약 체결').count, '본인 계약 체결 1건');
            Assert.areEqual(0, byStage.get('상품 확정').count, 'rm2 소유 건은 제외');
        }
        Test.stopTest();
    }

    // ── helpers ──────────────────────────────────────────────

    private static TeamFunnelController.FunnelAnalysis runAsManager() {
        User manager = [SELECT Id FROM User WHERE Alias = 'mgr' AND LastName = 'TFC' LIMIT 1];
        TeamFunnelController.FunnelAnalysis analysis;
        Test.startTest();
        System.runAs(manager) {
            analysis = TeamFunnelController.getFunnelAnalysis();
        }
        Test.stopTest();
        return analysis;
    }

    private static String periodLabelToday() {
        Date d = Date.today();
        return String.valueOf(d.year()) + (d.month() <= 6 ? ' 상반기' : ' 하반기');
    }

    private static User buildUser(Id profileId, Id roleId, String alias, String stamp) {
        return new User(
            ProfileId = profileId,
            UserRoleId = roleId,
            LastName = 'TFC',
            Alias = alias,
            Email = alias + '.tfc@example.com',
            Username = alias + '.tfc.' + stamp + '@example.com.invalid',
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

    private static Map<String, TeamFunnelController.FunnelStage> stagesOf(TeamFunnelController.FunnelAnalysis analysis) {
        Map<String, TeamFunnelController.FunnelStage> byStage =
            new Map<String, TeamFunnelController.FunnelStage>();
        for (TeamFunnelController.FunnelStage stage : analysis.stages) {
            byStage.put(stage.stageName, stage);
        }
        return byStage;
    }

    private static TeamFunnelController.MonthlyPoint pointFor(TeamFunnelController.FunnelAnalysis analysis, String monthLabel) {
        for (TeamFunnelController.MonthlyPoint point : analysis.monthlyTrend) {
            if (point.monthLabel == monthLabel) {
                return point;
            }
        }
        return null;
    }
}