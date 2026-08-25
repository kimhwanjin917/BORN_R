/**
 * DART 재무제표 수집을 비동기로 실행하고, 일시적 오류 발생 시 자기 자신을 재큐하여
 * 재시도한다. 최대 재시도 횟수(DART_Setting__mdt.Default.Max_Retry__c)를 초과하면
 * 관리자에게 이메일로 실패를 알린다.
 */
public with sharing class DartCollectionQueueable implements Queueable, Database.AllowsCallouts {
    private final String corpCode;
    private final String businessYear;
    private final String reportCode;
    private final Integer attempt;

    /**
     * @param corpCode DART 기업 고유번호
     * @param businessYear 사업연도(예: '2023')
     * @param reportCode 보고서 코드(11011/11012/11013/11014)
     */
    public DartCollectionQueueable(String corpCode, String businessYear, String reportCode) {
        this(corpCode, businessYear, reportCode, 0);
    }

    private DartCollectionQueueable(String corpCode, String businessYear, String reportCode, Integer attempt) {
        this.corpCode = corpCode;
        this.businessYear = businessYear;
        this.reportCode = reportCode;
        this.attempt = attempt;
    }

    public void execute(QueueableContext context) {
        try {
            DartFinancialService.collectFinancials(corpCode, businessYear, reportCode);
        } catch (DartFinancialService.DartServiceException e) {
            handleFailure(e);
        }
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
        DartCollectionQueueable retry =
            new DartCollectionQueueable(corpCode, businessYear, reportCode, attempt + 1);
        if (Test.isRunningTest()) {
            // 테스트에서는 실제 재큐(콜아웃 제한) 대신 재시도 발생을 기록만 한다.
            retryEnqueued = retry;
            return;
        }
        // 재시도: 지수적 지연으로 재큐 (최대 10분)
        Integer delayMinutes = Math.min((Integer) Math.pow(2, attempt), 10);
        AsyncOptions options = new AsyncOptions();
        options.MinimumQueueableDelayInMinutes = delayMinutes;
        System.enqueueJob(retry, options);
    }

    // 테스트에서 재시도 재큐 발생을 검증할 수 있게 한다.
    @TestVisible
    private static DartCollectionQueueable retryEnqueued;

    @TestVisible
    private void notifyAdmin(Exception e, Integer finalAttempt) {
        String adminEmail = getAdminEmail();
        if (String.isBlank(adminEmail)) {
            return;
        }
        Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
        mail.setToAddresses(new List<String>{ adminEmail });
        mail.setSubject('[DART 수집 실패] ' + corpCode + ' / ' + businessYear + ' / ' + reportCode);
        mail.setPlainTextBody(
            'DART 재무제표 수집이 최대 재시도(' + finalAttempt + '회) 후에도 실패했습니다.\n\n' +
            'corp_code: ' + corpCode + '\n' +
            'bsns_year: ' + businessYear + '\n' +
            'reprt_code: ' + reportCode + '\n\n' +
            '오류: ' + e.getMessage()
        );
        mail.setSaveAsActivity(false);
        if (Test.isRunningTest()) {
            // org 의 이메일 deliverability 설정에 관계없이 알림 발송을 결정론적으로 검증하기 위한 훅.
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