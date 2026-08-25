/**
 * Finlight News API에서 기업명으로 뉴스를 수집해
 * ExternalSignal__c(Signal_Type__c='뉴스')로 적재하는 서비스.
 *
 * 엔드포인트는 https://api.finlight.me/v2/articles (POST)이며, 인증은
 * Finlight_Setting__mdt.Default.API_Key__c 를 X-API-KEY 헤더로 전달한다.
 * (OAuth 가 아니라 단순 API 키 헤더 인증이므로 Named/External Credential 은 쓰지 않고
 *  Remote Site Setting(Finlight_API)만으로 콜아웃한다.)
 *
 * 수집한 뉴스 항목은 NewsSignalService.NewsItem 으로 정규화한 뒤 NewsSignalService.ingest 에
 * 위임한다. Account 매핑(기업명 기준)·Source_URL__c 자연키 중복 제거·적재는 모두
 * NewsSignalService 가 담당하므로 이 서비스는 콜아웃과 응답 정규화에만 집중한다.
 */
public with sharing class FinlightNewsService {
    @TestVisible
    private static final String API_ENDPOINT = 'https://api.finlight.me/v2/articles';
    private static final Integer TIMEOUT_MS = 120000;
    // 한 번에 가져올 기사 수.
    private static final Integer PAGE_SIZE = 50;
    private static final String LANGUAGE = 'ko';

    private static final String HEADER_API_KEY = 'X-API-KEY';

    public class FinlightNewsException extends Exception {}

    /**
     * 단일 기업명으로 Finlight 뉴스를 검색해 ExternalSignal__c 로 적재한다.
     * Source_URL__c 기준으로 이미 적재된 뉴스는 NewsSignalService 에서 건너뛴다.
     *
     * @param companyName 검색·매핑 대상 기업명(Account.Name)
     * @return 새로 insert 된 ExternalSignal__c 목록(중복·매핑 실패 제외)
     * @throws FinlightNewsException API 키 미설정·콜아웃 실패·오류 응답 시
     */
    public static List<ExternalSignal__c> collectNews(String companyName) {
        if (String.isBlank(companyName)) {
            throw new FinlightNewsException('companyName 은 필수입니다.');
        }

        HttpResponse response = sendRequest(companyName);
        Integer status = response.getStatusCode();
        if (status >= 500 || status == 429) {
            throw new FinlightNewsException('Finlight 일시적 오류(HTTP ' + status + '). 재시도 대상입니다.');
        }
        if (status != 200) {
            throw new FinlightNewsException('Finlight 호출 실패(HTTP ' + status + '): ' + response.getBody());
        }

        List<NewsSignalService.NewsItem> items = parse(response.getBody(), companyName);
        return NewsSignalService.ingest(items);
    }

    private static HttpResponse sendRequest(String companyName) {
        String apiKey = getApiKey();

        HttpRequest request = new HttpRequest();
        request.setEndpoint(API_ENDPOINT);
        request.setMethod('POST');
        request.setTimeout(TIMEOUT_MS);
        request.setHeader(HEADER_API_KEY, apiKey);
        request.setHeader('Content-Type', 'application/json');
        request.setBody(JSON.serialize(new Map<String, Object>{
            'query' => companyName,
            'language' => LANGUAGE,
            'pageSize' => PAGE_SIZE
        }));

        try {
            return new Http().send(request);
        } catch (System.CalloutException e) {
            throw new FinlightNewsException('Finlight 콜아웃 예외: ' + e.getMessage(), e);
        }
    }

    @TestVisible
    private static String testApiKey;

    @TestVisible
    private static String getApiKey() {
        if (Test.isRunningTest()) {
            if (String.isBlank(testApiKey)) {
                throw new FinlightNewsException('Finlight API 키가 설정되지 않았습니다. Finlight_Setting__mdt.Default.API_Key__c 를 확인하세요.');
            }
            return testApiKey;
        }
        Finlight_Setting__mdt setting = Finlight_Setting__mdt.getInstance('Default');
        if (setting == null || String.isBlank(setting.API_Key__c)) {
            throw new FinlightNewsException('Finlight API 키가 설정되지 않았습니다. Finlight_Setting__mdt.Default.API_Key__c 를 확인하세요.');
        }
        return setting.API_Key__c;
    }

    private static List<NewsSignalService.NewsItem> parse(String body, String companyName) {
        Map<String, Object> parsed;
        try {
            parsed = (Map<String, Object>) JSON.deserializeUntyped(body);
        } catch (System.JSONException e) {
            throw new FinlightNewsException('Finlight 응답 파싱 실패: ' + e.getMessage(), e);
        }

        List<NewsSignalService.NewsItem> items = new List<NewsSignalService.NewsItem>();
        List<Object> rows = (List<Object>) parsed.get('articles');
        if (rows == null) {
            return items;
        }

        for (Object rowObj : rows) {
            Map<String, Object> row = (Map<String, Object>) rowObj;
            String sourceUrl = (String) row.get('link');
            String title = (String) row.get('title');
            if (String.isBlank(title) || String.isBlank(sourceUrl)) {
                continue;
            }

            NewsSignalService.NewsItem item = new NewsSignalService.NewsItem();
            item.companyName = companyName;
            item.title = title;
            item.summary = (String) row.get('summary');
            item.sourceUrl = sourceUrl;
            item.publishedDate = parsePublishDate((String) row.get('publishDate'));
            item.relevanceScore = 60;
            item.confidence = 60;
            items.add(item);
        }
        return items;
    }

    /**
     * Finlight publishDate(ISO 8601, 예: "2026-08-19T10:06:49.000Z")에서 날짜를 추출한다.
     * 앞 10자(YYYY-MM-DD)만 사용해 시간대 변환 없이 표기 날짜를 그대로 쓴다.
     */
    @TestVisible
    private static Date parsePublishDate(String raw) {
        if (String.isBlank(raw) || raw.length() < 10) {
            return null;
        }
        String datePart = raw.substring(0, 10);
        List<String> parts = datePart.split('-');
        if (parts.size() != 3 || !parts[0].isNumeric() || !parts[1].isNumeric() || !parts[2].isNumeric()) {
            return null;
        }
        return Date.newInstance(
            Integer.valueOf(parts[0]),
            Integer.valueOf(parts[1]),
            Integer.valueOf(parts[2])
        );
    }
}