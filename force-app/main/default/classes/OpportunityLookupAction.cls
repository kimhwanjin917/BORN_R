/**
 * 백로그 20 보조 — 에이전트가 사용자의 말(기업명/기회명 키워드)로 Opportunity 를 찾을 때 쓰는 Invocable 액션.
 *
 * - with sharing + WITH USER_MODE: 실행 사용자가 볼 수 있는 기회만 반환 (타 RM 딜은 0건 — E5 권한 경계 시연 포인트).
 * - 접근 불가/검색 결과 없음이면 빈 목록 (예외 없음).
 * - 반환된 opportunityId 는 ProductRecommendationAction / GetSanitizedMeetingNote 입력으로 쓴다.
 */
public with sharing class OpportunityLookupAction {

    @TestVisible
    private static final Integer MAX_RESULTS = 5;

    public class Request {
        @InvocableVariable(
            label='검색어'
            description='기회 이름 또는 고객사(Account) 이름의 일부. 예: 근본테스트, 주식회사 A'
            required=true)
        public String keyword;
    }

    public class Match {
        @InvocableVariable(label='Opportunity Id' description='기회 레코드 Id')
        public Id opportunityId;
        @InvocableVariable(label='기회명' description='Opportunity.Name')
        public String opportunityName;
        @InvocableVariable(label='고객사명' description='Account.Name')
        public String accountName;
        @InvocableVariable(label='산업군' description='Account.Industry')
        public String accountIndustry;
        @InvocableVariable(label='금액' description='Opportunity.Amount')
        public Decimal amount;
        @InvocableVariable(label='단계' description='Opportunity.StageName')
        public String stageName;
    }

    public class Result {
        @InvocableVariable(label='검색 결과 수' description='반환된 기회 수 (최대 5). 0이면 접근 가능한 기회가 없음')
        public Integer matchCount;
        @InvocableVariable(label='기회 목록' description='실행 사용자가 접근 가능한 기회 후보 목록 (최대 5건)')
        public List<Match> matches;
        @InvocableVariable(label='메시지' description='사람이 읽을 수 있는 요약')
        public String message;
    }

    @InvocableMethod(
        label='기회 검색 (이름/고객사 키워드)'
        description='기회 이름 또는 고객사 이름에 검색어가 포함된 Opportunity 를 실행 사용자 권한으로 최대 5건 찾아 Id·이름·고객사·금액·단계를 반환합니다. 접근 권한이 없거나 없으면 빈 목록입니다.'
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
            res.message = '검색어가 비어 있습니다. 기회 이름이나 고객사 이름을 알려주세요.';
            return res;
        }

        String pattern = '%' + String.escapeSingleQuotes(keyword) + '%';
        List<Opportunity> opps;
        try {
            // USER_MODE: 실행 사용자의 객체/필드 권한과 공유 규칙을 그대로 적용 (타 RM 딜은 나오지 않음)
            opps = [
                SELECT Id, Name, Amount, StageName, Account.Name, Account.Industry
                FROM Opportunity
                WHERE Name LIKE :pattern OR Account.Name LIKE :pattern
                WITH USER_MODE
                ORDER BY IsClosed ASC, LastModifiedDate DESC
                LIMIT :MAX_RESULTS
            ];
        } catch (QueryException e) {
            // 객체/필드 권한 부족 등 — 예외 대신 빈 결과 (에이전트는 "조회 결과 없음"으로 처리)
            res.message = '기회를 조회할 권한이 없어 결과를 가져오지 못했습니다. (' + e.getMessage() + ')';
            return res;
        }

        for (Opportunity opp : opps) {
            Match m = new Match();
            m.opportunityId = opp.Id;
            m.opportunityName = opp.Name;
            m.accountName = opp.Account == null ? null : opp.Account.Name;
            m.accountIndustry = opp.Account == null ? null : opp.Account.Industry;
            m.amount = opp.Amount;
            m.stageName = opp.StageName;
            res.matches.add(m);
        }
        res.matchCount = res.matches.size();
        res.message = res.matchCount == 0
            ? '"' + keyword + '"(으)로 접근 가능한 기회를 찾지 못했습니다. (권한이 없거나 존재하지 않음)'
            : '"' + keyword + '" 검색 결과 ' + res.matchCount + '건.';
        return res;
    }
}