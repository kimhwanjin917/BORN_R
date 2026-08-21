/**
 * 테스트 데이터 생성 유틸리티. 테스트 클래스는 레코드 생성을 이 팩토리에 위임한다.
 */
@isTest
public class TestDataFactory {
    /**
     * DART 기업코드가 매핑된 법인 고객(Account)을 생성한다.
     *
     * @param corpCode Account.Assigned_Company_Code__c 에 넣을 DART corp_code
     * @param doInsert true 면 즉시 insert
     * @return 생성된 Account
     */
    public static Account createAccount(String corpCode, Boolean doInsert) {
        Account account = new Account(
            Name = 'Test Corp ' + corpCode,
            Assigned_Company_Code__c = corpCode,
            Business_Registration_Number__c = buildBizRegNo(corpCode),
            Industry = pickIndustryValue()
        );
        if (doInsert) {
            insert account;
        }
        return account;
    }

    // 사업자등록번호(필수, 10자리)를 corp_code 기반으로 생성한다.
    private static String buildBizRegNo(String corpCode) {
        String digits = (corpCode == null ? '' : corpCode).replaceAll('[^0-9]', '');
        return (digits + '0000000000').substring(0, 10);
    }

    // 검증 규칙이 Industry 를 필수로 요구하므로 활성 피크리스트 값 하나를 반환한다.
    private static String pickIndustryValue() {
        List<Schema.PicklistEntry> entries =
            Account.Industry.getDescribe().getPicklistValues();
        for (Schema.PicklistEntry entry : entries) {
            if (entry.isActive()) {
                return entry.getValue();
            }
        }
        return null;
    }

    /**
     * 지정한 이름으로 법인 고객(Account)을 생성한다.
     * 네이버 뉴스 수집은 기업명(Account.Name)으로 매핑하므로 이름 기반 매핑 검증에 사용한다.
     *
     * @param name Account.Name
     * @param doInsert true 면 즉시 insert
     * @return 생성된 Account
     */
    public static Account createAccountByName(String name, Boolean doInsert) {
        Account account = new Account(
            Name = name,
            Business_Registration_Number__c = buildBizRegNo(name),
            Industry = pickIndustryValue()
        );
        if (doInsert) {
            insert account;
        }
        return account;
    }

    /**
     * 기존에 적재된 것으로 간주할 공시 시그널(ExternalSignal__c)을 생성한다.
     * DartSignalService 의 중복 갱신(External_Key__c upsert)을 검증할 때 사용한다.
     *
     * @param account 연결할 법인 고객
     * @param externalKey 공시 자연키(corp_code + '_' + rcept_no)
     * @param doInsert true 면 즉시 insert
     * @return 생성된 ExternalSignal__c
     */
    public static ExternalSignal__c createExternalSignal(Account account, String externalKey, Boolean doInsert) {
        ExternalSignal__c signal = new ExternalSignal__c(
            Account__c = account == null ? null : account.Id,
            External_Key__c = externalKey,
            Signal_Type__c = '공시',
            Title__c = 'Existing 공시'
        );
        if (doInsert) {
            insert signal;
        }
        return signal;
    }

    /**
     * DART_OpenAPI_Access 권한 세트가 부여된 테스트 사용자를 생성한다.
     * Assigned_Company_Code__c / CorporateFinancialStatement__c 는 이 권한 세트로만
     * 편집 FLS 가 열리므로, 수집 로직 테스트는 이 사용자로 System.runAs 해야 한다.
     */
    public static User createDartUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String unique = String.valueOf(System.now().getTime()) + Crypto.getRandomInteger();
        User u = new User(
            ProfileId = p.Id,
            LastName = 'DART',
            Email = 'dart.tester@example.com',
            Username = 'dart.tester.' + unique + '@example.com.invalid',
            Alias = 'dart',
            TimeZoneSidKey = 'Asia/Seoul',
            LocaleSidKey = 'ko_KR',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        insert u;

        PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'DART_OpenAPI_Access' LIMIT 1];
        insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
        return u;
    }
}