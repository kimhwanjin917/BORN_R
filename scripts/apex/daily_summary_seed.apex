// 일일 뉴스 요약 더미 데이터 사전 적재 (백로그 32 - 뉴스 AI 일일 요약).
// 화면 확인용으로 오늘·어제·그제 3건을 ExternalSignal__c(Signal_Type__c='일일요약')로 넣는다.
// External_Key__c(자연키 'DAILY_SUMMARY_<날짜>') 기준 upsert 라 재실행해도 중복 없이 갱신된다.
// 실제 운영에서는 NewsDailySummarySaveQueueable(오전 6시 스케줄)이 이 레코드를 생성한다.

final String DAILY = '일일요약';
final Date TODAY = Date.today();

// 날짜별 요약 본문(요약: 프롬프트 템플릿이 생성할 형식과 동일하게 더미 작성)
Map<Date, String> summaryByDate = new Map<Date, String>{
    TODAY => '오늘의 뉴스 요약:\n'
        + '- 담당 기업: 리노공업 - AI 반도체 테스트 소켓 수요 급증으로 2Q 실적 서프라이즈 (출처: https://dummy.news.local/NEWS_00369657_2)\n'
        + '- 담당 기업: 성우하이텍 - 북미 전기차 OEM에 차체 경량화 부품 다년 공급계약 (출처: https://dummy.news.local/NEWS_00132992_0)\n'
        + '- 담당 기업: 씨앤씨인터내셔널 - 글로벌 인디 브랜드향 립 제품 수주 확대 (출처: https://dummy.news.local/NEWS_01226410_8)\n'
        + '- 담당 산업군: 반도체전자 - AI·HBM 붐에 후공정·테스트 장비 투자 확대. 리노공업 소켓 수요와 직결.\n'
        + '한 줄 총평: 리노공업의 AI 소켓 수요 급증이 오늘 포트폴리오에서 가장 주목할 뉴스.',
    TODAY.addDays(-1) => '오늘의 뉴스 요약:\n'
        + '- 담당 기업: 하나기술 - 유럽 배터리셀 업체와 조립장비 턴키 수주로 수주잔고 확대 (출처: https://dummy.news.local/NEWS_00601191_6)\n'
        + '- 담당 기업: 코스메카코리아 - 미국 자회사 잉글우드랩 흑자 전환 (출처: https://dummy.news.local/NEWS_00763473_10)\n'
        + '- 담당 산업군: 자동차부품 - 전기차 전환에 차체 경량화 부품 수요 증가.\n'
        + '한 줄 총평: 하나기술 유럽 수주가 어제 가장 주목할 뉴스.',
    TODAY.addDays(-2) => '오늘의 뉴스 요약:\n'
        + '- 담당 기업: 하나마이크론 - 브라질 법인 반도체 패키징 신규 라인 가동 (출처: https://dummy.news.local/NEWS_00445054_4)\n'
        + '- 담당 산업군: 화장품ODM - K-뷰티 수출 사상 최대, ODM 수주 러시.\n'
        + '한 줄 총평: 하나마이크론 후공정 캐파 확대가 그제 가장 주목할 뉴스.'
};

List<ExternalSignal__c> records = new List<ExternalSignal__c>();
for (Date d : summaryByDate.keySet()) {
    records.add(new ExternalSignal__c(
        Signal_Type__c = DAILY,
        Signal_Date__c = d,
        Summary_Date__c = d,
        Summary_Text__c = summaryByDate.get(d),
        Generated_At__c = Datetime.newInstance(d, Time.newInstance(6, 0, 0, 0)),
        Title__c = String.valueOf(d) + ' 일일 뉴스 요약',
        External_Key__c = 'DAILY_SUMMARY_' + String.valueOf(d)
    ));
}

Database.UpsertResult[] results = Database.upsert(records, ExternalSignal__c.External_Key__c, AccessLevel.USER_MODE);
Integer ok = 0;
for (Database.UpsertResult r : results) {
    if (r.isSuccess()) ok++;
}
System.debug('일일요약 upsert 완료: ' + ok + '/' + records.size());
