/** 본이 대시보드 렌더링 입력. SOQL·콜아웃 없음. */
public with sharing class BoniDashboardData {
    public Id dataUserId;
    public String dataUserName;
    public String slackUserId;
    public String role;            // RM | Manager
    public Date today;
    public Datetime generatedAt;
    public List<EventItem> events = new List<EventItem>();
    public List<MaturityItem> maturities = new List<MaturityItem>();
    public List<SignalItem> signals = new List<SignalItem>();
    public PipelineSummary pipeline = new PipelineSummary();
    public List<TaskItem> tasks = new List<TaskItem>();
    public WrapupData wrapup;      // buildWrapup 에서만 채움
    public Boolean calendarConnected = true; // 이벤트 0건이면 false 로 안내 문구

    public class EventItem { public Id id; public String subject; public Datetime startAt; public String location; public String accountName; }
    public class MaturityItem { public Id oppId; public String accountName; public String productName; public Decimal amount; public Date maturityDate; public Integer daysLeft; }
    public class SignalItem { public Id id; public String accountName; public String title; public Date signalDate; public Decimal relevance; }
    public class PipelineSummary { public Integer closingThisWeek = 0; public Decimal closingAmount = 0; public Integer stale = 0; public Integer openTotal = 0; }
    public class TaskItem { public Id id; public String subject; public Date dueDate; public Integer overdueDays; }
    public class WrapupData {
        public List<String> updatedOpps = new List<String>();   // "클래시스 · Negotiation"
        public Integer completedTasks = 0;
        public Integer carriedTasks = 0;
        public EventItem tomorrowFirst;
        public List<String> teamLines = new List<String>();     // Manager 전용 "윤주환 · 갱신 2 · 완료 1"
    }
}