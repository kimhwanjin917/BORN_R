/**
 * RP 계약서 작성 Form 의 최종 제출이 호출하는 Contract 생성 진입점.
 *
 * 자동 실행되지 않는다 — 트리거·Queueable 로 걸지 않는다. 오직 이 static 메서드를 명시적으로
 * 부를 때만 Contract 를 만든다. (미팅 로그 저장 → 자동 심사 → 자동 계약 경로는 OpportunityReviewService
 * 가 이미 담당하며, 이 클래스는 그 경로를 대체하지도 수정하지도 않는다.)
 *
 * Contract·PDF·파일 연결의 실제 생성은 기존 ContractDocumentService.createContracts 를 그대로 재사용한다.
 * 이 클래스가 더하는 것은 (1) 생성 전 검증, (2) SourceOpportunity 기준 중복 방지, (3) 생성 후
 * Form 흐름에 필요한 값 스냅샷 보정(시작/종료일·담당 Contact·수수료·수익률 구조)뿐이다.
 *
 * Form 이 수정한 최종 조건은 이미 RpTermConfirmController.confirmTerms 가 Opportunity 에 저장하므로
 * (조건 확정 = Opportunity 에 persist), 이 진입점은 Opportunity 를 source of truth 로 읽는다.
 */
public with sharing class RpContractCreationService {

    /** 삭제되지 않은 Contract 는 상태와 무관하게(Draft/In Approval Process/Activated) 중복으로 본다. */
    public class Result {
        @AuraEnabled public Id contractId;
        @AuraEnabled public String contractNumber;
        @AuraEnabled public Id contentDocumentId;
        @AuraEnabled public String fileName;
        @AuraEnabled public Boolean created = false;   // 이번 호출로 새로 만들었는가
        @AuraEnabled public Boolean reused = false;    // 기존 Contract 를 그대로 돌려주었는가
        @AuraEnabled public String message;
    }

    // @AuraEnabled 는 오버로드를 허용하지 않는다 — Form/LWC 진입점은 2-인자 버전 하나만 노출한다.
    public static Result createContract(Id opportunityId) {
        return createContract(opportunityId, null);
    }

    /**
     * @param opportunityId 계약을 만들 원본 영업기회. 확정 조건은 이 Opportunity 에 이미 저장돼 있어야 한다.
     * @param contactId     계약 업무 담당 고객사 Contact (선택). Contract.Contact__c 에 연결한다.
     */
    @AuraEnabled
    public static Result createContract(Id opportunityId, Id contactId) {
        Opportunity opp = loadOpportunity(opportunityId);

        List<String> errors = validate(opp);
        if (!errors.isEmpty()) {
            throw new AuraHandledException(String.join(errors, '\n'));
        }

        // 1) 중복 방지 — 이 Opportunity 에 이미 Contract 가 있으면 새로 만들지 않고 그대로 돌려준다.
        Result existing = findExistingContract(opportunityId);
        if (existing != null) {
            return existing;
        }

        // 2) 실제 Contract + PDF + 파일 연결은 기존 서비스 그대로 재사용
        Map<Id, ContractDocumentService.Result> byOpp =
            ContractDocumentService.createContracts(new List<Opportunity>{ new Opportunity(Id = opportunityId) });
        ContractDocumentService.Result cr = byOpp.get(opportunityId);
        if (cr == null || !cr.isSuccess || cr.contractId == null) {
            throw new AuraHandledException('계약서 생성에 실패했습니다: ' + (cr == null ? '알 수 없는 오류' : cr.errorMessage));
        }

        // 3) Form 흐름 스냅샷 보정 — 기존 서비스가 채우지 않는 값만 덮어쓴다.
        //    기존 서비스는 StartDate 를 오늘로 두고 Contact__c·Fee_Amount__c·Yield_Structure__c 를 채우지 않는다.
        //    표준 Contract.EndDate 는 StartDate + ContractTerm 으로 계산되는 읽기 전용 파생 필드라 직접 쓸 수
        //    없다 — 계약 종료일(만기)은 커스텀 Maturity_Date__c 가 담는다.
        //    Deal_Direction__c·Yield_Basis__c 도 확정 시점 조건이므로 여기서 스냅샷한다 — 특히 Yield_Basis__c
        //    (세전/세후)는 세금·환매예정금액 계산의 기준이라, 계약 후 Opportunity 값이 바뀌어도 계약 당시
        //    계산을 재현할 수 있도록 Contract 에 독립 보존한다.
        //    이 값들은 사용자가 타이핑하는 값이 아니라 서비스가 Opportunity 에서 옮겨 보존하는 스냅샷이므로
        //    SYSTEM_MODE 로 쓴다 — 신규 커스텀 필드는 프로필/권한셋 FLS 가 아직 없어 USER_MODE 로는 거부된다
        //    (권한셋은 팀이 org UI 에서 관리한다는 규칙상 코드로 FLS 를 부여하지 않는다). 클래스는 with sharing
        //    이라 레코드 공유 규칙은 그대로 지킨다.
        //    담당 Contact 는 전달된 contactId 우선, 없으면 Opportunity.ContactId 로 보완한다(둘 다 없으면 null).
        //    Account 의 임의 첫 Contact 를 고르지 않는다 — 실제 거래 상대가 아닐 수 있다.
        Contract con = new Contract(
            Id = cr.contractId,
            StartDate = opp.Contract_Start_Date__c,
            Maturity_Date__c = opp.RP_Maturity_Date__c,
            Contact__c = contactId != null ? contactId : opp.ContactId,
            Fee_Amount__c = opp.Fee_Amount__c,
            Yield_Structure__c = opp.Yield_Structure__c,
            Deal_Direction__c = opp.Deal_Direction__c,
            Yield_Basis__c = opp.Yield_Basis__c
        );
        Database.update(con, true, AccessLevel.SYSTEM_MODE);

        Result r = new Result();
        r.created = true;
        r.contractId = cr.contractId;
        r.contentDocumentId = cr.contentDocumentId;
        r.fileName = cr.fileName;
        r.contractNumber = [
            SELECT ContractNumber FROM Contract WHERE Id = :cr.contractId WITH USER_MODE LIMIT 1
        ].ContractNumber;
        r.message = '계약서 ' + r.contractNumber + ' 를 생성했습니다.';
        return r;
    }

    // ─── 내부 ─────────────────────────────────────────────────────────

    private static Opportunity loadOpportunity(Id opportunityId) {
        List<Opportunity> opps = [
            SELECT Id, Name, AccountId, ContactId, Primary_Product__c, Amount, RP_Yield__c, Fee_Rate__c, Fee_Amount__c,
                   Contract_Start_Date__c, RP_Maturity_Date__c, Yield_Structure__c, Deal_Direction__c, Yield_Basis__c
            FROM Opportunity
            WHERE Id = :opportunityId
            WITH USER_MODE
            LIMIT 1
        ];
        if (opps.isEmpty()) {
            throw new AuraHandledException('영업기회를 찾을 수 없거나 접근 권한이 없습니다.');
        }
        return opps[0];
    }

    /** 확정 조건이 준비된 Opportunity 인지까지 함께 본다 — 필수 조건 필드가 비어 있으면 준비되지 않은 것이다. */
    @TestVisible
    private static List<String> validate(Opportunity opp) {
        List<String> errors = new List<String>();
        if (opp.AccountId == null)              { errors.add('고객사(Account)가 없어 계약을 만들 수 없습니다.'); }
        if (opp.Primary_Product__c == null)     { errors.add('상품이 선택되지 않았습니다.'); }
        if (opp.Amount == null)                 { errors.add('계약금액이 없습니다.'); }
        if (opp.Contract_Start_Date__c == null) { errors.add('계약 시작일이 없습니다.'); }
        if (opp.RP_Maturity_Date__c == null)    { errors.add('계약 종료일이 없습니다.'); }
        if (opp.RP_Yield__c == null)            { errors.add('RP 약정수익률이 없습니다.'); }

        if (opp.Contract_Start_Date__c != null && opp.RP_Maturity_Date__c != null
                && opp.RP_Maturity_Date__c < opp.Contract_Start_Date__c) {
            errors.add('계약 종료일은 시작일보다 빠를 수 없습니다.');
        }
        return errors;
    }

    /** 이 Opportunity 에서 나온 Contract 가 이미 있으면 Result 로 감싸 돌려준다. 없으면 null. */
    private static Result findExistingContract(Id opportunityId) {
        List<Contract> cons = [
            SELECT Id, ContractNumber FROM Contract
            WHERE SourceOpportunityId = :opportunityId
            WITH USER_MODE
            ORDER BY CreatedDate ASC
            LIMIT 1
        ];
        if (cons.isEmpty()) {
            return null;
        }
        Result r = new Result();
        r.reused = true;
        r.contractId = cons[0].Id;
        r.contractNumber = cons[0].ContractNumber;
        List<ContentDocumentLink> links = [
            SELECT ContentDocumentId FROM ContentDocumentLink
            WHERE LinkedEntityId = :cons[0].Id
            WITH USER_MODE
            ORDER BY SystemModstamp DESC
            LIMIT 1
        ];
        if (!links.isEmpty()) {
            r.contentDocumentId = links[0].ContentDocumentId;
        }
        r.message = '이미 계약서 ' + r.contractNumber + ' 가 존재하여 새로 만들지 않았습니다.';
        return r;
    }
}