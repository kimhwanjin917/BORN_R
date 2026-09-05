/**
 * Contract 레코드의 RP 확정조건 요약 조회용 컨트롤러 (LWC: contractRpSummary).
 *
 * 조회 전용이다 — 이 클래스는 Contract 를 수정하지 않는다. 편집 Form 이 아니라 확정조건 요약 화면이다.
 *
 * 계산(수익금·세금·환매예정금액)은 새로 만들지 않고 RpTermConfirmController.calculateRpTerms 를 재사용한다
 * — 조건 확정 모달·향후 PDF 와 같은 단일 계산 source. 계산 기준(세전/세후)은 Contract 에 스냅샷된
 * Yield_Basis__c 를 쓴다. Opportunity 를 실시간 조회하지 않는다 — 계약 후 Opportunity 가 바뀌어도
 * 계약 당시 계산이 그대로 재현되어야 하기 때문이다.
 *
 * FLS 존중: 신규 커스텀 필드는 프로필/권한셋 FLS 가 아직 org UI 에서 부여되기 전이라 실행 사용자가
 * 못 읽을 수 있다. USER_MODE 로 접근 불가 필드까지 SELECT 하면 쿼리 자체가 터져 요약 화면 전체가
 * 안 보인다. 그래서 접근 가능한 필드만 동적으로 골라 USER_MODE 로 조회한다 — 접근 가능한 값은
 * 보이고, 접근 불가 필드(특히 민감정보 Settlement_Account__c)는 조회하지 않고 null 로 남긴다.
 * SYSTEM_MODE·without sharing 으로 우회하지 않는다.
 */
