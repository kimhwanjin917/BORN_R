/**
 * Creates "만기 알림" follow-up Tasks for Assets whose UsageEndDate falls within the
 * next ALERT_WINDOW_DAYS (default 30). One open Task per Asset — different assets have
 * different maturity dates and products, so each maturing asset is its own alert.
 *
 * Idempotent across daily runs: an Asset that already has an open maturity-alert Task
 * is skipped, so re-running the nightly job never duplicates alerts.
 *
 * Task owner = the Asset's Account owner (담당 RM), so the alert surfaces on that RM's
 * home dashboard 만기 알림 card. That card (HomeDashboardController.getMaturityAlertTasks,
 * owned by another team member — read-only reference) filters by
 * `OwnerId = 본인 AND IsClosed = false AND Subject LIKE '만기 30일 전 후속 영업%'`,
 * so SUBJECT_PREFIX below MUST stay in sync with that LIKE pattern.
 *
 * Called from RadarRefreshSchedulable (nightly 03:30). No trigger, no new object/field.
 */
public with sharing class MaturityAlertService {
    // Keep in sync with HomeDashboardController.MATURITY_SUBJECT_LIKE ('만기 30일 전 후속 영업%').
    @TestVisible
    private static final String SUBJECT_PREFIX = '만기 30일 전 후속 영업';

    // Alert lead time in days. Deliberately an Apex constant (not a mdt record): AGENTS.md
    // restricts deployable metadata to Apex/LWC, and the radar's own Maturity_Window_Days
    // mdt (90) is a different, score-side window.
    @TestVisible
    private static final Integer ALERT_WINDOW_DAYS = 30;

    /** Existing desktop/mobile RM notification channel used for the alert bell. */
    @TestVisible
    private static final String NOTIFICATION_TYPE_DEVELOPER_NAME = 'DART_Signal_RM_Alert';

    /** Days before maturity when a bell notification is sent. */
    @TestVisible
    private static final Set<Integer> NOTIFICATION_DAYS = new Set<Integer>{ 30, 7, 1, 0 };

    /**
     * Inserts one maturity-alert Task per newly-maturing Asset. Safe to call daily.
     */
    public static void generateAlerts() {
        Date today = Date.today();
        Date windowEnd = today.addDays(ALERT_WINDOW_DAYS);

        List<Asset> maturing = [
            SELECT Id, Name, AccountId, Account.OwnerId, UsageEndDate
            FROM Asset
            WHERE UsageEndDate >= :today
              AND UsageEndDate <= :windowEnd
              AND AccountId != null
            WITH USER_MODE
            ORDER BY UsageEndDate ASC
            LIMIT 2000
        ];
        if (maturing.isEmpty()) {
            return;
        }

        Set<Id> assetIds = new Set<Id>();
        for (Asset a : maturing) {
            assetIds.add(a.Id);
        }

        // Assets that already carry an open maturity-alert Task — skip to stay idempotent.
        String subjectLike = SUBJECT_PREFIX + '%';
        Set<Id> alreadyAlerted = new Set<Id>();
        for (Task existing : [
            SELECT WhatId
            FROM Task
            WHERE WhatId IN :assetIds
              AND IsClosed = false
              AND Subject LIKE :subjectLike
            WITH USER_MODE
        ]) {
            alreadyAlerted.add(existing.WhatId);
        }

        List<Task> toInsert = new List<Task>();
        for (Asset a : maturing) {
            if (alreadyAlerted.contains(a.Id) || a.Account == null || a.Account.OwnerId == null) {
                continue;
            }
            toInsert.add(new Task(
                Subject = SUBJECT_PREFIX + ' - ' + a.Name,
                WhatId = a.Id,
                OwnerId = a.Account.OwnerId,
                ActivityDate = a.UsageEndDate,
                Status = 'Not Started',
                Priority = 'High'
            ));
        }

        if (!toInsert.isEmpty()) {
            Database.insert(toInsert, true, AccessLevel.USER_MODE);
        }

        sendMaturityNotifications(maturing);
    }

    /**
     * Sends one Salesforce bell notification for each Asset at D-30, D-7, D-1,
     * and D-day. The home dashboard Task remains independent and persistent.
     * @param maturing Assets in the current 30-day maturity window
     */
    private static void sendMaturityNotifications(List<Asset> maturing) {
        Id notificationTypeId = findNotificationTypeId();
        if (notificationTypeId == null) {
            return;
        }

        for (Asset asset : maturing) {
            if (asset.Account == null || asset.Account.OwnerId == null || asset.UsageEndDate == null) {
                continue;
            }

            Integer daysUntilMaturity = Date.today().daysBetween(asset.UsageEndDate);
            if (!NOTIFICATION_DAYS.contains(daysUntilMaturity)) {
                continue;
            }

            Messaging.CustomNotification notification = new Messaging.CustomNotification();
            notification.setNotificationTypeId(notificationTypeId);
            notification.setTitle('만기 알림 · ' + formatNotificationDayLabel(daysUntilMaturity));
            notification.setBody(
                asset.Name + ' 만기일: ' + String.valueOf(asset.UsageEndDate)
            );
            notification.setTargetPageRef(buildRadarPageReference(asset.Id));
            notification.send(new Set<String>{ String.valueOf(asset.Account.OwnerId) });
        }
    }

    /**
     * Formats the threshold label with the same two-digit convention as the home card.
     * @param daysUntilMaturity Days remaining until the Asset matures
     * @return D-day label
     */
    private static String formatNotificationDayLabel(Integer daysUntilMaturity) {
        String days = String.valueOf(daysUntilMaturity);
        if (daysUntilMaturity < 10) {
            days = '0' + days;
        }
        return 'D-' + days;
    }

    /**
     * Finds the existing notification type by developer name instead of storing
     * an org-specific Id in Apex.
     * @return Notification type Id, or null when it is not configured
     */
    private static Id findNotificationTypeId() {
        List<CustomNotificationType> notificationTypes = [
            SELECT Id
            FROM CustomNotificationType
            WHERE DeveloperName = :NOTIFICATION_TYPE_DEVELOPER_NAME
            WITH USER_MODE
            LIMIT 1
        ];
        return notificationTypes.isEmpty() ? null : notificationTypes[0].Id;
    }

    /**
     * Builds the page reference used when an RM clicks the bell notification.
     * @param assetId Asset passed to Opportunity Radar through component state
     * @return Serialized Lightning page reference
     */
    private static String buildRadarPageReference(Id assetId) {
        Map<String, Object> pageReference = new Map<String, Object>{
            'type' => 'standard__navItemPage',
            'attributes' => new Map<String, Object>{ 'apiName' => 'Opportunity_Radar' },
            'state' => new Map<String, Object>{ 'c__whatId' => String.valueOf(assetId) }
        };
        return JSON.serialize(pageReference);
    }
}