/**
 * DartFinancialService 의 Lead 매칭(Lead__c) 확장 검증.
 * corp_code(Account.Assigned_Company_Code__c 와 동일 체계)가 Lead.Assigned_Company_Code__c 와
 * 일치하는 Lead 가 있으면 Lead__c 룩업이 채워지고, 없으면 비워지는지를
 * 기존 HttpCalloutMock 패턴으로 검증한다. (기존 테스트·TestDataFactory 는 수정하지 않는다.)
 */
@isTest
private class DartFinancialLeadMatchTest {
    // 매칭 Lead 가 존재하는 corp_code
    private static final String MATCH_CODE = '00811111';
    // Account 는 있으나 매칭 Lead 가 없는 corp_code
    private static final String NOLEAD_CODE = '00822222';
    // 매칭되면 안 되는 다른 corp_code 의 Lead(정확 일치만 연결되는지 검증용)
    private static final String DECOY_CODE = '00833333';
    private static final String BUSINESS_YEAR = '2023';
    private static final String REPORT_CODE = '11011';

    private class SuccessMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setBody(JSON.serialize(new Map<String, Object>{
                'status' => '000',
                'message' => '정상',
                'list' => new List<Map<String, Object>>{
                    new Map<String, Object>{ 'account_nm' => '현금및현금성자산', 'thstrm_amount' => '1,000,000' },
                    new Map<String, Object>{ 'account_nm' => '자산총계', 'thstrm_amount' => '5,000,000' }
                }
            }));
            return response;
        }
    }

    @TestSetup
    static void setup() {
        // User(setup 객체) 삽입과 Account/Lead(비 setup 객체) 삽입 사이의 MIXED_DML 은
        // runAs 블록으로 컨텍스트를 분리해 피한다. Account 는 dartUser 가 FLS 를 가지므로
        // 기존 패턴대로 생성하고, Lead 는 이 org 에서 관리자조차 커스텀 필드 편집 FLS 가 없어
        // 테스트 데이터 준비 목적상 SYSTEM_MODE 로 삽입해 FLS 를 우회한다.
        User dartUser = TestDataFactory.createDartUser();
        System.runAs(dartUser) {
            // 매칭 시나리오: Account + 같은 corp_code 의 Lead
            TestDataFactory.createAccount(MATCH_CODE, true);
            Database.insert(buildLead(MATCH_CODE, 'MatchCo'), AccessLevel.SYSTEM_MODE);

            // 불일치 시나리오: Account 는 있으나 Lead 없음
            TestDataFactory.createAccount(NOLEAD_CODE, true);

            // decoy: 무관한 corp_code 의 Lead 는 연결되면 안 된다
            Database.insert(buildLead(DECOY_CODE, 'DecoyCo'), AccessLevel.SYSTEM_MODE);
        }
    }

    // 사업자등록번호(Account/Lead 각각 unique)를 corp_code 로부터 결정론적으로 생성한다.
    private static Lead buildLead(String corpCode, String company) {
        return new Lead(
            LastName = 'Lead ' + corpCode,
            Company = company,
            Assigned_Company_Code__c = corpCode,
            Business_Registration_Number__c = ('9' + corpCode + '000').substring(0, 12)
        );
    }

    private static User getDartUser() {
        return [
            SELECT Id FROM User
            WHERE LastName = 'DART' AND Alias = 'dart' AND Username LIKE 'dart.tester.%'
            LIMIT 1
        ];
    }

    @isTest
    static void shouldPopulateLead_WhenCorpCodeMatchesLead() {
        // Given
        DartFinancialService.testCrtfcKey = 'TEST_KEY';
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        // When
        System.runAs(getDartUser()) {
            Lead matchLead = [SELECT Id FROM Lead WHERE Assigned_Company_Code__c = :MATCH_CODE LIMIT 1];

            Test.startTest();
            DartFinancialService.collectFinancials(MATCH_CODE, BUSINESS_YEAR, REPORT_CODE);
            Test.stopTest();

            // Then: corp_code 가 일치하는 Lead 가 Lead__c 에 연결되어야 한다
            CorporateFinancialStatement__c saved = [
                SELECT Lead__c, Account__c
                FROM CorporateFinancialStatement__c
                WHERE External_Key__c = :(MATCH_CODE + '_' + BUSINESS_YEAR + '_' + REPORT_CODE)
            ];
            Assert.areEqual(matchLead.Id, saved.Lead__c, 'corp_code 가 일치하는 Lead 가 연결되어야 한다');
            Assert.isNotNull(saved.Account__c, 'Account 매칭은 기존대로 유지되어야 한다');
        }
    }

    @isTest
    static void shouldLeaveLeadNull_WhenNoMatchingLead() {
        // Given: Account 는 있으나 같은 corp_code 의 Lead 가 없는 경우
        DartFinancialService.testCrtfcKey = 'TEST_KEY';
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        // When
        System.runAs(getDartUser()) {
            Test.startTest();
            DartFinancialService.collectFinancials(NOLEAD_CODE, BUSINESS_YEAR, REPORT_CODE);
            Test.stopTest();

            // Then: 매칭 Lead 가 없으면 Lead__c 는 비어 있어야 한다(decoy Lead 와도 연결되지 않음)
            CorporateFinancialStatement__c saved = [
                SELECT Lead__c, Account__c
                FROM CorporateFinancialStatement__c
                WHERE External_Key__c = :(NOLEAD_CODE + '_' + BUSINESS_YEAR + '_' + REPORT_CODE)
            ];
            Assert.isNull(saved.Lead__c, '매칭되는 Lead 가 없으면 Lead__c 는 null 이어야 한다');
            Assert.isNotNull(saved.Account__c, 'Account 매칭은 기존대로 유지되어야 한다');
        }
    }

    @isTest
    static void shouldPopulateLead_WhenBatchRunsSuccessfully() {
        // Given: 배치 경계 검증 — DartCollectionBatch 가 담당사(Assigned_Company_Code__c 보유)를
        // 훑어 재무제표를 upsert 할 때, corp_code 매칭 Lead 가 Lead__c 에 연결되는지 확인한다.
        // 배치는 회사당 1 execute(콜아웃 1 + upsert 1)로 설계되어 scope size 가 1 이며,
        // 테스트 컨텍스트는 executeBatch 당 execute 1회만 허용하므로 담당사를 1건으로 좁힌다
        // (비매칭 케이스는 서비스 레벨 테스트가 커버). 비매칭 담당사는 삭제한다.
        DartFinancialService.testCrtfcKey = 'TEST_KEY';
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        System.runAs(getDartUser()) {
            Lead matchLead = [SELECT Id FROM Lead WHERE Assigned_Company_Code__c = :MATCH_CODE LIMIT 1];
            delete [SELECT Id FROM Account WHERE Assigned_Company_Code__c = :NOLEAD_CODE];

            Test.startTest();
            Database.executeBatch(new DartCollectionBatch(BUSINESS_YEAR, REPORT_CODE), 1);
            Test.stopTest();

            // Then: 매칭 담당사 레코드에 corp_code 가 일치하는 Lead 가 연결되어야 한다
            CorporateFinancialStatement__c matched = [
                SELECT Lead__c FROM CorporateFinancialStatement__c
                WHERE External_Key__c = :(MATCH_CODE + '_' + BUSINESS_YEAR + '_' + REPORT_CODE)
            ];
            Assert.areEqual(matchLead.Id, matched.Lead__c,
                '배치 실행 시 corp_code 가 일치하는 Lead 가 연결되어야 한다');
        }
    }
}
