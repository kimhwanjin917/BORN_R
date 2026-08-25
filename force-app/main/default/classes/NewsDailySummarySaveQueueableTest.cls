/**
 * NewsDailySummarySaveQueueable 테스트.
 * 프롬프트 템플릿 호출은 stubResponse seam 으로 대체해, 일일요약 저장·일자별 1건 유지·빈 응답 처리를 검증한다.
 * 요약은 ExternalSignal__c(Signal_Type__c='일일요약')에 저장된다.
 */
@isTest
private class NewsDailySummarySaveQueueableTest {

    private static final String DAILY_SUMMARY_SIGNAL = '일일요약';
    private static final String SAMPLE_SUMMARY =
        '오늘의 뉴스 요약:\n- 담당 기업: 리노공업 - AI 소켓 수요 급증 (출처: https://news.example.com/1)\n한 줄 총평: 리노공업 소켓 수요가 가장 주목할 뉴스.';

    @isTest
    static void shouldCreateRecord_WhenNoneExistsToday() {
        NewsDailySummarySaveQueueable.stubResponse = SAMPLE_SUMMARY;

        Test.startTest();
        System.enqueueJob(new NewsDailySummarySaveQueueable());
        Test.stopTest();

        List<ExternalSignal__c> saved = [
            SELECT Summary_Text__c, Summary_Date__c, Generated_At__c, Signal_Type__c
            FROM ExternalSignal__c WHERE Signal_Type__c = :DAILY_SUMMARY_SIGNAL
            WITH SYSTEM_MODE
        ];
        Assert.areEqual(1, saved.size(), '오늘 일일요약 레코드 1건이 생성돼야 한다');
        Assert.areEqual(Date.today(), saved[0].Summary_Date__c, '요약 일자는 오늘이어야 한다');
        Assert.isTrue(saved[0].Summary_Text__c.contains('리노공업'), '요약 본문이 저장돼야 한다');
        Assert.areNotEqual(null, saved[0].Generated_At__c, '생성 시각이 기록돼야 한다');
    }

    @isTest
    static void shouldUpdateExisting_WhenRecordForTodayExists() {
        insert new ExternalSignal__c(
            Signal_Type__c = DAILY_SUMMARY_SIGNAL,
            Signal_Date__c = Date.today(),
            Summary_Date__c = Date.today(),
            Summary_Text__c = '이전 요약',
            External_Key__c = 'DAILY_SUMMARY_' + String.valueOf(Date.today())
        );
        NewsDailySummarySaveQueueable.stubResponse = SAMPLE_SUMMARY;

        Test.startTest();
        System.enqueueJob(new NewsDailySummarySaveQueueable());
        Test.stopTest();

        List<ExternalSignal__c> saved = [
            SELECT Summary_Text__c FROM ExternalSignal__c
            WHERE Signal_Type__c = :DAILY_SUMMARY_SIGNAL AND Summary_Date__c = :Date.today()
        ];
        Assert.areEqual(1, saved.size(), '같은 날짜 레코드는 새로 만들지 않고 1건을 유지해야 한다');
        Assert.isTrue(saved[0].Summary_Text__c.contains('리노공업'), '기존 레코드가 새 요약으로 갱신돼야 한다');
    }

    @isTest
    static void shouldNotSave_WhenResponseBlank() {
        insert new ExternalSignal__c(
            Signal_Type__c = DAILY_SUMMARY_SIGNAL,
            Signal_Date__c = Date.today(),
            Summary_Date__c = Date.today(),
            Summary_Text__c = '보존돼야 할 이전 요약',
            External_Key__c = 'DAILY_SUMMARY_' + String.valueOf(Date.today())
        );
        NewsDailySummarySaveQueueable.stubResponse = '';

        Test.startTest();
        System.enqueueJob(new NewsDailySummarySaveQueueable());
        Test.stopTest();

        ExternalSignal__c saved = [
            SELECT Summary_Text__c FROM ExternalSignal__c
            WHERE Signal_Type__c = :DAILY_SUMMARY_SIGNAL AND Summary_Date__c = :Date.today()
        ];
        Assert.areEqual(
            '보존돼야 할 이전 요약',
            saved.Summary_Text__c,
            '빈 응답이면 저장하지 않아 기존 요약이 보존돼야 한다'
        );
    }
}