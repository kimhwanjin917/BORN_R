/**
 * 임계 통과 ExternalSignal__c 에 대해 담당 RM 에게 알림을 발송한다.
 * 발송 수단은 Salesforce Custom Notification(DART_Signal_RM_Alert). Slack 연동은
 * 보류 상태이며, 발송부(sendNotifications)만 교체하면 Slack 로 전환할 수 있다.
 *
 * 일시적 오류 시 자기 자신을 재큐하여 재시도하고, 최대 재시도 횟수
 * (DART_Setting__mdt.Default.Max_Retry__c)를 초과하면 관리자에게 이메일로 실패를 알린다.
 * (기존 DartSignalQueueable 과 동일한 재처리·관리자 알림 패턴)
 */
public with sharing class SignalRmAlertQueueable implements Queueable {
    private static final String NOTIF_TYPE_NAME = 'DART_Signal_RM_Alert';

    // signalId → 담당 RM(UserId)
    private final Map<Id, Id> ownerBySignalId;
    private final Integer attempt;

    public class SignalRmAlertException extends Exception {}

    /**
     * @param ownerBySignalId 알림 대상 ExternalSignal__c Id → 담당 RM UserId
     */
    public SignalRmAlertQueueable(Map<Id, Id> ownerBySignalId) {
        this(ownerBySignalId, 0);
    }

    private SignalRmAlertQueueable(Map<Id, Id> ownerBySignalId, Integer attempt) {
        this.ownerBySignalId = ownerBySignalId;
        this.attempt = attempt;
    }

    // 테스트에서 execute 의 실패 경로(catch → handleFailure)를 검증하기 위한 주입 훅.
    @TestVisible
    private static Boolean forceSendFailure = false;

    public void execute(QueueableContext context) {
        try {
            if (Test.isRunningTest() && forceSendFailure) {
                throw new SignalRmAlertException('강제 발송 실패(테스트)');
            }
            sendNotifications();
        } catch (Exception e) {
            handleFailure(e);
        }
    }

    /**
     * 발송부. 담당 RM 별로 관련 시그널을 묶어 Custom Notification 을 발송한다.
     * (Slack 전환 시 이 메서드만 교체한다.)
     */
    private void sendNotifications() {
        Id typeId = getNotificationTypeId();

        // 대상 시그널의 제목을 한 번에 조회(루프 밖 SOQL)
        Map<Id, ExternalSignal__c> signalById = new Map<Id, ExternalSignal__c>([
            SELECT Id, Name, Title__c
            FROM ExternalSignal__c
            WHERE Id IN :ownerBySignalId.keySet()
            WITH USER_MODE
        ]);

        for (Id signalId : ownerBySignalId.keySet()) {
            ExternalSignal__c signal = signalById.get(signalId);
            if (signal == null) {
                continue;
            }
            Id recipientId = ownerBySignalId.get(signalId);

            Messaging.CustomNotification notification = new Messaging.CustomNotification();
            notification.setTitle('신규 공시 알림');
            notification.setBody(buildBody(signal));
            notification.setNotificationTypeId(typeId);
            notification.setTargetId(signalId);

            if (Test.isRunningTest()) {
                // 테스트에서는 실제 발송 대신 발송 시도를 기록만 한다(결정론적 검증).
                sentNotifications.add(recipientId);
                continue;
            }
            notification.send(new Set<String>{ recipientId });
        }
    }

    private String buildBody(ExternalSignal__c signal) {
        String title = String.isBlank(signal.Title__c) ? signal.Name : signal.Title__c;
        return '담당 고객 관련 신규 공시가 감지되었습니다: ' + title;
    }

    // 테스트에서 발송된 알림 수신자를 검증할 수 있게 한다.
    @TestVisible
    private static List<Id> sentNotifications = new List<Id>();

    @TestVisible
    private Id getNotificationTypeId() {
        List<CustomNotificationType> types = [
            SELECT Id FROM CustomNotificationType
            WHERE DeveloperName = :NOTIF_TYPE_NAME
            LIMIT 1
        ];
        if (types.isEmpty()) {
            throw new SignalRmAlertException(
                'Custom Notification Type 미설정: ' + NOTIF_TYPE_NAME
            );
        }
        return types[0].Id;
    }

    private void handleFailure(Exception e) {
        Integer maxRetry = getMaxRetry();
        if (attempt < maxRetry) {
            reEnqueue();
        } else {
            notifyAdmin(e, attempt);
        }
    }

    private void reEnqueue() {
        SignalRmAlertQueueable retry =
            new SignalRmAlertQueueable(ownerBySignalId, attempt + 1);
        if (Test.isRunningTest()) {
            // 테스트에서는 실제 재큐 대신 재시도 발생을 기록만 한다.
            retryEnqueued = retry;
            return;
        }
        Integer delayMinutes = Math.min((Integer) Math.pow(2, attempt), 10);
        AsyncOptions options = new AsyncOptions();
        options.MinimumQueueableDelayInMinutes = delayMinutes;
        System.enqueueJob(retry, options);
    }

    // 테스트에서 재시도 재큐 발생을 검증할 수 있게 한다.
    @TestVisible
    private static SignalRmAlertQueueable retryEnqueued;

    @TestVisible
    private void notifyAdmin(Exception e, Integer finalAttempt) {
        String adminEmail = getAdminEmail();
        if (String.isBlank(adminEmail)) {
            return;
        }
        Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
        mail.setToAddresses(new List<String>{ adminEmail });
        mail.setSubject('[RM 알림 발송 실패] 대상 시그널 ' + ownerBySignalId.size() + '건');
        mail.setPlainTextBody(
            'RM 공시 알림 발송이 최대 재시도(' + finalAttempt + '회) 후에도 실패했습니다.\n\n' +
            '대상 시그널 수: ' + ownerBySignalId.size() + '\n\n' +
            '오류: ' + e.getMessage()
        );
        mail.setSaveAsActivity(false);
        if (Test.isRunningTest()) {
            sentEmails.add(mail);
            return;
        }
        Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail });
    }

    // 테스트에서 발송된 알림 메시지를 검증할 수 있게 한다.
    @TestVisible
    private static List<Messaging.SingleEmailMessage> sentEmails =
        new List<Messaging.SingleEmailMessage>();

    private Integer getMaxRetry() {
        DART_Setting__mdt setting = DART_Setting__mdt.getInstance('Default');
        if (setting == null || setting.Max_Retry__c == null) {
            return 3;
        }
        return (Integer) setting.Max_Retry__c;
    }

    // 테스트에서 CMDT 레코드를 DML로 삽입할 수 없으므로 관리자 이메일을 주입할 수 있게 한다.
    @TestVisible
    private static String testAdminEmail;

    private String getAdminEmail() {
        if (Test.isRunningTest() && String.isNotBlank(testAdminEmail)) {
            return testAdminEmail;
        }
        DART_Setting__mdt setting = DART_Setting__mdt.getInstance('Default');
        return setting == null ? null : setting.Admin_Email__c;
    }
}