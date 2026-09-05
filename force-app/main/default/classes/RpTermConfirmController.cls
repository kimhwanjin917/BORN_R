/**
 * Opportunity 모달 Quick Action "조건 확정하기" 의 Apex.
 *
 * 기존 자산을 그대로 쓴다:
 *   - PDF 렌더링 : Visualforce 페이지 + PageReference.getContentAsPDF() (ContractDocumentService 와 같은 방식)
 *   - 파일 연결  : ContentVersion + ContentDocumentLink (ContractDocumentService 와 같은 구조)
 *   - 상품 목록  : 활성 Product2 전체(IsActive = true). 상품군·이름 하드코딩 필터는 두지 않는다 —
 *                 어떤 상품으로도 조건을 확정할 수 있어야 한다는 요구(2026-08-30).
 *
 * 순서가 중요하다: getContentAsPDF() 는 콜아웃 취급이라 같은 트랜잭션의 어떤 DML 보다 먼저 불러야 한다
 * (ContractDocumentService 의 제약과 동일). 저장 DML 이 실패하면 트랜잭션이 통째로 롤백되므로
 * 렌더링을 먼저 하더라도 "저장 실패 시 PDF 가 남지 않는다" 는 요구는 그대로 지켜진다.
 */
public with sharing class RpTermConfirmController {

    /** 확정 조건서 제목 규칙. 재확정 시 같은 ContentDocument 에 새 버전을 쌓기 위한 식별자이기도 하다. */
    @TestVisible private static final String TITLE_SUFFIX = '_RP_확정조건';

    // 세후 환매예정금액 계산 시 이자에 적용하는 원천징수율. LeadProposalController.WITHHOLDING_RATE(0.14)와 동일 기준.
    @TestVisible private static final Decimal WITHHOLDING_RATE = 0.14;
    private static final Integer DAYS_IN_YEAR = 365;

    // ─── DTO ──────────────────────────────────────────────────────────

    public class ProductOption {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String family;
        @AuraEnabled public Decimal defaultFeeRate;
    }

    public class InitState {
        // 읽기전용 자동 표시값
        @AuraEnabled public String opportunityName;   // 거래ID = Opportunity.Name (별도 식별자 필드 만들지 않음)
        @AuraEnabled public String accountName;
        @AuraEnabled public String ownerName;
        @AuraEnabled public String slackReplyLink;     // 최종 협의 링크
        @AuraEnabled public String productTeamConfirmer; // 상품팀 확정자

        // 선택지
        @AuraEnabled public List<ProductOption> products = new List<ProductOption>();
        @AuraEnabled public List<String> yieldStructures = new List<String>();
        @AuraEnabled public List<String> dealDirections = new List<String>();
        @AuraEnabled public List<String> yieldBases = new List<String>();
        @AuraEnabled public List<String> feeMethods = new List<String>();
        @AuraEnabled public List<String> feeBearers = new List<String>();
        @AuraEnabled public List<String> earlyRedemptions = new List<String>();
        @AuraEnabled public List<String> customerFinalAgreements = new List<String>();

        // 이미 저장된 값(미팅 저장/재확정 시 모달에 채워 넣는다)
        @AuraEnabled public Id productId;
        @AuraEnabled public String dealDirection;
        @AuraEnabled public Date startDate;
        @AuraEnabled public Date endDate;
        @AuraEnabled public Decimal amount;
        @AuraEnabled public Decimal rpYield;
        @AuraEnabled public String yieldStructure;
        @AuraEnabled public String yieldBasis;
        @AuraEnabled public String feeMethod;
        @AuraEnabled public Decimal feeRate;
        @AuraEnabled public Decimal feeAmount;
        @AuraEnabled public String feeBearer;
        @AuraEnabled public String earlyRedemption;
        @AuraEnabled public String specialTerms;
        @AuraEnabled public String customerFinalAgreement;
        @AuraEnabled public Decimal couponRate;
        @AuraEnabled public Decimal collateralRatio;
        @AuraEnabled public Boolean hasConfirmedPdf = false;
    }

    /** 확정 입력값. 항목이 많아 위치 인자 대신 래퍼로 받는다. */
    public class TermInput {
        @AuraEnabled public Id productId;
        @AuraEnabled public String dealDirection;
        @AuraEnabled public Date startDate;
        @AuraEnabled public Date endDate;
        @AuraEnabled public Decimal amount;
        @AuraEnabled public Decimal rpYield;
        @AuraEnabled public String yieldStructure;
        @AuraEnabled public String yieldBasis;
        @AuraEnabled public String feeMethod;
        @AuraEnabled public Decimal feeRate;
        @AuraEnabled public Decimal feeAmount;
        @AuraEnabled public String feeBearer;
        @AuraEnabled public String earlyRedemption;
        @AuraEnabled public String specialTerms;
        @AuraEnabled public String customerFinalAgreement;
        @AuraEnabled public Decimal couponRate;
        @AuraEnabled public Decimal collateralRatio;
    }

    public class ConfirmResult {
        @AuraEnabled public Id contentDocumentId;
        @AuraEnabled public Id contentVersionId;
        @AuraEnabled public String fileName;
        @AuraEnabled public Boolean newVersion = false;
        @AuraEnabled public String message;
    }

    private static final String FEE_METHOD_RATE = '정률';
    private static final String FEE_METHOD_AMOUNT = '정액';

    // 약정수익률 상한(연 %). DealTermCollabController.MAX_AGREED_YIELD 와 동일 기준.
    // 이 값을 넘는 확정 수익률은 승인 전까지 적용값(RP_Yield__c)이 아니라 대기 필드(Pending_Yield__c)에만 저장한다 —
    // 상품팀 [승인] 시 DealApprovalHandler 가 RP_Yield__c 로 옮기고 대기 필드를 비운다.
    @TestVisible private static final Decimal MAX_AGREED_YIELD = 7;

    // ─── 조회 ─────────────────────────────────────────────────────────

    @AuraEnabled(cacheable=false)
    public static InitState getInit(Id opportunityId) {
        Opportunity opp = loadOpportunity(opportunityId);

        InitState s = new InitState();
        s.opportunityName = opp.Name;
        s.accountName = opp.Account == null ? null : opp.Account.Name;
        s.ownerName = opp.Owner == null ? null : opp.Owner.Name;
        s.slackReplyLink = opp.Slack_Reply_Link__c;
        s.productTeamConfirmer = resolveProductTeamConfirmer(opp);

        s.productId = opp.Primary_Product__c;
        // 신규 조건 필드는 아직 아무도 채운 적이 없어(전부 null) 열자마자 모든 항목이 필수 오류로 뜬다.
        // Opportunity 에 저장된 값이 있으면 그 값을, 없으면 일반적인 RP 기본값을 모달 초기값으로 내려준다
        // (저장은 하지 않는다 — 사용자가 확정할 때 confirmTerms 가 최종값을 기록한다).
        s.dealDirection = blankToDefault(opp.Deal_Direction__c, 'RP 매수');
        // 시작일이 아직 확정되지 않았으면(미팅 저장은 종료일만 채운다) 모달 초기값으로만 오늘을 내려준다.
        s.startDate = opp.Contract_Start_Date__c == null ? Date.today() : opp.Contract_Start_Date__c;
        s.endDate = opp.RP_Maturity_Date__c;
        s.amount = opp.Amount;
        // 상한 초과로 승인 대기 중인 값이 있으면 모달엔 그 값을 되보여준다(재확정 시 이어서 편집).
        s.rpYield = opp.Pending_Yield__c != null ? opp.Pending_Yield__c : opp.RP_Yield__c;
        s.yieldStructure = blankToDefault(opp.Yield_Structure__c, '고정금리');
        s.yieldBasis = blankToDefault(opp.Yield_Basis__c, '세전');
        s.feeMethod = blankToDefault(opp.Fee_Method__c, '정률');
        s.feeRate = opp.Fee_Rate__c;
        s.feeAmount = opp.Fee_Amount__c;
        s.feeBearer = blankToDefault(opp.Fee_Bearer__c, '고객');
        s.earlyRedemption = blankToDefault(opp.Early_Redemption__c, '불가');
        s.specialTerms = opp.Special_Terms__c;
        s.customerFinalAgreement = blankToDefault(opp.Customer_Final_Agreement__c, '미완료');
        s.couponRate = opp.Coupon_Rate__c;
        s.collateralRatio = opp.Collateral_Ratio__c;

        for (Product2 p : [
            SELECT Id, Name, Family, Default_Fee_Rate__c
            FROM Product2
            WHERE IsActive = true
            WITH USER_MODE
            ORDER BY Name
        ]) {
            ProductOption o = new ProductOption();
            o.id = p.Id;
            o.name = p.Name;
            o.family = p.Family;
            o.defaultFeeRate = p.Default_Fee_Rate__c;
            s.products.add(o);
        }

        s.yieldStructures = activeValues(Opportunity.Yield_Structure__c);
        s.dealDirections = activeValues(Opportunity.Deal_Direction__c);
        s.yieldBases = activeValues(Opportunity.Yield_Basis__c);
        s.feeMethods = activeValues(Opportunity.Fee_Method__c);
        s.feeBearers = activeValues(Opportunity.Fee_Bearer__c);
        s.earlyRedemptions = activeValues(Opportunity.Early_Redemption__c);
        s.customerFinalAgreements = activeValues(Opportunity.Customer_Final_Agreement__c);

        s.hasConfirmedPdf = findLatestTermPdfId(opportunityId) != null;
        return s;
    }

    // ─── 확정 ─────────────────────────────────────────────────────────

    @AuraEnabled
    public static ConfirmResult confirmTerms(Id opportunityId, String inputJson) {
        // 입력은 JSON 문자열로 받는다. Apex 정의 타입 파라미터를 LWC 에서 직접 넘기면
        // 프레임워크 역직렬화가 조용히 전 필드 null 인스턴스를 만드는 경우가 있어(2026-08-31 실측),
        // 문자열로 받아 JSON.deserialize 로 확실히 복원한다.
        if (String.isBlank(inputJson)) {
            throw new AuraHandledException('입력값이 없습니다.');
        }
        TermInput input;
        try {
            input = (TermInput) JSON.deserialize(inputJson, TermInput.class);
        } catch (Exception e) {
            throw new AuraHandledException('입력값을 해석하지 못했습니다.');
        }
        if (input == null) {
            throw new AuraHandledException('입력값이 없습니다.');
        }
        List<String> errors = validate(input);
        if (!errors.isEmpty()) {
            throw new AuraHandledException(String.join(errors, '\n'));
        }

        Opportunity opp = loadOpportunity(opportunityId);
        List<Product2> products = [
            SELECT Id, Name, Family FROM Product2 WHERE Id = :input.productId WITH USER_MODE LIMIT 1
        ];
        if (products.isEmpty()) {
            throw new AuraHandledException('선택한 상품을 찾을 수 없습니다.');
        }

        // 수수료 방식에 따라 저장 대상을 정리한다 — 쓰지 않는 값은 비워 조건서가 모호해지지 않게 한다.
        Boolean isRate = FEE_METHOD_RATE.equals(input.feeMethod);
        Decimal saveFeeRate = isRate ? input.feeRate : null;
        Decimal saveFeeAmount = isRate ? null : input.feeAmount;

        Date confirmedOn = Date.today();
        String fileName = buildFileName(opp.Name, confirmedOn);

        // 1) PDF 먼저 렌더(콜아웃 취급). 아래 DML 이 실패하면 트랜잭션이 통째로 롤백되어 파일도 남지 않는다.
        Blob pdf = renderPdf(buildParams(opp, products[0], input, saveFeeRate, saveFeeAmount, confirmedOn));

        // 2) 조건 저장
        opp.Primary_Product__c = input.productId;
        opp.Deal_Direction__c = input.dealDirection;
        opp.Contract_Start_Date__c = input.startDate;
        opp.RP_Maturity_Date__c = input.endDate;
        opp.Amount = input.amount;
        // 상한(연 7%) 초과분은 승인 전까지 RP_Yield__c 에 반영하지 않고 대기 필드에만 둔다(승인 시 DealApprovalHandler 가 이관).
        // 상한 이하이면 즉시 적용하고, 이전에 대기 중이던 초과값이 있으면 비운다.
        if (input.rpYield != null && input.rpYield > MAX_AGREED_YIELD) {
            opp.Pending_Yield__c = input.rpYield;
        } else {
            opp.RP_Yield__c = input.rpYield;
            opp.Pending_Yield__c = null;
        }
        opp.Yield_Structure__c = input.yieldStructure;
        opp.Yield_Basis__c = input.yieldBasis;
        opp.Fee_Method__c = input.feeMethod;
        opp.Fee_Rate__c = saveFeeRate;
        opp.Fee_Amount__c = saveFeeAmount;
        opp.Fee_Bearer__c = input.feeBearer;
        opp.Early_Redemption__c = input.earlyRedemption;
        opp.Special_Terms__c = input.specialTerms;
        opp.Customer_Final_Agreement__c = input.customerFinalAgreement;
        opp.Coupon_Rate__c = input.couponRate;
        opp.Collateral_Ratio__c = input.collateralRatio;
        update as user opp;

        // 3) 파일 저장 — 이미 확정 조건서가 있으면 같은 문서에 새 버전을 쌓는다(히스토리 보존)
        ConfirmResult r = new ConfirmResult();
        r.fileName = fileName;
        Id existingDocId = findLatestTermPdfId(opp.Id);

        ContentVersion cv = new ContentVersion(
            Title = fileName.removeEnd('.pdf'),
            PathOnClient = fileName,
            VersionData = pdf
        );
        if (existingDocId != null) {
            cv.ContentDocumentId = existingDocId;
            r.newVersion = true;
        } else {
            cv.FirstPublishLocationId = opp.Id;
        }
        insert as user cv;

        r.contentVersionId = cv.Id;
        r.contentDocumentId = [
            SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id WITH USER_MODE LIMIT 1
        ].ContentDocumentId;
        r.message = r.newVersion
            ? '조건을 확정하고 확정 조건서를 새 버전으로 저장했습니다.'
            : '조건을 확정하고 확정 조건서를 생성했습니다.';
        return r;
    }

    // ─── 환매예정금액 계산 (모달·PDF 공통) ────────────────────────────
    //
    // 기존 RP 수익 계산과 동일한 일할 공식: 원금 × 약정수익률 × 경과일수 / 365
    // (LeadProposalController.buildSimulation / meetingNotePad._annualizedAmount 와 같은 식).
    // 세후 기준이면 이자에 원천징수(0.14)를 반영한다. 환매예정금액 = 원금 + (세후) 이자.
    @TestVisible
    private static Decimal computeRedemptionAmount(
        Decimal amount, Decimal rpYield, Date startDate, Date endDate, String yieldBasis
    ) {
        if (amount == null || rpYield == null || startDate == null || endDate == null) {
            return null;
        }
        Integer days = startDate.daysBetween(endDate);
        if (days < 0) {
            return null;
        }
        Decimal grossInterest = amount * (rpYield / 100) * days / DAYS_IN_YEAR;
        Decimal interest = '세후'.equals(yieldBasis)
            ? grossInterest * (1 - WITHHOLDING_RATE)
            : grossInterest;
        return (amount + interest).setScale(0, System.RoundingMode.HALF_UP);
    }

    // ─── 재사용 wrapper (조건 확정 모달·Contract Summary·향후 PDF 공통) ──
    //
    // 계산의 단일 source. 산식은 위 computeRedemptionAmount(private helper)를 그대로 재사용하며
    // 새로운 산식을 만들지 않는다. 개별 항목(이자·세금·순이자)도 같은 일할 공식에서 파생한다:
    //   총이자      = 원금 × (약정수익률/100) × 일수 / 365   (환매예정금액 산식과 동일)
    //   원천징수세  = 세후 기준일 때만 총이자 × 0.14, 세전이면 0
    //   순이자      = 총이자 − 원천징수세
    //   환매예정금액 = computeRedemptionAmount(...) — 위 helper 를 그대로 호출
    public class RpCalculationResult {
        @AuraEnabled public Integer days;
        @AuraEnabled public Decimal grossInterest;    // 세전 총이자
        @AuraEnabled public Decimal withholdingTax;   // 원천징수세 (세전이면 0)
        @AuraEnabled public Decimal netInterest;      // 수익금 = 총이자 − 원천징수세
        @AuraEnabled public Decimal redemptionAmount; // 환매예정금액 (원금 + 순이자)
    }

    /**
     * RP 확정조건의 파생 계산값을 한 번에 돌려준다. 입력이 부족하거나 기간이 음수면 null 을 반환한다.
     * 환매예정금액은 기존 private helper(computeRedemptionAmount)를 그대로 호출해 산식을 단일화한다.
     */
    public static RpCalculationResult calculateRpTerms(
        Decimal amount, Decimal rpYield, Date startDate, Date endDate, String yieldBasis
    ) {
        if (amount == null || rpYield == null || startDate == null || endDate == null) {
            return null;
        }
        Integer days = startDate.daysBetween(endDate);
        if (days < 0) {
            return null;
        }
        Decimal grossInterest = (amount * (rpYield / 100) * days / DAYS_IN_YEAR)
            .setScale(0, System.RoundingMode.HALF_UP);
        Decimal withholdingTax = '세후'.equals(yieldBasis)
            ? (grossInterest * WITHHOLDING_RATE).setScale(0, System.RoundingMode.HALF_UP)
            : 0;
        RpCalculationResult res = new RpCalculationResult();
        res.days = days;
        res.grossInterest = grossInterest;
        res.withholdingTax = withholdingTax;
        res.netInterest = grossInterest - withholdingTax;
        res.redemptionAmount = computeRedemptionAmount(amount, rpYield, startDate, endDate, yieldBasis);
        return res;
    }

    // ─── 공유 헬퍼 ────────────────────────────────────────────────────

    /**
     * 이 Opportunity 에 연결된 최신 RP 확정 조건서의 ContentDocumentId. 없으면 null.
     * DealTermCollabController(상품팀 전달) 가 Slack 첨부 대상을 찾을 때도 이 메서드를 쓴다.
     */
    public static Id findLatestTermPdfId(Id opportunityId) {
        Set<Id> docIds = new Set<Id>();
        for (ContentDocumentLink l : [
            SELECT ContentDocumentId FROM ContentDocumentLink
            WHERE LinkedEntityId = :opportunityId
            WITH USER_MODE
        ]) {
            docIds.add(l.ContentDocumentId);
        }
        if (docIds.isEmpty()) {
            return null;
        }
        String pattern = '%' + TITLE_SUFFIX + '%';
        List<ContentVersion> versions = [
            SELECT ContentDocumentId FROM ContentVersion
            WHERE ContentDocumentId IN :docIds AND IsLatest = true AND Title LIKE :pattern
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        return versions.isEmpty() ? null : versions[0].ContentDocumentId;
    }

    // ─── 매니저 결재 "(심사 완료)" 조건서 재렌더 (2026-09-02 재구성) ─────
    //
    // DealApprovalPoller 가 매니저 결재 완료 시 호출한다. 이미 확정 조건서가 있는 딜이면
    // 저장된 조건값으로 같은 VF 페이지를 titleTag='(심사 완료)' 로 다시 렌더해 Blob 으로 돌려준다.
    // 저장(ContentVersion)은 하지 않는다 — 폴러가 Slack 에 직접 업로드만 한다. 조건서가 없으면 null.

    public class ReviewedPdf {
        public Blob body;
        public String fileName;
        public ReviewedPdf(Blob body, String fileName) { this.body = body; this.fileName = fileName; }
    }

    public static ReviewedPdf buildReviewedTermPdf(Id opportunityId) {
        if (opportunityId == null || findLatestTermPdfId(opportunityId) == null) {
            return null;
        }
        List<Opportunity> opps = [
            SELECT Id, Name, Amount, Fee_Rate__c, Fee_Amount__c, Fee_Method__c, Fee_Bearer__c,
                   RP_Yield__c, Pending_Yield__c, RP_Maturity_Date__c, Contract_Start_Date__c,
                   Deal_Direction__c, Yield_Structure__c, Yield_Basis__c, Early_Redemption__c,
                   Special_Terms__c, Customer_Final_Agreement__c, Coupon_Rate__c, Collateral_Ratio__c,
                   Slack_Reply_Link__c, Product_Team_Reply_By__c,
                   Primary_Product__r.Name, Primary_Product__r.Family,
                   Primary_Product__r.Product_Team_Rep__r.Name,
                   Account.Name, Owner.Name
            FROM Opportunity WHERE Id = :opportunityId LIMIT 1
        ];
        if (opps.isEmpty()) {
            return null;
        }
        Opportunity opp = opps[0];
        // 승인 대기값이 있으면 그 값이 최종 약정수익률(승격 예정) — getInit 과 같은 우선순위.
        Decimal effYield = opp.Pending_Yield__c != null ? opp.Pending_Yield__c : opp.RP_Yield__c;
        Boolean isAmount = FEE_METHOD_AMOUNT.equals(opp.Fee_Method__c);
        Date confirmedOn = Date.today();

        Map<String, String> params = new Map<String, String>{
            'opportunityName'   => nz(opp.Name),
            'accountName'       => nz(opp.Account == null ? null : opp.Account.Name),
            'ownerName'         => nz(opp.Owner == null ? null : opp.Owner.Name),
            'productName'       => nz(opp.Primary_Product__r == null ? null : opp.Primary_Product__r.Name),
            'productFamily'     => nz(opp.Primary_Product__r == null ? null : opp.Primary_Product__r.Family),
            'dealDirection'     => nz(opp.Deal_Direction__c),
            'amountText'        => money(opp.Amount),
            'startText'         => opp.Contract_Start_Date__c == null ? '' : opp.Contract_Start_Date__c.format(),
            'endText'           => opp.RP_Maturity_Date__c == null ? '' : opp.RP_Maturity_Date__c.format(),
            'yieldText'         => pct(effYield),
            'yieldStructure'    => nz(opp.Yield_Structure__c),
            'yieldBasis'        => nz(opp.Yield_Basis__c),
            'redemptionText'    => money(computeRedemptionAmount(opp.Amount, effYield, opp.Contract_Start_Date__c, opp.RP_Maturity_Date__c, opp.Yield_Basis__c)),
            'feeMethod'         => nz(opp.Fee_Method__c),
            'feeRateText'       => pct(isAmount ? null : opp.Fee_Rate__c),
            'feeAmountText'     => money(isAmount ? opp.Fee_Amount__c : null),
            'feeBearer'         => nz(opp.Fee_Bearer__c),
            'earlyRedemption'   => nz(opp.Early_Redemption__c),
            'specialTerms'      => nz(opp.Special_Terms__c),
            'customerFinalAgreement' => nz(opp.Customer_Final_Agreement__c),
            'slackReplyLink'    => nz(opp.Slack_Reply_Link__c),
            'productTeamConfirmer' => nz(resolveProductTeamConfirmer(opp)),
            'confirmedText'     => confirmedOn.format(),
            'couponRateText'    => pct(opp.Coupon_Rate__c),
            'collateralRatioText' => pct(opp.Collateral_Ratio__c),
            'titleTag'          => '(심사 완료)'
        };
        return new ReviewedPdf(renderPdf(params), buildFileName(opp.Name, confirmedOn));
    }

    // ─── 내부 ─────────────────────────────────────────────────────────

    private static Opportunity loadOpportunity(Id opportunityId) {
        List<Opportunity> opps = [
            SELECT Id, Name, Amount, Primary_Product__c, Fee_Rate__c, Fee_Amount__c, RP_Yield__c, Pending_Yield__c,
                   RP_Maturity_Date__c, Contract_Start_Date__c, Yield_Structure__c,
                   Deal_Direction__c, Yield_Basis__c, Fee_Method__c, Fee_Bearer__c,
                   Early_Redemption__c, Special_Terms__c, Customer_Final_Agreement__c,
                   Coupon_Rate__c, Collateral_Ratio__c,
                   Slack_Reply_Link__c, Product_Team_Reply_By__c,
                   Primary_Product__r.Product_Team_Rep__r.Name,
                   Account.Name, Owner.Name
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

    /** 상품팀 확정자: 실제 회신자(Product_Team_Reply_By__c) 우선, 없으면 상품 담당 rep. */
    private static String resolveProductTeamConfirmer(Opportunity opp) {
        if (String.isNotBlank(opp.Product_Team_Reply_By__c)) {
            return opp.Product_Team_Reply_By__c;
        }
        return opp.Primary_Product__r == null || opp.Primary_Product__r.Product_Team_Rep__r == null
            ? null
            : opp.Primary_Product__r.Product_Team_Rep__r.Name;
    }

    private static List<String> activeValues(Schema.SObjectField field) {
        List<String> values = new List<String>();
        for (Schema.PicklistEntry e : field.getDescribe().getPicklistValues()) {
            if (e.isActive()) {
                values.add(e.getValue());
            }
        }
        return values;
    }

    @TestVisible
    private static List<String> validate(TermInput f) {
        List<String> errors = new List<String>();
        if (f.productId == null)                        { errors.add('상품을 선택하세요.'); }
        if (String.isBlank(f.dealDirection))            { errors.add('거래방향을 선택하세요.'); }
        if (f.startDate == null)                        { errors.add('최초 매매일을 입력하세요.'); }
        if (f.endDate == null)                          { errors.add('환매일을 입력하세요.'); }
        if (f.amount == null)                           { errors.add('거래금액을 입력하세요.'); }
        if (f.rpYield == null)                          { errors.add('약정수익률을 입력하세요.'); }
        if (String.isBlank(f.yieldStructure))           { errors.add('수익률 구조를 선택하세요.'); }
        if (String.isBlank(f.yieldBasis))               { errors.add('수익률 기준을 선택하세요.'); }
        if (String.isBlank(f.feeMethod))                { errors.add('수수료 방식을 선택하세요.'); }
        if (String.isBlank(f.feeBearer))                { errors.add('수수료 부담 주체를 선택하세요.'); }
        if (String.isBlank(f.earlyRedemption))          { errors.add('중도환매 여부를 선택하세요.'); }
        if (String.isBlank(f.customerFinalAgreement))   { errors.add('고객 최종합의 상태를 선택하세요.'); }

        // 수수료 방식별 필수값: 정률→수수료율, 정액→수수료 금액.
        if (FEE_METHOD_RATE.equals(f.feeMethod)) {
            if (f.feeRate == null) { errors.add('정률 방식은 확정 수수료율을 입력하세요.'); }
        } else if (FEE_METHOD_AMOUNT.equals(f.feeMethod)) {
            if (f.feeAmount == null) { errors.add('정액 방식은 확정 수수료 금액을 입력하세요.'); }
        }

        if (f.startDate != null && f.endDate != null && f.endDate < f.startDate) {
            errors.add('환매일은 최초 매매일보다 빠를 수 없습니다.');
        }
        if (f.amount != null && f.amount <= 0) {
            errors.add('거래금액은 0보다 커야 합니다.');
        }
        if (f.feeAmount != null && f.feeAmount < 0) {
            errors.add('수수료 금액은 0보다 작을 수 없습니다.');
        }
        // 필드 정의상 RP_Yield__c 는 Percent(3,2), Fee_Rate__c 는 Percent(1,4) — 자릿수를 넘기면 DML 이 거절한다.
        if (f.rpYield != null && (f.rpYield < 0 || f.rpYield > 100)) {
            errors.add('약정수익률은 0 ~ 100 % 사이여야 합니다.');
        }
        if (f.feeRate != null && (f.feeRate < 0 || f.feeRate >= 10)) {
            errors.add('확정 수수료율은 0 이상 10 % 미만이어야 합니다.');
        }
        return errors;
    }

    @TestVisible
    private static String buildFileName(String opportunityName, Date confirmedOn) {
        String stamp = Datetime.newInstance(confirmedOn, Time.newInstance(0, 0, 0, 0)).format('yyyyMMdd');
        String safeName = opportunityName == null ? '' : opportunityName.replaceAll('[^\\p{L}\\p{N} _.\\-]', '_');
        return safeName + TITLE_SUFFIX + '_' + stamp + '.pdf';
    }

    @TestVisible
    private static Map<String, String> buildParams(
        Opportunity opp, Product2 product, TermInput input,
        Decimal saveFeeRate, Decimal saveFeeAmount, Date confirmedOn
    ) {
        Decimal redemption = computeRedemptionAmount(
            input.amount, input.rpYield, input.startDate, input.endDate, input.yieldBasis
        );
        return new Map<String, String>{
            'opportunityName'   => nz(opp.Name),
            'accountName'       => nz(opp.Account == null ? null : opp.Account.Name),
            'ownerName'         => nz(opp.Owner == null ? null : opp.Owner.Name),
            'productName'       => nz(product == null ? null : product.Name),
            'productFamily'     => nz(product == null ? null : product.Family),
            'dealDirection'     => nz(input.dealDirection),
            'amountText'        => money(input.amount),
            'startText'         => input.startDate == null ? '' : input.startDate.format(),
            'endText'           => input.endDate == null ? '' : input.endDate.format(),
            'yieldText'         => pct(input.rpYield),
            'yieldStructure'    => nz(input.yieldStructure),
            'yieldBasis'        => nz(input.yieldBasis),
            'redemptionText'    => money(redemption),
            'feeMethod'         => nz(input.feeMethod),
            'feeRateText'       => pct(saveFeeRate),
            'feeAmountText'     => money(saveFeeAmount),
            'feeBearer'         => nz(input.feeBearer),
            'earlyRedemption'   => nz(input.earlyRedemption),
            'specialTerms'      => nz(input.specialTerms),
            'customerFinalAgreement' => nz(input.customerFinalAgreement),
            'slackReplyLink'    => nz(opp.Slack_Reply_Link__c),
            'productTeamConfirmer' => nz(resolveProductTeamConfirmer(opp)),
            'confirmedText'     => confirmedOn == null ? '' : confirmedOn.format(),
            'couponRateText'    => pct(input.couponRate),
            'collateralRatioText' => pct(input.collateralRatio)
        };
    }

    @TestVisible
    private static Blob renderPdf(Map<String, String> params) {
        PageReference page = Page.RpTermConfirmPdf;
        page.getParameters().putAll(params);
        return Test.isRunningTest()
            ? Blob.valueOf('PDF-TEST ' + params.get('opportunityName'))
            : page.getContentAsPDF();
    }

    /** Opportunity 값이 있으면 그대로, 비어 있으면 모달 초기값(default)을 돌려준다. */
    private static String blankToDefault(String stored, String defaultValue) {
        return String.isBlank(stored) ? defaultValue : stored;
    }

    private static String nz(String s) { return s == null ? '' : s; }
    private static String money(Decimal d) { return d == null ? '' : d.setScale(0).format() + ' 원'; }
    private static String pct(Decimal d) { return d == null ? '' : d.setScale(4).stripTrailingZeros().toPlainString() + ' %'; }
}