/**
 * 네이버 뉴스 수집을 비동기로 실행한다.
 *
 * 배치(NaverNewsBatch)의 execute 는 회사별로 콜아웃+DML(insert)을 수행하므로, 같은
 * 트랜잭션에서 실패 회사를 재시도하면 "uncommitted work pending" 이 발생할 수 있다.
 * 따라서 실패 재처리는 별도 트랜잭션(Queueable)으로 분리해 실행한다.
 *
 * 일시적 오류 시 자기 자신을 재큐하여 재시도하고, 최대 재시도 횟수
 * (Naver_Setting__mdt.Default.Max_Retry__c)를 초과하면 관리자에게 이메일로 실패를 알린다.
 * (기존 DartSignalQueueable 과 동일한 재처리·관리자 알림 패턴)
 */
public with sharing class NaverNewsQueueable implements Queueable, Database.AllowsCallouts {
    private final String companyName;
    private final Integer attempt;

    /**
     * @param companyName 수집·매핑 대상 기업명(Account.Name)
     */
    public NaverNewsQueueable(String companyName) {
        this(companyName, 0);
    }

    private NaverNewsQueueable(String companyName, Integer attempt) {
        this.companyName = companyName;
        this.attempt = attempt;
    }

    public void execute(QueueableContext context) {
        try {
            NaverNewsService.collectNews(companyName);
        } catch (NaverNewsService.NaverNewsException e) {
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
        NaverNewsQueueable retry = new NaverNewsQueueable(companyName, attempt + 1);
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
    private static NaverNewsQueueable retryEnqueued;

    @TestVisible
    private void notifyAdmin(Exception e, Integer finalAttempt) {
        String adminEmail = getAdminEmail();
        if (String.isBlank(adminEmail)) {
            return;
        }
        Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
        mail.setToAddresses(new List<String>{ adminEmail });
        mail.setSubject('[네이버 뉴스 수집 실패] ' + companyName);
        mail.setPlainTextBody(
            '네이버 뉴스 수집이 최대 재시도(' + finalAttempt + '회) 후에도 실패했습니다.\n\n' +
            '기업명: ' + companyName + '\n\n' +
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
        Naver_Setting__mdt setting = Naver_Setting__mdt.getInstance('Default');
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
        Naver_Setting__mdt setting = Naver_Setting__mdt.getInstance('Default');
        return setting == null ? null : setting.Admin_Email__c;
    }
}