/**
 * Lead 단계 상품추천 보조 — 에이전트가 사용자의 말(회사명/담당자명 키워드)로 미전환 Lead 를 찾을 때 쓰는 Invocable 액션.
 * OpportunityLookupAction 과 같은 패턴.
 *
 * - with sharing + WITH USER_MODE: 실행 사용자가 볼 수 있는 Lead 만 반환.
 * - 전환된 Lead 는 제외(추천은 Opportunity 쪽 액션이 담당).
 * - 접근 불가/검색 결과 없음이면 빈 목록 (예외 없음).
 * - 반환된 leadId 는 LeadProductRecommendationAction / LeadRecommendationSaveAction 입력으로 쓴다.
 */
public with sharing class LeadLookupAction {

    @TestVisible
    private static final Integer MAX_RESULTS = 5;

    public class Request {
        @InvocableVariable(
            label='검색어'
            description='회사명 또는 담당자 이름의 일부. 예: 대성정밀, 씨앤씨'
            required=true)
        public String keyword;
    }

    public class Match {
        @InvocableVariable(label='Lead Id' description='Lead 레코드 Id')
        public Id leadId;
        @InvocableVariable(label='회사명' description='Lead.Company')
        public String company;
        @InvocableVariable(label='담당자 이름' description='Lead.name_new__c')
        public String contactName;
        @InvocableVariable(label='산업군' description='Lead.Industry')
        public String industry;
        @InvocableVariable(label='상태' description='Lead.Status')
        public String status;
        @InvocableVariable(label='우선순위 점수' description='Lead.Priority_Score__c')
        public Decimal priorityScore;
        @InvocableVariable(label='추천 상품군' description='이미 기록된 추천 상품군(RP/회사채). 비어 있으면 미정')
        public String recommendedProductFamily;
    }

    public class Result {
        @InvocableVariable(label='검색 결과 수' description='반환된 Lead 수 (최대 5). 0이면 접근 가능한 Lead 가 없음')
        public Integer matchCount;
        @InvocableVariable(label='Lead 목록' description='실행 사용자가 접근 가능한 미전환 Lead 후보 (최대 5건)')
        public List<Match> matches;
        @InvocableVariable(label='메시지' description='사람이 읽을 수 있는 요약')
        public String message;
    }

    @InvocableMethod(
        label='Lead 검색 (회사명/담당자 키워드)'
        description='회사명 또는 담당자 이름에 검색어가 포함된 미전환 Lead 를 실행 사용자 권한으로 최대 5건 찾아 Id·회사·담당자·산업군·상태·우선순위·추천 상품군을 반환합니다. 없으면 빈 목록입니다.'
        category='근본증권 RM')
    public static List<Result> search(List<Request> requests) {
        List<Result> results = new List<Result>();
        if (requests == null) {
            return results;
        }
        for (Request req : requests) {
            results.add(searchOne(req));
        }
        return results;
    }

    private static Result searchOne(Request req) {
        Result res = new Result();
        res.matches = new List<Match>();
        res.matchCount = 0;

        String keyword = (req == null || req.keyword == null) ? '' : req.keyword.trim();
        if (keyword.length() == 0) {
            res.message = '검색어가 비어 있습니다. 회사명이나 담당자 이름을 알려주세요.';
            return res;
        }

        String pattern = '%' + String.escapeSingleQuotes(keyword) + '%';
        List<Lead> leads;
        try {
            leads = [
                SELECT Id, Company, name_new__c, Industry, Status, Priority_Score__c,
                       Recommended_Product_Family__c
                FROM Lead
                WHERE IsConverted = false
                  AND (Company LIKE :pattern OR name_new__c LIKE :pattern OR Name LIKE :pattern)
                WITH USER_MODE
                ORDER BY Priority_Score__c DESC NULLS LAST, LastModifiedDate DESC
                LIMIT :MAX_RESULTS
            ];
        } catch (QueryException e) {
            res.message = 'Lead 를 조회할 권한이 없어 결과를 가져오지 못했습니다. (' + e.getMessage() + ')';
            return res;
        }

        for (Lead ld : leads) {
            Match m = new Match();
            m.leadId = ld.Id;
            m.company = ld.Company;
            m.contactName = ld.name_new__c;
            m.industry = ld.Industry;
            m.status = ld.Status;
            m.priorityScore = ld.Priority_Score__c;
            m.recommendedProductFamily = ld.Recommended_Product_Family__c;
            res.matches.add(m);
        }
        res.matchCount = res.matches.size();
        res.message = res.matchCount == 0
            ? '"' + keyword + '"(으)로 접근 가능한 미전환 Lead 를 찾지 못했습니다.'
            : '"' + keyword + '" 검색 결과 ' + res.matchCount + '건.';
        return res;
    }
}