public with sharing class ContractRpSummaryController {

    public class Summary {
        // 기본 정보
        @AuraEnabled public String dealId;        // 거래 ID = SourceOpportunity.Name
        @AuraEnabled public String accountName;
        @AuraEnabled public String rmName;         // 담당 RM = Owner.Name
        @AuraEnabled public String contactName;    // 담당 Contact
        @AuraEnabled public String productName;

        // RP 조건 (Contract 스냅샷)
        @AuraEnabled public String dealDirection;
        @AuraEnabled public Date startDate;        // 최초 매매일
        @AuraEnabled public Date maturityDate;     // 환매일
        @AuraEnabled public Decimal amount;        // 거래금액
        @AuraEnabled public Decimal rpYield;       // 약정수익률
        @AuraEnabled public String yieldStructure;
        @AuraEnabled public String yieldBasis;     // 수익률 기준(세전/세후)
        @AuraEnabled public Decimal feeRate;
        @AuraEnabled public Decimal feeAmount;
        @AuraEnabled public Decimal collateralRatio;
        @AuraEnabled public String specialTerms;

        // 자동 계산 (calculateRpTerms 재사용)
        @AuraEnabled public Integer days;
        @AuraEnabled public Decimal netInterest;      // 수익금
        @AuraEnabled public Decimal withholdingTax;   // 세금
        @AuraEnabled public Decimal redemptionAmount; // 환매예정금액
        @AuraEnabled public Boolean hasCalculation = false;

        // 체결정보
        @AuraEnabled public String earlyRedemptionTerms;
        @AuraEnabled public String settlementAccount;
        @AuraEnabled public Boolean settlementAccountAccessible = false; // 접근 권한 여부
        @AuraEnabled public String status;
    }

    @AuraEnabled(cacheable=true)
    public static Summary getSummary(Id contractId) {
        if (contractId == null) {
            throw new AuraHandledException('계약 Id 가 필요합니다.');
        }

        Map<String, Schema.SObjectField> fields = Schema.SObjectType.Contract.fields.getMap();

        // 접근 가능한 필드만 SELECT 절에 넣는다 — 접근 불가 필드는 쿼리에서 제외하고 null 로 남긴다.
        List<String> selects = new List<String>{
            'Id', 'Status', 'StartDate', 'SpecialTerms',
            'AccountId', 'Account.Name', 'OwnerId', 'Owner.Name',
            'SourceOpportunityId', 'SourceOpportunity.Name'
        };
        addIfAccessible(selects, fields, 'Maturity_Date__c', new List<String>{ 'Maturity_Date__c' });
        addIfAccessible(selects, fields, 'Contract_Amount__c', new List<String>{ 'Contract_Amount__c' });
        addIfAccessible(selects, fields, 'RP_Yield__c', new List<String>{ 'RP_Yield__c' });
        addIfAccessible(selects, fields, 'Fee_Rate__c', new List<String>{ 'Fee_Rate__c' });
        addIfAccessible(selects, fields, 'Fee_Amount__c', new List<String>{ 'Fee_Amount__c' });
        addIfAccessible(selects, fields, 'Yield_Structure__c', new List<String>{ 'Yield_Structure__c' });
        addIfAccessible(selects, fields, 'Yield_Basis__c', new List<String>{ 'Yield_Basis__c' });
        addIfAccessible(selects, fields, 'Deal_Direction__c', new List<String>{ 'Deal_Direction__c' });
        addIfAccessible(selects, fields, 'Collateral_Ratio__c', new List<String>{ 'Collateral_Ratio__c' });
        addIfAccessible(selects, fields, 'Early_Redemption_Terms__c', new List<String>{ 'Early_Redemption_Terms__c' });
        // 관계 필드는 룩업 필드 자체가 접근 가능할 때만 자식 필드까지 SELECT 한다.
        addIfAccessible(selects, fields, 'Product__c', new List<String>{ 'Product__c', 'Product__r.Name' });
        addIfAccessible(selects, fields, 'Contact__c', new List<String>{ 'Contact__c', 'Contact__r.Name' });
        // 민감정보 — 접근 가능한 사용자에게만 SELECT 한다.
        Boolean settlementAccessible = isAccessible(fields, 'Settlement_Account__c');
        if (settlementAccessible) {
            selects.add('Settlement_Account__c');
        }

        String soql = 'SELECT ' + String.join(selects, ', ')
            + ' FROM Contract WHERE Id = :contractId LIMIT 1';
        List<Contract> rows = Database.query(soql, AccessLevel.USER_MODE);
        if (rows.isEmpty()) {
            throw new AuraHandledException('계약을 찾을 수 없거나 조회 권한이 없습니다.');
        }
        Contract c = rows[0];

        Summary s = new Summary();
        s.dealId = c.SourceOpportunity == null ? null : c.SourceOpportunity.Name;
        s.accountName = c.Account == null ? null : c.Account.Name;
        s.rmName = c.Owner == null ? null : c.Owner.Name;
        s.status = c.Status;
        s.startDate = c.StartDate;
        s.specialTerms = c.SpecialTerms;

        s.maturityDate      = readDate(c, fields, 'Maturity_Date__c');
        s.amount            = readDecimal(c, fields, 'Contract_Amount__c');
        s.rpYield           = readDecimal(c, fields, 'RP_Yield__c');
        s.feeRate           = readDecimal(c, fields, 'Fee_Rate__c');
        s.feeAmount         = readDecimal(c, fields, 'Fee_Amount__c');
        s.collateralRatio   = readDecimal(c, fields, 'Collateral_Ratio__c');
        s.yieldStructure    = readString(c, fields, 'Yield_Structure__c');
        s.yieldBasis        = readString(c, fields, 'Yield_Basis__c');
        s.dealDirection     = readString(c, fields, 'Deal_Direction__c');
        s.earlyRedemptionTerms = readString(c, fields, 'Early_Redemption_Terms__c');

        if (isAccessible(fields, 'Product__c') && c.Product__c != null) {
            s.productName = c.Product__r == null ? null : c.Product__r.Name;
        }
        if (isAccessible(fields, 'Contact__c') && c.Contact__c != null) {
            s.contactName = c.Contact__r == null ? null : c.Contact__r.Name;
        }

        s.settlementAccountAccessible = settlementAccessible;
        if (settlementAccessible) {
            s.settlementAccount = (String) c.get('Settlement_Account__c');
        }

        // 자동 계산 — Contract 에 스냅샷된 값만으로 계산한다 (Opportunity 실시간 참조 없음).
        RpTermConfirmController.RpCalculationResult calc =
            RpTermConfirmController.calculateRpTerms(s.amount, s.rpYield, s.startDate, s.maturityDate, s.yieldBasis);
        if (calc != null) {
            s.days = calc.days;
            s.netInterest = calc.netInterest;
            s.withholdingTax = calc.withholdingTax;
            s.redemptionAmount = calc.redemptionAmount;
            s.hasCalculation = true;
        }
        return s;
    }

    // ─── FLS 헬퍼 ─────────────────────────────────────────────────────

    private static Boolean isAccessible(Map<String, Schema.SObjectField> fields, String apiName) {
        Schema.SObjectField f = fields.get(apiName.toLowerCase());
        return f != null && f.getDescribe().isAccessible();
    }

    private static void addIfAccessible(
        List<String> selects, Map<String, Schema.SObjectField> fields, String gateField, List<String> toAdd
    ) {
        if (isAccessible(fields, gateField)) {
            selects.addAll(toAdd);
        }
    }

    private static Decimal readDecimal(Contract c, Map<String, Schema.SObjectField> fields, String apiName) {
        return isAccessible(fields, apiName) ? (Decimal) c.get(apiName) : null;
    }

    private static Date readDate(Contract c, Map<String, Schema.SObjectField> fields, String apiName) {
        return isAccessible(fields, apiName) ? (Date) c.get(apiName) : null;
    }

    private static String readString(Contract c, Map<String, Schema.SObjectField> fields, String apiName) {
        return isAccessible(fields, apiName) ? (String) c.get(apiName) : null;
    }
}