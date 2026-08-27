/**
 * 본이 대시보드 데이터 조회. SOQL 전용, 콜아웃 없음.
 * without sharing 이유: 플랫폼 이벤트 트리거(Automated Process 사용자) 경로에서도 RM 데이터를 읽어야 함.
 * 조회 범위는 항상 OwnerId 로 제한한다. (2026-08-27 사용자 승인)
 */
public without sharing class BoniDashboardService {

    public class Settings {
        public Integer maturityWindowDays = 7;
        public Integer signalDays = 3;
        public Integer staleDays = 14;
        public Integer briefingHour = 7;
        public Integer wrapupHour = 18;
    }

    private static final Decimal SIGNAL_MIN_RELEVANCE = 70;
    private static final Decimal SIGNAL_MIN_CONFIDENCE = 60;
    private static final Integer SECTION_LIMIT = 20; // 빌더가 5건+더보기로 줄임

    public static Settings load() {
        Settings s = new Settings();
        for (Boni_Setting__mdt m : [SELECT Maturity_Window_Days__c, Signal_Days__c, Stale_Days__c, Briefing_Hour__c, Wrapup_Hour__c
                                    FROM Boni_Setting__mdt WHERE DeveloperName = 'Default' LIMIT 1]) {
            if (m.Maturity_Window_Days__c != null) s.maturityWindowDays = m.Maturity_Window_Days__c.intValue();
            if (m.Signal_Days__c != null) s.signalDays = m.Signal_Days__c.intValue();
            if (m.Stale_Days__c != null) s.staleDays = m.Stale_Days__c.intValue();
            if (m.Briefing_Hour__c != null) s.briefingHour = m.Briefing_Hour__c.intValue();
            if (m.Wrapup_Hour__c != null) s.wrapupHour = m.Wrapup_Hour__c.intValue();
        }
        return s;
    }

    public static List<Id> resolveDataUserIds(Boni_Target__mdt target) {
        Id userId = (Id) target.Data_User_Id__c;
        if (target.Role__c != 'Manager') return new List<Id>{ userId };
        List<Id> ids = new List<Id>();
        User mgr = [SELECT UserRoleId FROM User WHERE Id = :userId];
        if (mgr.UserRoleId != null) {
            for (User u : [SELECT Id FROM User WHERE IsActive = true AND UserRole.ParentRoleId = :mgr.UserRoleId]) ids.add(u.Id);
        }
        if (ids.isEmpty()) ids.add(userId);
        return ids;
    }

    public static BoniDashboardData build(Boni_Target__mdt target, Date today) {
        Settings s = load();
        BoniDashboardData d = base(target, today);
        List<Id> owners = resolveDataUserIds(target);
        Datetime dayStart = Datetime.newInstance(today, Time.newInstance(0, 0, 0, 0));
        Datetime dayEnd = dayStart.addDays(1);

        for (Event e : [SELECT Id, Subject, StartDateTime, Location, What.Name FROM Event
                        WHERE OwnerId IN :owners AND StartDateTime >= :dayStart AND StartDateTime < :dayEnd
                        ORDER BY StartDateTime LIMIT :SECTION_LIMIT]) {
            BoniDashboardData.EventItem it = new BoniDashboardData.EventItem();
            it.id = e.Id; it.subject = e.Subject; it.startAt = e.StartDateTime; it.location = e.Location;
            it.accountName = e.What != null ? e.What.Name : null;
            d.events.add(it);
        }
        d.calendarConnected = !d.events.isEmpty();

        Date matEnd = today.addDays(s.maturityWindowDays);
        for (Opportunity o : [SELECT Id, Account.Name, Amount, RP_Maturity_Date__c, Primary_Product__r.Name FROM Opportunity
                              WHERE OwnerId IN :owners AND RP_Maturity_Date__c >= :today AND RP_Maturity_Date__c <= :matEnd
                              ORDER BY RP_Maturity_Date__c LIMIT :SECTION_LIMIT]) {
            BoniDashboardData.MaturityItem it = new BoniDashboardData.MaturityItem();
            it.oppId = o.Id; it.accountName = o.Account != null ? o.Account.Name : null; it.amount = o.Amount;
            it.productName = o.Primary_Product__r != null ? o.Primary_Product__r.Name : null;
            it.maturityDate = o.RP_Maturity_Date__c; it.daysLeft = today.daysBetween(o.RP_Maturity_Date__c);
            d.maturities.add(it);
        }

        Date sigSince = today.addDays(-s.signalDays);
        for (ExternalSignal__c sg : [SELECT Id, Title__c, Signal_Date__c, Relevance_Score__c, Account__r.Name FROM ExternalSignal__c
                                     WHERE Account__r.OwnerId IN :owners AND Signal_Date__c >= :sigSince
                                       AND Relevance_Score__c >= :SIGNAL_MIN_RELEVANCE AND Confidence__c >= :SIGNAL_MIN_CONFIDENCE
                                     ORDER BY Relevance_Score__c DESC LIMIT :SECTION_LIMIT]) {
            BoniDashboardData.SignalItem it = new BoniDashboardData.SignalItem();
            it.id = sg.Id; it.title = sg.Title__c; it.signalDate = sg.Signal_Date__c; it.relevance = sg.Relevance_Score__c;
            it.accountName = sg.Account__r != null ? sg.Account__r.Name : null;
            d.signals.add(it);
        }

        Date weekStart = today.toStartOfWeek();
        Date weekEnd = weekStart.addDays(6);
        Datetime staleBefore = Datetime.now().addDays(-s.staleDays);
        for (Opportunity o : [SELECT Id, Amount, CloseDate, LastStageChangeDate, CreatedDate FROM Opportunity
                              WHERE OwnerId IN :owners AND IsClosed = false]) {
            d.pipeline.openTotal++;
            if (o.CloseDate >= weekStart && o.CloseDate <= weekEnd) {
                d.pipeline.closingThisWeek++;
                d.pipeline.closingAmount += (o.Amount == null ? 0 : o.Amount);
            }
            Datetime lastChange = o.LastStageChangeDate != null ? o.LastStageChangeDate : o.CreatedDate;
            if (lastChange < staleBefore) d.pipeline.stale++;
        }

        for (Task t : [SELECT Id, Subject, ActivityDate FROM Task
                       WHERE OwnerId IN :owners AND IsClosed = false AND ActivityDate <= :today
                       ORDER BY ActivityDate LIMIT :SECTION_LIMIT]) {
            BoniDashboardData.TaskItem it = new BoniDashboardData.TaskItem();
            it.id = t.Id; it.subject = t.Subject; it.dueDate = t.ActivityDate;
            it.overdueDays = t.ActivityDate == null ? 0 : t.ActivityDate.daysBetween(today);
            d.tasks.add(it);
        }
        return d;
    }

    public static BoniDashboardData buildWrapup(Boni_Target__mdt target, Date today) {
        BoniDashboardData d = base(target, today);
        List<Id> owners = resolveDataUserIds(target);
        Datetime dayStart = Datetime.newInstance(today, Time.newInstance(0, 0, 0, 0));
        Datetime dayEnd = dayStart.addDays(1);
        Datetime tmrEnd = dayEnd.addDays(1);
        BoniDashboardData.WrapupData w = new BoniDashboardData.WrapupData();

        Map<Id, Integer> updatedByOwner = new Map<Id, Integer>();
        for (Opportunity o : [SELECT Name, StageName, OwnerId FROM Opportunity
                              WHERE OwnerId IN :owners AND LastModifiedDate >= :dayStart AND LastModifiedDate < :dayEnd
                              ORDER BY LastModifiedDate DESC LIMIT :SECTION_LIMIT]) {
            w.updatedOpps.add(o.Name + ' · ' + o.StageName);
            updatedByOwner.put(o.OwnerId, (updatedByOwner.containsKey(o.OwnerId) ? updatedByOwner.get(o.OwnerId) : 0) + 1);
        }
        Map<Id, Integer> doneByOwner = new Map<Id, Integer>();
        for (Task t : [SELECT OwnerId FROM Task WHERE OwnerId IN :owners AND IsClosed = true
                       AND LastModifiedDate >= :dayStart AND LastModifiedDate < :dayEnd]) {
            w.completedTasks++;
            doneByOwner.put(t.OwnerId, (doneByOwner.containsKey(t.OwnerId) ? doneByOwner.get(t.OwnerId) : 0) + 1);
        }
        w.carriedTasks = [SELECT COUNT() FROM Task WHERE OwnerId IN :owners AND IsClosed = false AND ActivityDate <= :today];
        for (Event e : [SELECT Id, Subject, StartDateTime, What.Name FROM Event
                        WHERE OwnerId IN :owners AND StartDateTime >= :dayEnd AND StartDateTime < :tmrEnd
                        ORDER BY StartDateTime LIMIT 1]) {
            BoniDashboardData.EventItem it = new BoniDashboardData.EventItem();
            it.id = e.Id; it.subject = e.Subject; it.startAt = e.StartDateTime; it.accountName = e.What != null ? e.What.Name : null;
            w.tomorrowFirst = it;
        }
        if (target.Role__c == 'Manager') {
            for (User u : [SELECT Id, Name FROM User WHERE Id IN :owners]) {
                Integer up = updatedByOwner.containsKey(u.Id) ? updatedByOwner.get(u.Id) : 0;
                Integer dn = doneByOwner.containsKey(u.Id) ? doneByOwner.get(u.Id) : 0;
                w.teamLines.add(u.Name + ' · 갱신 ' + up + ' · 완료 ' + dn);
            }
        }
        d.wrapup = w;
        return d;
    }

    private static BoniDashboardData base(Boni_Target__mdt target, Date today) {
        BoniDashboardData d = new BoniDashboardData();
        d.dataUserId = (Id) target.Data_User_Id__c;
        d.slackUserId = target.Slack_User_Id__c;
        d.role = target.Role__c;
        d.today = today;
        d.generatedAt = Datetime.now();
        for (User u : [SELECT Name FROM User WHERE Id = :d.dataUserId LIMIT 1]) d.dataUserName = u.Name;
        return d;
    }
}