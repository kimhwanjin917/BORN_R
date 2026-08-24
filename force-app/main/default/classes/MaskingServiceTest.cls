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
}