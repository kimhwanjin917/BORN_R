/**
 * DartSignalService 의 Lead 매칭(Lead__c) 확장 검증.
 * corp_code(Account.Assigned_Company_Code__c 와 동일 체계)가 Lead.Assigned_Company_Code__c 와
 * 일치하는 Lead 가 있으면 적재되는 공시 시그널의 Lead__c 룩업이 채워지고, 없으면 비워지는지를
 * 기존 HttpCalloutMock 패턴으로 검증한다. (기존 테스트·TestDataFactory 는 수정하지 않는다.)
 */
@isTest
private class DartSignalLeadMatchTest {
    // 매칭 Lead 가 존재하는 corp_code
    private static final String MATCH_CODE = '00844444';
    // Account 는 있으나 매칭 Lead 가 없는 corp_code
    private static final String NOLEAD_CODE = '00855555';
    private static final String BEGIN_DATE = '20230101';
    private static final String END_DATE = '20231231';

    // 관심 공시(설비투자 1 + 차입 1)를 반환하는 정상 응답 mock.
    private static final String CAPEX_RCEPT_NO = '20230101000010';
    private static final String DEBT_RCEPT_NO = '20230201000020';

    private class SuccessMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setBody(JSON.serialize(new Map<String, Object>{
                'status' => '000',
                'message' => '정상',
                'list' => new List<Map<String, Object>>{
                    new Map<String, Object>{
                        'report_nm' => '유형자산 취득결정',
                        'rcept_no' => CAPEX_RCEPT_NO,
                        'rcept_dt' => '20230115',
                        'corp_name' => '테스트법인',
                        'flr_nm' => '테스트법인'
                    },
                    new Map<String, Object>{
                        'report_nm' => '회사채 발행결정',
                        'rcept_no' => DEBT_RCEPT_NO,
                        'rcept_dt' => '20230210',
                        'corp_name' => '테스트법인',
                        'flr_nm' => '테스트법인'
                    }
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
        }
    }

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
        DartSignalService.testCrtfcKey = 'TEST_KEY';
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        // When
        System.runAs(getDartUser()) {
            Lead matchLead = [SELECT Id FROM Lead WHERE Assigned_Company_Code__c = :MATCH_CODE LIMIT 1];

            Test.startTest();
            DartSignalService.collectSignals(MATCH_CODE, BEGIN_DATE, END_DATE);
            Test.stopTest();

            // Then: 적재된 모든 시그널의 Lead__c 가 매칭 Lead 로 연결되어야 한다
            List<ExternalSignal__c> signals = [
                SELECT Lead__c, Account__c FROM ExternalSignal__c
            ];
            Assert.areEqual(2, signals.size(), '설비투자·차입 공시 2건이 적재되어야 한다');
            for (ExternalSignal__c s : signals) {
                Assert.areEqual(matchLead.Id, s.Lead__c, 'corp_code 가 일치하는 Lead 가 연결되어야 한다');
                Assert.isNotNull(s.Account__c, 'Account 매칭은 기존대로 유지되어야 한다');
            }
        }
    }

    @isTest
    static void shouldLeaveLeadNull_WhenNoMatchingLead() {
        // Given: Account 는 있으나 같은 corp_code 의 Lead 가 없는 경우
        DartSignalService.testCrtfcKey = 'TEST_KEY';
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        // When
        System.runAs(getDartUser()) {
            Test.startTest();
            DartSignalService.collectSignals(NOLEAD_CODE, BEGIN_DATE, END_DATE);
            Test.stopTest();

            // Then: 매칭 Lead 가 없으면 적재된 시그널의 Lead__c 는 비어 있어야 한다
            List<ExternalSignal__c> signals = [
                SELECT Lead__c, Account__c FROM ExternalSignal__c
            ];
            Assert.areEqual(2, signals.size(), '설비투자·차입 공시 2건이 적재되어야 한다');
            for (ExternalSignal__c s : signals) {
                Assert.isNull(s.Lead__c, '매칭되는 Lead 가 없으면 Lead__c 는 null 이어야 한다');
                Assert.isNotNull(s.Account__c, 'Account 매칭은 기존대로 유지되어야 한다');
            }
        }
    }

    @isTest
    static void shouldPopulateLead_WhenBatchRunsSuccessfully() {
        // Given: 배치 경계 검증 — DartSignalBatch 가 담당사(Assigned_Company_Code__c 보유)를
        // 훑어 공시 시그널을 upsert 할 때, corp_code 매칭 Lead 가 Lead__c 에 연결되는지 확인한다.
        // 배치는 회사당 1 execute(콜아웃 1 + upsert 1)로 설계되어 scope size 가 1 이며,
        // 테스트 컨텍스트는 executeBatch 당 execute 1회만 허용하므로 담당사를 1건으로 좁힌다
        // (비매칭 케이스는 서비스 레벨 테스트가 커버). 비매칭 담당사는 삭제한다.
        DartSignalService.testCrtfcKey = 'TEST_KEY';
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        System.runAs(getDartUser()) {
            Lead matchLead = [SELECT Id FROM Lead WHERE Assigned_Company_Code__c = :MATCH_CODE LIMIT 1];
            delete [SELECT Id FROM Account WHERE Assigned_Company_Code__c = :NOLEAD_CODE];

            Test.startTest();
            Database.executeBatch(new DartSignalBatch(BEGIN_DATE, END_DATE), 1);
            Test.stopTest();

            // Then: 매칭 담당사의 적재 시그널이 모두 corp_code 일치 Lead 로 연결되어야 한다
            List<ExternalSignal__c> signals = [
                SELECT Lead__c FROM ExternalSignal__c
            ];
            Assert.areEqual(2, signals.size(), '설비투자·차입 공시 2건이 적재되어야 한다');
            for (ExternalSignal__c s : signals) {
                Assert.areEqual(matchLead.Id, s.Lead__c,
                    '배치 실행 시 corp_code 가 일치하는 Lead 가 연결되어야 한다');
            }
        }
    }
}