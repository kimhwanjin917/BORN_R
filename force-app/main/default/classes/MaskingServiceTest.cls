/**
 * Tests for MaskingService.
 *
 * Test data is created inline in @TestSetup (team rule: TestDataFactory is a
 * frozen shared file and must not be created or modified here). Korean Contact
 * names are stored entirely in LastName so Contact.Name is deterministic
 * regardless of org locale.
 */
@isTest
private class MaskingServiceTest {
    @TestSetup
    static void setupTestData() {
        // Email is FLS-restricted (Confidential) and Department is required by a
        // validation rule; insert in system mode so test data setup is not blocked
        // by field-level security or the running user's permissions.
        List<Contact> contacts = new List<Contact>{
            new Contact(LastName = '김철수', name_new__c = '김철수', Email = 'c1@test.example', Department = 'Sales'),
            new Contact(LastName = '이영희', name_new__c = '이영희', Email = 'c2@test.example', Department = 'Sales'),
            new Contact(LastName = '박지성민', name_new__c = '박지성민', Email = 'c3@test.example', Department = 'Sales'),
            new Contact(FirstName = 'John', LastName = 'Smith', name_new__c = 'Smith', Email = 'c4@test.example', Department = 'Sales')
        };
        Database.insert(contacts, AccessLevel.SYSTEM_MODE);

        // Company names for category 5. Industry is required by the Required_PL
        // validation rule and Business_Registration_Number__c is a required
        // Text(10). None of these names appear in the other tests' inputs, so the
        // existing expectations are unaffected.
        List<Account> accounts = new List<Account>{
            new Account(Name = '보르니증권', Industry = 'Banking',
                Business_Registration_Number__c = '2000000001'),
            new Account(Name = '보르니증권 서울지점', Industry = 'Banking',
                Business_Registration_Number__c = '2000000002')
        };
        Database.insert(accounts, AccessLevel.SYSTEM_MODE);
    }

    @isTest
    static void shouldMaskMobilePhone_WhenHyphenated() {
        Test.startTest();
        MaskingService.MaskingResult result = MaskingService.mask('연락처는 010-1234-5678 입니다');
        Test.stopTest();

        Assert.areEqual('연락처는 010-****-**** 입니다', result.sanitizedText, 'Mobile number should be masked after the carrier prefix');
        Assert.areEqual(1, result.maskedCount, 'Exactly one value should be masked');
    }

    @isTest
    static void shouldMaskSeoulLandline_WhenHyphenated() {
        Test.startTest();
        MaskingService.MaskingResult result = MaskingService.mask('사무실 02-123-4567');
        Test.stopTest();

        Assert.areEqual('사무실 02-***-****', result.sanitizedText, 'Seoul landline should keep the 02 prefix');
        Assert.areEqual(1, result.maskedCount, 'Exactly one value should be masked');
    }

    @isTest
    static void shouldMaskPlainPhone_WhenNoSeparators() {
        Test.startTest();
        MaskingService.MaskingResult result = MaskingService.mask('01012345678');
        Test.stopTest();

        Assert.areEqual('010********', result.sanitizedText, 'Plain mobile number keeps first three digits');
        Assert.areEqual(1, result.maskedCount, 'Exactly one value should be masked');
    }

    @isTest
    static void shouldMaskEmail_WhenPresent() {
        Test.startTest();
        MaskingService.MaskingResult result = MaskingService.mask('메일 hong.gildong@example.com 로 연락');
        Test.stopTest();

        Assert.areEqual('메일 ho***@example.com 로 연락', result.sanitizedText, 'Email keeps first two local characters');
        Assert.areEqual(1, result.maskedCount, 'Exactly one value should be masked');
    }

    @isTest
    static void shouldMaskShortEmailLocalPart_WhenSingleChar() {
        Test.startTest();
        MaskingService.MaskingResult result = MaskingService.mask('a@example.com');
        Test.stopTest();

        Assert.areEqual('a***@example.com', result.sanitizedText, 'Single-character local part is kept as-is before ***');
        Assert.areEqual(1, result.maskedCount, 'Exactly one value should be masked');
    }

    @isTest
    static void shouldMaskHyphenatedAccount_WhenThreeGroups() {
        Test.startTest();
        MaskingService.MaskingResult result = MaskingService.mask('계좌 123-45-678901 입금');
        Test.stopTest();

        Assert.areEqual('계좌 ***-**-****** 입금', result.sanitizedText, 'Account digits should all be masked, hyphens kept');
        Assert.areEqual(1, result.maskedCount, 'Exactly one value should be masked');
    }

    @isTest
    static void shouldMaskPlainAccount_WhenLongDigitRun() {
        Test.startTest();
        MaskingService.MaskingResult result = MaskingService.mask('계좌번호 1234567890123');
        Test.stopTest();

        Assert.areEqual('계좌번호 *************', result.sanitizedText, 'Long unbroken digit run is masked as an account');
        Assert.areEqual(1, result.maskedCount, 'Exactly one value should be masked');
    }

