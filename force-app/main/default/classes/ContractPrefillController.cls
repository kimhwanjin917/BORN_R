/**
 * 영업기회 [계약서 작성] — 계약 생성 폼에 미리 채울 기본값을 계산한다.
 *
 * 상품팀 조건 확정이 끝난 Opportunity 에서 계약(Contract) 에 그대로 옮길 값을 모아
 * LWC(createContractAction) 가 표준 계약 생성 폼을 열 때 쓰는 defaultFieldValues 로 돌려준다.
 * 레코드를 만들지 않는다 — 저장은 RM 이 폼에서 직접 한다.
 *
 * - with sharing: 실행 사용자가 볼 수 있는 Opportunity 만 읽는다.
 * - 폼 자동 채우기는 계약 레이아웃에 있는 필드만 반영되므로, 여기 담는 필드는 레이아웃과 맞춰 둔다.
 * - 조건이 덜 채워졌으면(개시일·만기일 없음) ready=false 로 돌려주고 화면이 안내만 한다.
 * - 같은 영업기회로 만든 계약이 이미 있으면 계약번호를 함께 돌려준다(진행 여부는 RM 판단).
 */
public with sharing class ContractPrefillController {

    @TestVisible
    private static final String STATUS_DRAFT = 'Draft';

    /** 거래방향 값에 대응하는 계약 양식. 매칭되는 값이 없으면 '기타'. */
    private static final Map<String, String> FORM_BY_DIRECTION = new Map<String, String>{
        'RP 매수' => 'RP 매매계약서',
        'RP 매도' => 'RP 매매계약서'
    };

    /** 화면이 쓰는 결과 묶음. */
    public class Prefill {
        @AuraEnabled public Boolean ready;
        @AuraEnabled public String message;
        @AuraEnabled public String existingContractNumber;
        @AuraEnabled public Id existingContractId;
        @AuraEnabled public Map<String, Object> defaults;

        Prefill() {
            this.ready = false;
            this.defaults = new Map<String, Object>();
        }
    }

    /**
     * 영업기회 하나를 읽어 계약 폼 기본값을 만든다.
     * @param opportunityId 계약을 만들 영업기회
     */
    @AuraEnabled
    public static Prefill getPrefill(Id opportunityId) {
        Prefill result = new Prefill();
        if (opportunityId == null) {
            result.message = '영업기회를 찾을 수 없습니다.';
            return result;
        }

        List<Opportunity> opps = [
            SELECT Id, Name, AccountId, OwnerId, CurrencyIsoCode, Amount,
                   Deal_Direction__c, Primary_Product__c, Issuer_Name__c, Coupon_Rate__c, Collateral_Ratio__c,
                   Contract_Start_Date__c, RP_Maturity_Date__c,
                   RP_Yield__c, Yield_Structure__c, Yield_Basis__c, Fee_Rate__c,
                   Special_Terms__c, Early_Redemption__c
            FROM Opportunity
            WHERE Id = :opportunityId
            LIMIT 1
        ];
        if (opps.isEmpty()) {
            result.message = '영업기회를 찾을 수 없습니다.';
            return result;
        }
        Opportunity opp = opps[0];

        // 이미 이 영업기회로 만든 계약이 있으면 알려준다(막지는 않는다).
        List<Contract> existing = [
            SELECT Id, ContractNumber
            FROM Contract
            WHERE SourceOpportunityId = :opportunityId
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (!existing.isEmpty()) {
            result.existingContractId = existing[0].Id;
            result.existingContractNumber = existing[0].ContractNumber;
        }

        if (opp.AccountId == null) {
            result.message = '영업기회에 법인 고객이 연결되어 있지 않아 계약을 만들 수 없습니다.';
            return result;
        }
        if (opp.Contract_Start_Date__c == null || opp.RP_Maturity_Date__c == null) {
            result.message = '조건 확정이 완료되지 않았습니다. 계약 시작일과 만기일을 먼저 채워 주세요.';
            return result;
        }

        Map<String, Object> v = result.defaults;
        v.put('SourceOpportunityId', opportunityId);
        v.put('AccountId', opp.AccountId);
        v.put('OwnerId', opp.OwnerId);
        v.put('Status', STATUS_DRAFT);
        v.put('CurrencyIsoCode', opp.CurrencyIsoCode);
        v.put('StartDate', String.valueOf(opp.Contract_Start_Date__c));
        v.put('Maturity_Date__c', String.valueOf(opp.RP_Maturity_Date__c));
        v.put('ContractTerm', monthsBetween(opp.Contract_Start_Date__c, opp.RP_Maturity_Date__c));
        v.put('Contract_Form__c', formFor(opp.Deal_Direction__c));

        putIfNotNull(v, 'Deal_Direction__c', opp.Deal_Direction__c);
        putIfNotNull(v, 'Product__c', opp.Primary_Product__c);
        if (String.isNotBlank(opp.Issuer_Name__c)) {
            v.put('Issuer_Name__c', opp.Issuer_Name__c);
        } else {
            v.put('Issuer_Name__c', '근본증권');
        }
        putIfNotNull(v, 'Coupon_Rate__c', opp.Coupon_Rate__c);
        putIfNotNull(v, 'Collateral_Ratio__c', opp.Collateral_Ratio__c);
        putIfNotNull(v, 'Contract_Amount__c', opp.Amount);
        putIfNotNull(v, 'RP_Yield__c', opp.RP_Yield__c);
        putIfNotNull(v, 'Yield_Structure__c', opp.Yield_Structure__c);
        putIfNotNull(v, 'Yield_Basis__c', opp.Yield_Basis__c);
        putIfNotNull(v, 'Fee_Rate__c', opp.Fee_Rate__c);
        putIfNotNull(v, 'SpecialTerms', opp.Special_Terms__c);
        putIfNotNull(v, 'Early_Redemption_Terms__c', opp.Early_Redemption__c);
        // 서명 정보: 자사 서명자는 담당 RM, 고객사 서명자는 기본 담당자.
        // 서명일(CompanySignedDate/CustomerSignedDate)은 실제 서명 시점에 RM 이 직접 넣는다 —
        // 작성 시점 날짜를 미리 박으면 계약서 PDF 에 사실과 다른 서명일이 찍힌다.
        v.put('CompanySignedId', opp.OwnerId);

        Contact primary = primaryContact(opportunityId);
        if (primary != null) {
            v.put('Contact__c', primary.Id);
            v.put('CustomerSignedId', primary.Id);
            putIfNotNull(v, 'CustomerSignedTitle', primary.Title);
        }

        result.ready = true;
        result.message = '조건 값을 불러왔습니다. 내용을 확인한 뒤 저장하세요.';
        return result;
    }

    /**
     * 영업기회의 대표 연락처. 담당 Contact·고객사 서명자·서명자 직책에 함께 쓴다.
     * 기본 연락처(IsPrimary=true)를 우선 쓰되, 없으면 가장 먼저 등록된 Contact Role 을 쓴다.
     * (Lead 전환 등으로 Contact Role 이 primary 표시 없이 만들어지는 경우가 있어, primary 만
     *  고집하면 서명자가 비게 된다.) 연락처가 하나도 없으면 null.
     */
    private static Contact primaryContact(Id opportunityId) {
        List<OpportunityContactRole> roles = [
            SELECT ContactId, Contact.Id, Contact.Title
            FROM OpportunityContactRole
            WHERE OpportunityId = :opportunityId
            ORDER BY IsPrimary DESC, CreatedDate ASC
            LIMIT 1
        ];
        return roles.isEmpty() ? null : roles[0].Contact;
    }

    /**
     * 계약기간(개월). 표준 계약 만료일 = 개시일 + 계약기간(개월) - 1일 이므로,
     * 만료일이 만기일(환매일) 이상이 되는 가장 작은 개월 수를 쓴다.
     * 예: 2026-09-01 ~ 2026-11-30 → 3 (9/1 + 3개월 - 1일 = 11/30).
     * 표준 필수 필드라 최소 1 을 보장한다.
     */
    @TestVisible
    private static Integer monthsBetween(Date startDate, Date endDate) {
        Integer months = startDate.monthsBetween(endDate);
        if (months < 1) {
            months = 1;
        }
        // 만료일이 만기일에 못 미치면 한 달씩 늘린다(최대 12회 — 무한 루프 방지).
        for (Integer i = 0; i < 12 && startDate.addMonths(months).addDays(-1) < endDate; i++) {
            months++;
        }
        return months;
    }

    /** 거래방향 → 계약 양식. */
    @TestVisible
    private static String formFor(String direction) {
        if (String.isBlank(direction)) {
            return '기타';
        }
        String form = FORM_BY_DIRECTION.get(direction);
        return form == null ? '기타' : form;
    }

    private static void putIfNotNull(Map<String, Object> target, String key, Object value) {
        if (value == null) {
            return;
        }
        if (value instanceof String && String.isBlank((String) value)) {
            return;
        }
        target.put(key, value);
    }
}