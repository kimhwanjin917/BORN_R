/**
 * 네이버 검색 OpenAPI(뉴스 검색)에서 기업명으로 뉴스를 수집해
 * ExternalSignal__c(Signal_Type__c='뉴스')로 적재하는 서비스.
 *
 * 엔드포인트는 Named Credential(callout:Naver_OpenAPI)로, 인증 정보(Client Id/Secret)는
 * Naver_Setting__mdt.Default 에서 읽어 X-Naver-Client-Id / X-Naver-Client-Secret 헤더로
 * 전달한다(네이버는 쿼리파라미터가 아닌 헤더 인증을 사용).
 *
 * 수집한 뉴스 항목은 NewsSignalService.NewsItem 으로 정규화한 뒤 NewsSignalService.ingest 에
 * 위임한다. Account 매핑(기업명 기준)·Source_URL__c 자연키 중복 제거·적재는 모두
 * NewsSignalService 가 담당하므로 이 서비스는 콜아웃과 응답 정규화에만 집중한다.
 */
public with sharing class NaverNewsService {
    @TestVisible
    private static final String NAMED_CREDENTIAL = 'callout:Naver_OpenAPI';
    // 뉴스 검색 API. query(검색어) 기준 뉴스 목록(title·description·originallink·pubDate 등)을 반환한다.
    private static final String API_PATH = '/v1/search/news.json';
    private static final Integer TIMEOUT_MS = 120000;
    // 한 번에 가져올 검색 결과 수(네이버 허용 최대 100).
    private static final Integer DISPLAY_COUNT = 100;

    private static final String HEADER_CLIENT_ID = 'X-Naver-Client-Id';
    private static final String HEADER_CLIENT_SECRET = 'X-Naver-Client-Secret';

    // pubDate 파싱용 영문 월 약어 → 월 번호 매핑(로케일 비의존).
    private static final Map<String, Integer> MONTH_BY_ABBREVIATION = new Map<String, Integer>{
        'Jan' => 1, 'Feb' => 2, 'Mar' => 3, 'Apr' => 4, 'May' => 5, 'Jun' => 6,
        'Jul' => 7, 'Aug' => 8, 'Sep' => 9, 'Oct' => 10, 'Nov' => 11, 'Dec' => 12
    };

    public class NaverNewsException extends Exception {}

    /**
     * 단일 기업명으로 네이버 뉴스를 검색해 ExternalSignal__c 로 적재한다.
     * Source_URL__c 기준으로 이미 적재된 뉴스는 NewsSignalService 에서 건너뛴다.
     *
     * @param companyName 검색·매핑 대상 기업명(Account.Name)
     * @return 새로 insert 된 ExternalSignal__c 목록(중복·매핑 실패 제외)
     * @throws NaverNewsException 인증정보 미설정·콜아웃 실패·네이버 오류 응답 시
     */
    public static List<ExternalSignal__c> collectNews(String companyName) {
        if (String.isBlank(companyName)) {
            throw new NaverNewsException('companyName 은 필수입니다.');
        }

        HttpResponse response = sendRequest(companyName);
        Integer status = response.getStatusCode();
        if (status >= 500 || status == 429) {
            throw new NaverNewsException('네이버 일시적 오류(HTTP ' + status + '). 재시도 대상입니다.');
        }
        if (status != 200) {
            throw new NaverNewsException('네이버 호출 실패(HTTP ' + status + '): ' + response.getBody());
        }

        List<NewsSignalService.NewsItem> items = parse(response.getBody(), companyName);
        return NewsSignalService.ingest(items);
    }

    private static HttpResponse sendRequest(String companyName) {
        Naver_Setting__mdt setting = getSetting();
        String clientId = setting.Client_Id__c;
        String clientSecret = setting.Client_Secret__c;

        String endpoint =
            NAMED_CREDENTIAL +
            API_PATH +
            '?query=' + EncodingUtil.urlEncode(companyName, 'UTF-8') +
            '&display=' + DISPLAY_COUNT +
            '&sort=date';

        HttpRequest request = new HttpRequest();
        request.setEndpoint(endpoint);
        request.setMethod('GET');
        request.setTimeout(TIMEOUT_MS);
        request.setHeader(HEADER_CLIENT_ID, clientId);
        request.setHeader(HEADER_CLIENT_SECRET, clientSecret);

        try {
            return new Http().send(request);
        } catch (System.CalloutException e) {
            throw new NaverNewsException('네이버 콜아웃 예외: ' + e.getMessage(), e);
        }
    }

    @TestVisible
    private static String testClientId;
    @TestVisible
    private static String testClientSecret;

    @TestVisible
    private static Naver_Setting__mdt getSetting() {
        if (Test.isRunningTest()) {
            if (String.isBlank(testClientId) || String.isBlank(testClientSecret)) {
                throw new NaverNewsException('네이버 인증정보가 설정되지 않았습니다. Naver_Setting__mdt.Default 를 확인하세요.');
            }
            Naver_Setting__mdt testSetting = new Naver_Setting__mdt();
            testSetting.Client_Id__c = testClientId;
            testSetting.Client_Secret__c = testClientSecret;
            return testSetting;
        }
        Naver_Setting__mdt setting = Naver_Setting__mdt.getInstance('Default');
        if (setting == null || String.isBlank(setting.Client_Id__c) || String.isBlank(setting.Client_Secret__c)) {
            throw new NaverNewsException('네이버 인증정보가 설정되지 않았습니다. Naver_Setting__mdt.Default 를 확인하세요.');
        }
        return setting;
    }

    private static List<NewsSignalService.NewsItem> parse(String body, String companyName) {
        Map<String, Object> parsed;
        try {
            parsed = (Map<String, Object>) JSON.deserializeUntyped(body);
        } catch (System.JSONException e) {
            throw new NaverNewsException('네이버 응답 파싱 실패: ' + e.getMessage(), e);
        }

        // 네이버는 오류 시 errorCode/errorMessage 를 반환한다.
        if (parsed.containsKey('errorCode')) {
            throw new NaverNewsException(
                '네이버 오류(' + parsed.get('errorCode') + '): ' + parsed.get('errorMessage')
            );
        }

        List<NewsSignalService.NewsItem> items = new List<NewsSignalService.NewsItem>();
        List<Object> rows = (List<Object>) parsed.get('items');
        if (rows == null) {
            return items;
        }

        for (Object rowObj : rows) {
            Map<String, Object> row = (Map<String, Object>) rowObj;
            // originallink 우선(원문 URL), 없으면 link(네이버 뉴스 URL).
            String sourceUrl = (String) row.get('originallink');
            if (String.isBlank(sourceUrl)) {
                sourceUrl = (String) row.get('link');
            }
            String title = cleanText((String) row.get('title'));
            if (String.isBlank(title) || String.isBlank(sourceUrl)) {
                continue;
            }

            NewsSignalService.NewsItem item = new NewsSignalService.NewsItem();
            item.companyName = companyName;
            item.title = title;
            item.summary = cleanText((String) row.get('description'));
            item.sourceUrl = sourceUrl;
            item.publishedDate = parsePubDate((String) row.get('pubDate'));
            item.relevanceScore = 60;
            item.confidence = 60;
            items.add(item);
        }
        return items;
    }

    /**
     * 네이버 응답의 title/description 에 포함된 &lt;b&gt; 태그와 HTML 엔티티를 제거·복원한다.
     */
    @TestVisible
    private static String cleanText(String raw) {
        if (String.isBlank(raw)) {
            return raw;
        }
        String cleaned = raw.replaceAll('<[^>]+>', '');
        cleaned = cleaned.replace('&lt;', '<')
            .replace('&gt;', '>')
            .replace('&quot;', '"')
            .replace('&#39;', '\'')
            .replace('&apos;', '\'')
            .replace('&amp;', '&');
        return cleaned.trim();
    }

    /**
     * 네이버 pubDate(RFC-1123, 예: "Mon, 26 Sep 2016 07:50:00 +0900")에서 날짜를 추출한다.
     * 시간대 변환 없이 표기된 날짜를 그대로 사용한다.
     */
    @TestVisible
    private static Date parsePubDate(String raw) {
        if (String.isBlank(raw)) {
            return null;
        }
        // 요일 접두어(예: "Mon, ")를 제거하고 공백으로 분리 → [dd, MMM, yyyy, ...]
        List<String> parts = raw.replaceAll(',', '').trim().split('\\s+');
        if (parts.size() < 4) {
            return null;
        }
        Integer dayIndex = parts[0].isNumeric() ? 0 : 1;
        if (parts.size() < dayIndex + 3) {
            return null;
        }
        String dayToken = parts[dayIndex];
        String monthToken = parts[dayIndex + 1];
        String yearToken = parts[dayIndex + 2];
        if (!dayToken.isNumeric() || !yearToken.isNumeric()) {
            return null;
        }
        Integer month = MONTH_BY_ABBREVIATION.get(monthToken);
        if (month == null) {
            return null;
        }
        return Date.newInstance(
            Integer.valueOf(yearToken),
            month,
            Integer.valueOf(dayToken)
        );
    }
}