    @isTest
    static void shouldMaskContactName_WhenPresentInText() {
        Test.startTest();
        MaskingService.MaskingResult result = MaskingService.mask('고객 김철수 님 안녕하세요');
        Test.stopTest();

        Assert.areEqual('고객 김** 님 안녕하세요', result.sanitizedText, 'Korean name should be masked to surname + **');
        Assert.areEqual(1, result.maskedCount, 'Exactly one value should be masked');
    }

    @isTest
    static void shouldMaskFourCharName_WhenPresentInText() {
        Test.startTest();
        MaskingService.MaskingResult result = MaskingService.mask('담당자 박지성민 확인');
        Test.stopTest();

        Assert.areEqual('담당자 박** 확인', result.sanitizedText, 'Four-character Korean name keeps only the first character');
        Assert.areEqual(1, result.maskedCount, 'Exactly one value should be masked');
    }

    @isTest
    static void shouldNotMaskEnglishName_WhenPresentInText() {
        Test.startTest();
        MaskingService.MaskingResult result = MaskingService.mask('contact John Smith today');
        Test.stopTest();

        Assert.areEqual('contact John Smith today', result.sanitizedText, 'Non-Korean names must not be masked');
        Assert.areEqual(0, result.maskedCount, 'No values should be masked');
    }

    @isTest
    static void shouldMaskAllTypes_WhenCombinedText() {
        String input = '고객 김철수, 전화 010-1234-5678, 계좌 123-45-678901, 메일 test@abc.com';

        Test.startTest();
        MaskingService.MaskingResult result = MaskingService.mask(input);
        Test.stopTest();

        String expected = '고객 김**, 전화 010-****-****, 계좌 ***-**-******, 메일 te***@abc.com';
        Assert.areEqual(expected, result.sanitizedText, 'All four PII types should be masked in one pass');
        Assert.areEqual(4, result.maskedCount, 'Four distinct values should be masked');
    }

    @isTest
    static void shouldCountRepeatedValues_WhenSameValueTwice() {
        Test.startTest();
        MaskingService.MaskingResult result = MaskingService.mask('010-1234-5678 그리고 010-1234-5678');
        Test.stopTest();

        Assert.areEqual('010-****-**** 그리고 010-****-****', result.sanitizedText, 'Both occurrences should be masked');
        Assert.areEqual(2, result.maskedCount, 'Repeated value counts each occurrence');
    }

    @isTest
    static void shouldMaskCompanyName_WhenPresentInText() {
        Test.startTest();
        MaskingService.MaskingResult result = MaskingService.mask('보르니증권 과 계약 예정');
        Test.stopTest();

        Assert.areEqual('보** 과 계약 예정', result.sanitizedText, 'Company name keeps only the first character');
        Assert.areEqual(1, result.maskedCount, 'Exactly one value should be masked');
    }

    @isTest
    static void shouldMaskLongerCompanyNameFirst_WhenNamesOverlap() {
        Test.startTest();
        MaskingService.MaskingResult result = MaskingService.mask('보르니증권 서울지점 방문');
        Test.stopTest();

        Assert.areEqual('보** 방문', result.sanitizedText, 'The longest matching company name wins');
        Assert.areEqual(1, result.maskedCount, 'The branch name is masked as one value, not two');
    }

    @isTest
    static void shouldMaskCompanyAndPersonalPii_WhenCombined() {
        Test.startTest();
        MaskingService.MaskingResult result = MaskingService.mask(
            '보르니증권 김철수 부장 010-1234-5678 c1@test.example');
        Test.stopTest();

        Assert.areEqual('보** 김** 부장 010-****-**** c1***@test.example', result.sanitizedText,
            'Company, name, phone and email are masked in one pass; the title is left as plain text');
        Assert.areEqual(4, result.maskedCount, 'Four distinct values should be masked');
    }

    @isTest
    static void shouldNotMaskUnknownCompany_WhenNotAnAccountInTheOrg() {
        Test.startTest();
        MaskingService.MaskingResult result = MaskingService.mask('경쟁사 없는회사이름 언급');
        Test.stopTest();

        Assert.areEqual('경쟁사 없는회사이름 언급', result.sanitizedText,
            'Only company names that exist as Account records are masked');
        Assert.areEqual(0, result.maskedCount, 'Nothing should be masked');
    }

    @isTest
    static void shouldReturnEmpty_WhenNullInput() {
        Test.startTest();
        MaskingService.MaskingResult result = MaskingService.mask(null);
        Test.stopTest();

        Assert.areEqual('', result.sanitizedText, 'Null input returns empty text');
        Assert.areEqual(0, result.maskedCount, 'Null input masks nothing');
    }

