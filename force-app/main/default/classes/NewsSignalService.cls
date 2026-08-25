/**
 * 기업 뉴스를 ExternalSignal__c(Signal_Type__c='뉴스')로 적재하는 서비스.
 *
 * 뉴스 소스(포털/벤더 API)는 org 에 아직 Named Credential 이 구성돼 있지 않으므로,
 * 이 서비스는 소스에 종속되지 않도록 수집된 뉴스 항목(NewsItem)을 입력받아
 * Account 매핑·중복 제거·적재만 담당한다. 실제 외부 콜아웃 계층은 커넥션 구성 후
 * 이 서비스의 ingest(...) 를 호출하도록 별도로 연결한다.
 *
 * 매핑 규칙:
 *  - corpCode(Account.Assigned_Company_Code__c) 우선, 없으면 companyName(Account.Name)으로 매핑
 *  - Source_URL__c 를 자연키로 사용해 이미 적재된 뉴스는 건너뛴다(ExternalSignal__c 에 External ID 없음)
 */
public with sharing class NewsSignalService {
    private static final String SIGNAL_TYPE_NEWS = '뉴스';

    public class NewsSignalException extends Exception {}

    /**
     * 단일 기업 뉴스 항목을 담는 입력 DTO. 뉴스 소스와 무관하게 정규화된 형태로 전달한다.
     */
    public class NewsItem {
        public String corpCode;      // Account.Assigned_Company_Code__c (선택)
        public String companyName;   // Account.Name (corpCode 없을 때 매핑에 사용)
        public String title;
        public String summary;
        public Date publishedDate;
        public String sourceUrl;     // 원문 URL — 자연키(필수)
        public Decimal relevanceScore;
        public Decimal confidence;

        public NewsItem() {}
    }

    /**
     * 뉴스 항목들을 ExternalSignal__c 로 적재한다. Source_URL__c 기준으로 이미 적재된 건은 제외한다.
     *
     * @param items 정규화된 뉴스 항목 목록
     * @return 새로 insert 된 ExternalSignal__c 목록(중복·매핑 실패 제외)
     * @throws NewsSignalException 입력 항목의 필수값(제목/URL) 누락 시
     */
    public static List<ExternalSignal__c> ingest(List<NewsItem> items) {
        List<ExternalSignal__c> inserted = new List<ExternalSignal__c>();
        if (items == null || items.isEmpty()) {
            return inserted;
        }

        // 매핑에 필요한 키 수집
        Set<String> corpCodes = new Set<String>();
        Set<String> companyNames = new Set<String>();
        Set<String> sourceUrls = new Set<String>();
        for (NewsItem item : items) {
            if (String.isBlank(item.title) || String.isBlank(item.sourceUrl)) {
                throw new NewsSignalException('뉴스 항목의 title, sourceUrl 은 필수입니다.');
            }
            if (String.isNotBlank(item.corpCode)) {
                corpCodes.add(item.corpCode);
            }
            if (String.isNotBlank(item.companyName)) {
                companyNames.add(item.companyName);
            }
            sourceUrls.add(item.sourceUrl);
        }

        Map<String, Id> accountIdByCorpCode = new Map<String, Id>();
        Map<String, Id> accountIdByName = new Map<String, Id>();
        for (Account account : [
            SELECT Id, Name, Assigned_Company_Code__c
            FROM Account
            WHERE Assigned_Company_Code__c IN :corpCodes
               OR Name IN :companyNames
            WITH USER_MODE
        ]) {
            if (String.isNotBlank(account.Assigned_Company_Code__c)) {
                accountIdByCorpCode.put(account.Assigned_Company_Code__c, account.Id);
            }
            if (String.isNotBlank(account.Name) && !accountIdByName.containsKey(account.Name)) {
                accountIdByName.put(account.Name, account.Id);
            }
        }

        Set<String> existingUrls = new Set<String>();
        for (ExternalSignal__c existing : [
            SELECT Source_URL__c
            FROM ExternalSignal__c
            WHERE Source_URL__c IN :sourceUrls
            WITH USER_MODE
        ]) {
            existingUrls.add(existing.Source_URL__c);
        }

        Map<String, ExternalSignal__c> signalBySourceUrl = new Map<String, ExternalSignal__c>();
        for (NewsItem item : items) {
            if (existingUrls.contains(item.sourceUrl)) {
                continue;
            }
            Id accountId = resolveAccountId(item, accountIdByCorpCode, accountIdByName);
            // 입력 배치 내 중복 URL 은 마지막 항목으로 수렴
            signalBySourceUrl.put(item.sourceUrl, buildSignal(item, accountId));
        }

        inserted = signalBySourceUrl.values();
        if (!inserted.isEmpty()) {
            Database.insert(inserted, AccessLevel.USER_MODE);
        }
        return inserted;
    }

    private static Id resolveAccountId(
        NewsItem item,
        Map<String, Id> accountIdByCorpCode,
        Map<String, Id> accountIdByName
    ) {
        if (String.isNotBlank(item.corpCode) && accountIdByCorpCode.containsKey(item.corpCode)) {
            return accountIdByCorpCode.get(item.corpCode);
        }
        if (String.isNotBlank(item.companyName) && accountIdByName.containsKey(item.companyName)) {
            return accountIdByName.get(item.companyName);
        }
        return null;
    }

    private static ExternalSignal__c buildSignal(NewsItem item, Id accountId) {
        ExternalSignal__c signal = new ExternalSignal__c();
        signal.Account__c = accountId;
        signal.Signal_Type__c = SIGNAL_TYPE_NEWS;
        signal.Title__c = truncate(item.title, 255);
        signal.Summary__c = truncate(item.summary, 255);
        signal.Signal_Date__c = item.publishedDate;
        signal.Source_URL__c = item.sourceUrl;
        signal.Relevance_Score__c = item.relevanceScore;
        signal.Confidence__c = item.confidence;
        return signal;
    }

    private static String truncate(String value, Integer maxLength) {
        if (value == null) {
            return null;
        }
        return value.length() > maxLength ? value.substring(0, maxLength) : value;
    }
}