/** 대상 RM 순회 → 데이터 조회 → Block Kit → Slack 전송. 대상별 try/catch 로 격리. */
public with sharing class BoniPublisher implements Queueable, Database.AllowsCallouts {

    public enum Mode { BRIEFING, HOME, WRAPUP }
    private static final String ALERT_CHANNEL = 'C0BSE7LMBN2'; // #crm-처리요청
    @TestVisible private static Boolean alertOnFailure = true;

    private Mode runMode; private String onlySlackUserId;
    public BoniPublisher(Mode runMode) { this(runMode, null); }
    public BoniPublisher(Mode runMode, String onlySlackUserId) { this.runMode = runMode; this.onlySlackUserId = onlySlackUserId; }

    public void execute(QueueableContext ctx) { publishNow(runMode, onlySlackUserId); }

    public static List<Boni_Target__mdt> activeTargets() {
        return [SELECT DeveloperName, Data_User_Id__c, Slack_User_Id__c, Role__c, Is_Active__c FROM Boni_Target__mdt WHERE Is_Active__c = true];
    }

    public static Integer publishNow(Mode runMode, String onlySlackUserId) {
        Integer ok = 0;
        Date today = Date.today();
        for (Boni_Target__mdt t : activeTargets()) {
            if (onlySlackUserId != null && t.Slack_User_Id__c != onlySlackUserId) continue;
            try {
                if (runMode == Mode.WRAPUP) {
                    BoniDashboardData d = BoniDashboardService.buildWrapup(t, today);
                    String dm = t.Slack_User_Id__c; // user ID 를 channel 로 → Slack 이 DM 자동 오픈 (im:write 불필요)
                    BoniSlackClient.postBlocks(dm, BoniBlockKitBuilder.wrapupText(d), BoniBlockKitBuilder.wrapupBlocks(d));
                } else {
                    BoniDashboardData d = BoniDashboardService.build(t, today);
                    if (runMode == Mode.BRIEFING) {
                        String dm = t.Slack_User_Id__c; // user ID 를 channel 로 → Slack 이 DM 자동 오픈 (im:write 불필요)
                        BoniSlackClient.postBlocks(dm, BoniBlockKitBuilder.briefingText(d), BoniBlockKitBuilder.briefingBlocks(d));
                    }
                    BoniSlackClient.publishHome(t.Slack_User_Id__c, BoniBlockKitBuilder.homeView(d));
                }
                ok++;
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'BoniPublisher ' + runMode + ' ' + t.DeveloperName + ' 실패: ' + e.getMessage());
                alert(runMode, t, e);
            }
        }
        return ok;
    }

    private static void alert(Mode runMode, Boni_Target__mdt t, Exception e) {
        if (!alertOnFailure) return;
        try {
            BoniSlackClient.postBlocks(ALERT_CHANNEL, '보니 ' + runMode + ' 전송 실패',
                new List<Object>{ new Map<String, Object>{ 'type' => 'section', 'text' => new Map<String, Object>{ 'type' => 'mrkdwn',
                    'text' => '*보니 ' + runMode + ' 전송 실패* — 대상 `' + t.DeveloperName + '` (' + t.Slack_User_Id__c + ')\n> ' + e.getMessage() + ' :boni_curious:' } } });
        } catch (Exception ignore) { System.debug(LoggingLevel.ERROR, 'alert 실패: ' + ignore.getMessage()); }
    }
}