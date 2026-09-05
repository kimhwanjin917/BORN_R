/**
 * Risk-zone analysis over the running manager's team, resolved by role hierarchy
 * exactly like TeamDashboardControllerTest / TeamFunnelControllerTest: RMs whose
 * UserRole.ParentRoleId is the manager's role. Users are setup objects and
 * Opportunities are not, so opportunity DML is wrapped in System.runAs to avoid
 * MIXED_DML_OPERATION. All test users use the System Administrator profile plus
 * the Priority_Dashboard_Access permission set so WITH USER_MODE queries clear
 * field-level security on the custom fields the controller reads.
 *
 * Risk level is driven entirely by Last_Meeting_Date__c (a writable custom
 * field), so the three levels are seeded deterministically: met today → LOW,
 * met 20 days ago → MEDIUM (>14), met 40 days ago → HIGH (>30). Closed deals are
 * seeded too, to prove the risk zone counts open pipeline only.
 *
 * Stage-dwell is 0 here: CreatedDate and LastStageChangeDate are stamped at
 * insert (today), so every open deal falls in the 0-14일 bucket and nothing is a
 * long-dwell deal — the same deterministic dwell=0 baseline documented in
 * TeamFunnelControllerTest. The dwell arithmetic itself is covered by the
 * non-zero spans in production data.
 */
@isTest
private class TeamRiskControllerTest {

    private static final Decimal FEE_RATE = 10; // percent — keeps the arithmetic readable
    private static final Decimal ONE_MILLION = 1000000;

    @TestSetup
    static void setup() {
        Profile admin = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        String stamp = String.valueOf(System.now().getTime()) + Crypto.getRandomInteger();

        User rmOne = buildUser(admin.Id, null, 'rm1', stamp);
        User rmTwo = buildUser(admin.Id, null, 'rm2', stamp);
        System.runAs(new User(Id = UserInfo.getUserId())) {
            UserRole managerRole = new UserRole(Name = 'TRC Manager ' + stamp);
            insert managerRole;
            UserRole rmRole = new UserRole(Name = 'TRC RM ' + stamp, ParentRoleId = managerRole.Id);
            insert rmRole;

            User manager = buildUser(admin.Id, managerRole.Id, 'mgr', stamp);
            rmOne.UserRoleId = rmRole.Id;
            rmTwo.UserRoleId = rmRole.Id;
            insert new List<User>{ manager, rmOne, rmTwo };

            // The controller reads Opportunity/Product custom fields WITH USER_MODE;
            // field access lives on this permission set, not the profile, so the
            // running user needs it or the open-pipeline query throws.
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
            // rm1 open, met today → LOW · fee 100,000
            openOpp('저위험 건', '미팅', ONE_MILLION, product.Id, today, rmOne.Id),
            // rm1 open, met 20 days ago (>14) → MEDIUM · fee 200,000
            openOpp('중위험 건', '심사', ONE_MILLION * 2, product.Id, today.addDays(-20), rmOne.Id),
            // rm2 open, met 40 days ago (>30) → HIGH · fee 300,000
            openOpp('고위험 건', '상품 확정', ONE_MILLION * 3, product.Id, today.addDays(-40), rmTwo.Id),
            // rm2 open, never met (null) → measured from creation today → LOW · fee 100,000
            openOpp('신규 건', '계약 체결', ONE_MILLION, product.Id, null, rmTwo.Id),
            // rm1 won → excluded: a closed deal carries no risk
            closed('수주 건', 'Closed Won', ONE_MILLION * 5, product.Id, today, rmOne.Id),
            // rm2 lost → excluded
            closed('실주 건', 'Closed Lost', ONE_MILLION * 2, product.Id, today, rmTwo.Id)
        };
    }

    @isTest
    static void shouldResolveTeamAndReturnPeriod_WhenRunAsManager() {
        TeamRiskController.RiskZone zone = runAsManager();

        Assert.areEqual(2, zone.teamSize, '팀장 하위 역할 RM 2명');
        Assert.areEqual(periodLabelToday(), zone.periodLabel, '오늘이 속한 반기 라벨');
    }

    @isTest
    static void shouldCountOpenPipelineOnly_ExcludingClosedDeals() {
        TeamRiskController.RiskZone zone = runAsManager();

        Assert.areEqual(4, zone.openDealCount, '진행 중 기회 4건만(수주·실주 제외)');
    }

    @isTest
    static void shouldClassifyRiskLevel_FromContactStaleness() {
        TeamRiskController.RiskZone zone = runAsManager();

        Assert.areEqual(1, zone.highRiskCount, '40일 경과 1건이 HIGH');
        Assert.areEqual(1, zone.mediumRiskCount, '20일 경과 1건이 MEDIUM');
    }

    @isTest
    static void shouldBuildRiskDonut_AcrossAllLevels() {
        TeamRiskController.RiskZone zone = runAsManager();
        Map<String, Integer> countByLevel = donutOf(zone);

        Assert.areEqual(1, countByLevel.get('HIGH'), 'HIGH 1건');
        Assert.areEqual(1, countByLevel.get('MEDIUM'), 'MEDIUM 1건');
        Assert.areEqual(2, countByLevel.get('LOW'), '오늘 접촉 2건이 LOW');
    }

