/**
 * RM_Assistant 보조 — "내 진행 중 기회", "최근 생긴 기회", "OOO 담당 기회", "OO사 관련 기회" 같은
 * 일반 파이프라인 조회 질문에 답하기 위한 Invocable 액션.
 *
 * - with sharing + WITH USER_MODE: 실행 사용자가 볼 수 있는 기회만 반환 (타 RM 딜은 0건).
 * - 예외 대신 빈 목록 반환.
 */
public with sharing class OpportunityListAction {

    @TestVisible
    private static final Integer MAX_RESULTS = 10;

    public class Request {
        @InvocableVariable(
            label='내 기회만'
            description='true 면 실행 사용자가 담당(Owner)인 기회만. 기본 false')
        public Boolean mineOnly;
        @InvocableVariable(
            label='담당자 이름'
            description='선택. 담당자(Owner) 이름의 일부. 예: 김도현')
        public String ownerName;
        @InvocableVariable(
            label='고객사/기회 키워드'
            description='선택. 기회 이름 또는 고객사 이름의 일부. 예: 성우하이텍')
        public String keyword;
        @InvocableVariable(
            label='진행 중만'
            description='true 면 종결되지 않은(IsClosed=false) 기회만. 기본 true')
        public Boolean openOnly;
        @InvocableVariable(
            label='정렬'
            description='recent(최근 생성순, 기본) | close(마감일 빠른순) | amount(금액 큰순)')
        public String sortBy;
    }

    public class Item {
        @InvocableVariable(label='Opportunity Id')
        public Id opportunityId;
        @InvocableVariable(label='기회명')
        public String opportunityName;
        @InvocableVariable(label='고객사명')
        public String accountName;
        @InvocableVariable(label='담당자')
        public String ownerName;
        @InvocableVariable(label='금액')
        public Decimal amount;
        @InvocableVariable(label='단계')
        public String stageName;
        @InvocableVariable(label='마감 예정일')
        public Date closeDate;
        @InvocableVariable(label='생성일')
        public Date createdDate;
    }

    public class Result {
        @InvocableVariable(label='결과 수' description='반환된 기회 수 (최대 10). 0이면 접근 가능한 기회 없음')
        public Integer itemCount;
        @InvocableVariable(label='기회 목록')
        public List<Item> items;
        @InvocableVariable(label='메시지')
        public String message;
        @InvocableVariable(label='종결 건으로 대체됨' description='true 면 진행 중 기회가 0건이라 종결된 기회를 대신 반환한 것')
        public Boolean closedFallback;
    }

    @InvocableMethod(
        label='기회 목록 조회 (내 기회/최근/담당자/고객사)'
        description='조건(내 기회만, 담당자 이름, 고객사·기회 키워드, 진행 중 여부, 정렬)으로 실행 사용자가 접근 가능한 Opportunity 를 최대 10건 반환합니다.'
        category='근본증권 RM')
    public static List<Result> listOpportunities(List<Request> requests) {
        List<Result> results = new List<Result>();
        if (requests == null) {
            return results;
        }
        for (Request req : requests) {
            results.add(listOne(req));
        }
        return results;
    }

    private static Result listOne(Request req) {
        Result res = query(req, false);
        // 진행 중만 조회했는데 0건이면 종결 건까지 넓혀 한 번 더 조회 (사용자에게 "진행 중은 없고 종결 N건" 안내용)
        if (res.itemCount == 0 && res.items != null && (req == null || req.openOnly != false)) {
            Result closed = query(req, true);
            if (closed.itemCount > 0) {
                closed.closedFallback = true;
                closed.message = '진행 중인 기회는 없고, 종결된 기회 ' + closed.itemCount + '건이 있습니다. ' + closed.message;
                return closed;
            }
        }
        return res;
    }

    private static Result query(Request req, Boolean forceIncludeClosed) {
        Result res = new Result();
        res.closedFallback = false;
        res.items = new List<Item>();
        res.itemCount = 0;
        if (req == null) {
            req = new Request();
        }

        Boolean mineOnly = req.mineOnly == true;
        Boolean openOnly = forceIncludeClosed ? false : (req.openOnly != false); // 기본 true
        // 담당자 이름: 이 org 의 User.Name 은 "김 도현"처럼 성·이름 사이에 공백이 있으므로
        // 공백 없이 들어온 한글 이름("김도현")은 "김 도현" 형태도 함께 매칭한다.
        List<String> ownerPatterns = null;
        String ownerPattern = null;
        if (!String.isBlank(req.ownerName)) {
            String rawName = req.ownerName.trim();
            ownerPatterns = new List<String>{ '%' + String.escapeSingleQuotes(rawName) + '%' };
            String compact = rawName.replaceAll('\\s+', '');
            if (compact.length() >= 2) {
                ownerPatterns.add('%' + String.escapeSingleQuotes(compact.substring(0, 1) + ' ' + compact.substring(1)) + '%');
                if (compact.length() >= 3) {
                    ownerPatterns.add('%' + String.escapeSingleQuotes(compact.substring(0, 2) + ' ' + compact.substring(2)) + '%');
                }
            }
            ownerPattern = ownerPatterns[0];
        }
        String kwPattern = String.isBlank(req.keyword) ? null : '%' + String.escapeSingleQuotes(req.keyword.trim()) + '%';
        String sortBy = String.isBlank(req.sortBy) ? 'recent' : req.sortBy.trim().toLowerCase();
        Id me = UserInfo.getUserId();
        Integer maxResults = MAX_RESULTS;

        String orderBy;
        if (sortBy == 'close') {
            orderBy = 'CloseDate ASC';
        } else if (sortBy == 'amount') {
            orderBy = 'Amount DESC NULLS LAST';
        } else {
            orderBy = 'CreatedDate DESC';
        }

        String soql = 'SELECT Id, Name, Amount, StageName, CloseDate, CreatedDate, IsClosed, Account.Name, Owner.Name '
            + 'FROM Opportunity WHERE Id != null';
        if (mineOnly) {
            soql += ' AND OwnerId = :me';
        }
        if (ownerPattern != null) {
            soql += ' AND Owner.Name LIKE :ownerPatterns';
        }
        if (kwPattern != null) {
            soql += ' AND (Name LIKE :kwPattern OR Account.Name LIKE :kwPattern)';
        }
        if (openOnly) {
            soql += ' AND IsClosed = false';
        }
        soql += ' WITH USER_MODE ORDER BY ' + orderBy + ' LIMIT :maxResults';

        List<Opportunity> opps;
        try {
            opps = Database.query(soql);
        } catch (QueryException e) {
            res.message = '기회를 조회할 권한이 없어 결과를 가져오지 못했습니다. (' + e.getMessage() + ')';
            return res;
        }

        for (Opportunity opp : opps) {
            Item it = new Item();
            it.opportunityId = opp.Id;
            it.opportunityName = opp.Name;
            it.accountName = opp.Account == null ? null : opp.Account.Name;
            it.ownerName = opp.Owner == null ? null : opp.Owner.Name;
            it.amount = opp.Amount;
            it.stageName = opp.StageName;
            it.closeDate = opp.CloseDate;
            it.createdDate = opp.CreatedDate == null ? null : opp.CreatedDate.date();
            res.items.add(it);
        }
        res.itemCount = res.items.size();

        List<String> cond = new List<String>();
        if (mineOnly) {
            cond.add('내 담당');
        }
        if (ownerPattern != null) {
            cond.add('담당자 "' + req.ownerName.trim() + '"');
        }
        if (kwPattern != null) {
            cond.add('키워드 "' + req.keyword.trim() + '"');
        }
        cond.add(openOnly ? '진행 중' : '전체(종결 포함)');
        String condText = String.join(cond, ', ');
        res.message = res.itemCount == 0
            ? '조건(' + condText + ')에 맞는 접근 가능한 기회가 없습니다.'
            : '조건(' + condText + ') 기회 ' + res.itemCount + '건.';
        return res;
    }
}