    @isTest
    static void shouldReturnBlank_WhenBlankInput() {
        Test.startTest();
        MaskingService.MaskingResult result = MaskingService.mask('   ');
        Test.stopTest();

        Assert.areEqual('   ', result.sanitizedText, 'Blank input is returned unchanged');
        Assert.areEqual(0, result.maskedCount, 'Blank input masks nothing');
    }

    @isTest
    static void shouldReturnUnchanged_WhenNoPii() {
        Test.startTest();
        MaskingService.MaskingResult result = MaskingService.mask('오늘 날씨가 좋습니다');
        Test.stopTest();

        Assert.areEqual('오늘 날씨가 좋습니다', result.sanitizedText, 'Text without PII is unchanged');
        Assert.areEqual(0, result.maskedCount, 'Nothing should be masked');
    }

    // ─── 현재 미팅 Context 기반 정확 일치 마스킹 ──────────────────────────
    // 문맥 추측은 하지 않는다. 현재 미팅의 Contact.Name / Account.Name 과
    // 정확히 일치하는 문자열만 길이만큼 '*' 로 가린다.

    @isTest
    static void shouldFullyMaskCurrentContactAndAccount_WhenContextProvided() {
        String memo =
            '김민준 부장 / 한빛산업 재무팀\n' +
            '국민은행 123456-01-987654 계좌 사용\n' +
            '연락처 010-4827-1936';

        Test.startTest();
        MaskingService.MaskingResult result =
            MaskingService.mask(memo, '김민준', '한빛산업');
        Test.stopTest();

        System.assert(!result.sanitizedText.contains('김민준'),
            '담당자명이 남았습니다: ' + result.sanitizedText);
        System.assert(!result.sanitizedText.contains('한빛산업'),
            '고객사명이 남았습니다: ' + result.sanitizedText);

        // 부분 마스킹(김**)이 아니라 전체 '*' 여야 한다.
        System.assert(result.sanitizedText.contains('*** 부장'),
            '담당자명이 전체 마스킹되지 않았습니다: ' + result.sanitizedText);
        System.assert(result.sanitizedText.contains('**** 재무팀'),
            '고객사명이 전체 마스킹되지 않았습니다: ' + result.sanitizedText);

        // 기존 PII 규칙 유지
        System.assert(!result.sanitizedText.contains('123456-01-987654'),
            '계좌번호가 남았습니다: ' + result.sanitizedText);
        System.assert(!result.sanitizedText.contains('010-4827-1936'),
            '전화번호가 남았습니다: ' + result.sanitizedText);
    }

    @isTest
    static void shouldNotMaskUnrelatedCompany_WhenNotTheCurrentAccount() {
        Test.startTest();
        MaskingService.MaskingResult result = MaskingService.mask(
            '국민은행 상품도 비교함', '김민준', '한빛산업'
        );
        Test.stopTest();

        System.assert(result.sanitizedText.contains('국민은행'),
            '현재 고객사가 아닌 기관명이 마스킹되었습니다: ' + result.sanitizedText);
        System.assertEquals(0, result.maskedCount,
            '무관한 기관명이 카운트되었습니다: ' + result.sanitizedText);
    }

    @isTest
    static void shouldNotGuessNameFromTitle_WhenNotTheCurrentContact() {
        Test.startTest();
        MaskingService.MaskingResult result = MaskingService.mask(
            '박지훈 부장과 협의함', '김민준', '한빛산업'
        );
        Test.stopTest();

        System.assert(result.sanitizedText.contains('박지훈'),
            '직함만 보고 이름을 추측해 마스킹했습니다: ' + result.sanitizedText);
        System.assertEquals(0, result.maskedCount,
            '휴리스틱 마스킹이 남아 있습니다: ' + result.sanitizedText);
    }

    @isTest
    static void shouldMaskEveryOccurrence_WhenContextNameRepeats() {
        Test.startTest();
        MaskingService.MaskingResult result = MaskingService.mask(
            '김민준 부장과 이야기했고 김민준 부장이 재검토 요청', '김민준', null
        );
        Test.stopTest();

        System.assert(!result.sanitizedText.contains('김민준'),
            '반복 등장한 이름이 남았습니다: ' + result.sanitizedText);
        System.assertEquals(2, result.maskedCount,
            'occurrence 카운트가 맞지 않습니다: ' + result.maskedCount);
    }

    @isTest
    static void shouldKeepExistingBehaviour_WhenNoContextProvided() {
        Test.startTest();
        MaskingService.MaskingResult result =
            MaskingService.mask('연락처 010-4827-1936');
        Test.stopTest();

        System.assertEquals('연락처 010-****-****', result.sanitizedText,
            '기존 단일 인자 API 동작이 바뀌었습니다: ' + result.sanitizedText);
        System.assertEquals(1, result.maskedCount);
    }
}