    @isTest
    static void shouldListRiskDealsSortedByStaleness_HighAndMediumOnly() {
        TeamRiskController.RiskZone zone = runAsManager();

        Assert.areEqual(2, zone.riskDeals.size(), 'HIGH·MEDIUM 건만 리스트에 노출');
        Assert.areEqual('HIGH', zone.riskDeals[0].riskLevel, '가장 오래 방치된 건이 먼저');
        Assert.areEqual(40, zone.riskDeals[0].daysSinceContact, 'HIGH 건 40일 경과');
        Assert.areEqual('MEDIUM', zone.riskDeals[1].riskLevel, '그다음이 MEDIUM');
        Assert.areEqual(20, zone.riskDeals[1].daysSinceContact, 'MEDIUM 건 20일 경과');
    }

    @isTest
    static void shouldCarryFeeAndOwner_OnRiskDeal() {
        TeamRiskController.RiskZone zone = runAsManager();

        TeamRiskController.RiskDeal top = zone.riskDeals[0];
        Assert.areEqual(300000, top.feeRevenue, '3M × 10% 수수료');
        Assert.areEqual('상품 확정', top.stageName, 'HIGH 건 단계');
        Assert.isNotNull(top.rmName, 'RM 이름이 채워져야 함');
    }

    @isTest
    static void shouldMeasureFromCreation_WhenNeverMet() {
        TeamRiskController.RiskZone zone = runAsManager();
        Map<String, Integer> countByLevel = donutOf(zone);

        // The never-met deal (신규 건) was created today, so it is measured from
        // creation and lands in LOW alongside the deal met today.
        Assert.areEqual(2, countByLevel.get('LOW'), '미접촉 건은 생성일 기준이라 LOW');
    }

    @isTest
    static void shouldBucketAllOpenDealsByDwell_ZeroDwellBaseline() {
        TeamRiskController.RiskZone zone = runAsManager();
        Map<String, Integer> countByBucket = bucketsOf(zone);

        Assert.areEqual(4, countByBucket.get('0-14일'), '오늘 진입해 체류 0 → 전건 첫 버킷');
        Assert.areEqual(0, countByBucket.get('15-30일'), '체류 0이라 상위 버킷은 비어 있음');
        Assert.areEqual(0, countByBucket.get('31-60일'), '체류 0이라 상위 버킷은 비어 있음');
        Assert.areEqual(0, countByBucket.get('60일+'), '체류 0이라 상위 버킷은 비어 있음');
        Assert.areEqual(4, zone.openDealCount, '버킷 합계 = 진행 건수');
    }

    @isTest
    static void shouldReportNoLongDwellDeals_WhenNoStageOlderThanThreshold() {
        TeamRiskController.RiskZone zone = runAsManager();

        Assert.areEqual(0, zone.longDwellTop5.size(), '체류 0이면 장기 체류(60일+) 없음');
    }

    @isTest
    static void shouldFallBackToSelf_WhenUserHasNoSubordinateRoles() {
        User rmOne = [SELECT Id FROM User WHERE Alias = 'rm1' AND LastName = 'TRC' LIMIT 1];

        Test.startTest();
        System.runAs(rmOne) {
            TeamRiskController.RiskZone zone = TeamRiskController.getRiskZone();
            Assert.areEqual(1, zone.teamSize, '하위 역할이 없으면 본인만');
            // rm1 owns two open deals (저위험·중위험); the win is closed and excluded.
            Assert.areEqual(2, zone.openDealCount, '본인 진행 건 2건');
            Assert.areEqual(1, zone.mediumRiskCount, '본인 20일 경과 1건이 MEDIUM');
        }
        Test.stopTest();
    }

    // ── helpers ──────────────────────────────────────────────

    private static TeamRiskController.RiskZone runAsManager() {
        User manager = [SELECT Id FROM User WHERE Alias = 'mgr' AND LastName = 'TRC' LIMIT 1];
        TeamRiskController.RiskZone zone;
        Test.startTest();
        System.runAs(manager) {
            zone = TeamRiskController.getRiskZone();
        }
        Test.stopTest();
        return zone;
    }

    private static String periodLabelToday() {
        Date d = Date.today();
        return String.valueOf(d.year()) + (d.month() <= 6 ? ' 상반기' : ' 하반기');
    }

    private static User buildUser(Id profileId, Id roleId, String alias, String stamp) {
        return new User(
            ProfileId = profileId,
            UserRoleId = roleId,
            LastName = 'TRC',
            Alias = alias,
            Email = alias + '.trc@example.com',
            Username = alias + '.trc.' + stamp + '@example.com.invalid',
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
        Id ownerId
    ) {
        return new Opportunity(
            Name = name,
            StageName = stage,
            Amount = amount,
            CloseDate = Date.today().addDays(60),
            Primary_Product__c = productId,
            Last_Meeting_Date__c = lastMeeting,
            OwnerId = ownerId
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

    private static Map<String, Integer> donutOf(TeamRiskController.RiskZone zone) {
        Map<String, Integer> countByLevel = new Map<String, Integer>();
        for (TeamRiskController.RiskCount slice : zone.riskDistribution) {
            countByLevel.put(slice.level, slice.count);
        }
        return countByLevel;
    }

    private static Map<String, Integer> bucketsOf(TeamRiskController.RiskZone zone) {
        Map<String, Integer> countByBucket = new Map<String, Integer>();
        for (TeamRiskController.DwellBucket bucket : zone.dwellDistribution) {
            countByBucket.put(bucket.label, bucket.count);
        }
        return countByBucket;
    }
}