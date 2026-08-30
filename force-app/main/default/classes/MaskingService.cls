/**
 * Masks personally identifiable information (PII) within free text.
 *
 * Handles four categories, applied in a deterministic order so that phone
 * numbers are removed before account numbers are evaluated (both are
 * hyphenated digit sequences and would otherwise be ambiguous):
 *   1. Korean phone numbers   -> leading group kept, remaining digits masked
 *   2. Account numbers        -> all digits masked (e.g. ***-**-******)
 *   3. Email addresses        -> first two local characters kept + ***@domain
 *   4. Contact names (Korean) -> surname (first character) kept + **
 *   5. Account names (company)-> first character kept + **
 *
 * Categories 4 and 5 are not regular-expression based: the org's Contact.Name and
 * Account.Name values are read and matched literally, so only names that actually
 * exist as records are masked.
 *
 * Callable standalone (no trigger dependency).
 */
public with sharing class MaskingService {
    @TestVisible
    private static final Integer MAX_CONTACTS = 5000;
    @TestVisible
    private static final Integer MAX_ACCOUNTS = 5000;
    // Single-character company names are too ambiguous to replace safely.
    private static final Integer MIN_COMPANY_LENGTH = 2;

    // Mobile (010-1234-5678), Seoul landline (02-123-4567), other landlines (0XX-...).
    private static final Pattern PHONE_PATTERN = Pattern.compile(
        '(01[016789]|02|0[3-9][0-9])[-\\s]?\\d{3,4}[-\\s]?\\d{4}'
    );
    // Hyphenated numeric groups (e.g. 3-2-6) and long unbroken digit runs.
    private static final Pattern ACCOUNT_HYPHEN_PATTERN = Pattern.compile('\\d{2,6}-\\d{2,6}-\\d{2,6}');
    private static final Pattern ACCOUNT_PLAIN_PATTERN = Pattern.compile('\\d{10,14}');
    private static final Pattern EMAIL_PATTERN = Pattern.compile(
        '[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}'
    );
    // A Korean personal name: 2-4 Hangul syllables.
    private static final Pattern KOREAN_NAME_PATTERN = Pattern.compile('^[\\uAC00-\\uD7A3]{2,4}$');



    /**
     * Holds the masked text and the number of individual values that were masked.
     */
    public class MaskingResult {
        public String sanitizedText;
        public Integer maskedCount;

        public MaskingResult(String sanitizedText, Integer maskedCount) {
            this.sanitizedText = sanitizedText;
            this.maskedCount = maskedCount;
        }
    }

    /**
     * Masks phone numbers, account numbers, emails, and known Contact and Account
     * names in the given text.
     *
     * @param rawText The text to sanitize. Null or blank input returns an empty result.
     * @return A MaskingResult with the sanitized text and the count of masked values.
     * @example
     * MaskingService.MaskingResult result = MaskingService.mask('연락처 010-1234-5678');
     * // result.sanitizedText => '연락처 010-****-****'
     * // result.maskedCount   => 1
     */
    public static MaskingResult mask(String rawText) {
        return mask(rawText, null, null);
    }

    /**
     * 현재 미팅의 담당자/고객사 이름을 정확히 알고 있을 때 쓰는 오버로드.
     *
     * contactName / accountName 은 문맥 추측 없이 **정확히 일치하는 문자열만**
     * 길이만큼 '*' 로 바꾼다(예: 김민준 → ***). 조직 전체 Contact/Account 를
     * 훑는 기존 규칙보다 먼저 돌기 때문에, 현재 고객은 부분 마스킹(김**)이 아니라
     * 전체 마스킹이 적용된다.
     *
     * 현재 미팅과 무관한 이름/회사/기관은 여기서 가리지 않는다.
     */
    public static MaskingResult mask(String rawText, String contactName, String accountName) {
        if (String.isBlank(rawText)) {
            return new MaskingResult(rawText == null ? '' : rawText, 0);
        }

        Integer maskedCount = 0;
        String working = rawText;

        // 1. Phone numbers first (so their digits are not re-matched as accounts).
        MaskOutcome phoneOutcome = maskPattern(working, PHONE_PATTERN, MaskType.PHONE);
        working = phoneOutcome.text;
        maskedCount += phoneOutcome.count;

        // 2. Account numbers (hyphenated groups, then long plain digit runs).
        MaskOutcome accountHyphenOutcome = maskPattern(working, ACCOUNT_HYPHEN_PATTERN, MaskType.ACCOUNT);
        working = accountHyphenOutcome.text;
        maskedCount += accountHyphenOutcome.count;

        MaskOutcome accountPlainOutcome = maskPattern(working, ACCOUNT_PLAIN_PATTERN, MaskType.ACCOUNT);
        working = accountPlainOutcome.text;
        maskedCount += accountPlainOutcome.count;

        // 3. Email addresses.
        MaskOutcome emailOutcome = maskPattern(working, EMAIL_PATTERN, MaskType.EMAIL);
        working = emailOutcome.text;
        maskedCount += emailOutcome.count;

        // 3.5 현재 미팅의 담당자/고객사 — 정확 일치만 전체 '*' 처리.
        //     레코드 기반 규칙보다 먼저 돌려서 현재 고객이 부분 마스킹되지 않게 한다.
        MaskOutcome contextOutcome = maskExactNames(
            working, new List<String>{ contactName, accountName }
        );
        working = contextOutcome.text;
        maskedCount += contextOutcome.count;

        // 4. Contact names sourced from the org.
        MaskOutcome nameOutcome = maskContactNames(working);
        working = nameOutcome.text;
        maskedCount += nameOutcome.count;

        // 5. Account (company) names sourced from the org. Runs after personal
        //    names so a company name that contains one is not partially rewritten.
        MaskOutcome companyOutcome = maskAccountNames(working);
        working = companyOutcome.text;
        maskedCount += companyOutcome.count;

        return new MaskingResult(working, maskedCount);
    }

    private enum MaskType {
        PHONE,
        ACCOUNT,
        EMAIL
    }

    private class MaskOutcome {
        String text;
        Integer count;

        MaskOutcome(String text, Integer count) {
            this.text = text;
            this.count = count;
        }
    }

    /**
     * Finds every occurrence of the given pattern and replaces it with a masked form.
     */
    private static MaskOutcome maskPattern(String text, Pattern searchPattern, MaskType maskType) {
        Matcher matcher = searchPattern.matcher(text);
        Set<String> matches = new Set<String>();
        while (matcher.find()) {
            matches.add(matcher.group());
        }

        Integer count = 0;
        String working = text;
        for (String match : matches) {
            String masked = maskValue(match, maskType);
            count += countOccurrences(working, match);
            working = working.replace(match, masked);
        }
        return new MaskOutcome(working, count);
    }

    private static String maskValue(String value, MaskType maskType) {
        switch on maskType {
            when PHONE {
                return maskPhone(value);
            }
            when EMAIL {
                return maskEmail(value);
            }
            when else {
                return maskDigits(value);
            }
        }
    }

    /**
     * Keeps the leading group (area/carrier prefix) and masks all remaining digits.
     */
    private static String maskPhone(String value) {
        Integer prefixEnd = -1;
        for (Integer i = 0; i < value.length(); i++) {
            String currentChar = value.substring(i, i + 1);
            if (currentChar == '-' || currentChar == ' ') {
                prefixEnd = i;
                break;
            }
        }
        // No separator: keep the first three digits as the prefix.
        if (prefixEnd == -1) {
            prefixEnd = Math.min(3, value.length());
        }

        String prefix = value.substring(0, prefixEnd);
        String remainder = value.substring(prefixEnd);
        return prefix + maskDigits(remainder);
    }

    /**
     * Replaces every digit with '*', leaving separators intact.
     */
    private static String maskDigits(String value) {
        return value.replaceAll('[0-9]', '*');
    }

    /**
     * Keeps the first two characters of the local part, then ***@domain.
     */
    private static String maskEmail(String value) {
        Integer atIndex = value.indexOf('@');
        if (atIndex <= 0) {
            return value;
        }
        String localPart = value.substring(0, atIndex);
        String domain = value.substring(atIndex);
        Integer keep = Math.min(2, localPart.length());
        return localPart.substring(0, keep) + '***' + domain;
    }

    /**
     * Queries Contact names and replaces any Korean name found in the text with surname + **.
     */
    private static MaskOutcome maskContactNames(String text) {
        List<Contact> contacts = [
            SELECT Name
            FROM Contact
            WHERE Name != null
            WITH USER_MODE
            LIMIT :MAX_CONTACTS
        ];

        // Longer names first so a full name is masked before a shorter overlapping name.
        Set<String> koreanNames = new Set<String>();
        for (Contact contact : contacts) {
            String name = contact.Name == null ? '' : contact.Name.trim();
            if (KOREAN_NAME_PATTERN.matcher(name).matches()) {
                koreanNames.add(name);
            }
        }

        List<String> sortedNames = new List<String>(koreanNames);
        sortByLengthDesc(sortedNames);

        Integer count = 0;
        String working = text;
        for (String name : sortedNames) {
            if (!working.contains(name)) {
                continue;
            }
            String masked = name.substring(0, 1) + '**';
            count += countOccurrences(working, name);
            working = working.replace(name, masked);
        }
        return new MaskOutcome(working, count);
    }

    /**
     * Queries Account names and replaces any that appear in the text with the
     * first character + **. Unlike phone/email masking this is data driven: only
     * companies that exist as Account records in the org are masked.
     */
    private static MaskOutcome maskAccountNames(String text) {
        List<Account> accounts = [
            SELECT Name
            FROM Account
            WHERE Name != null
            WITH USER_MODE
            LIMIT :MAX_ACCOUNTS
        ];

        Set<String> companyNames = new Set<String>();
        for (Account account : accounts) {
            String name = account.Name == null ? '' : account.Name.trim();
            if (name.length() >= MIN_COMPANY_LENGTH) {
                companyNames.add(name);
            }
        }

        // Longer names first so "보르니증권 서울지점" is masked before "보르니증권".
        List<String> sortedNames = new List<String>(companyNames);
        sortByLengthDesc(sortedNames);

        Integer count = 0;
        String working = text;
        for (String name : sortedNames) {
            if (!working.contains(name)) {
                continue;
            }
            String masked = name.substring(0, 1) + '**';
            count += countOccurrences(working, name);
            working = working.replace(name, masked);
        }
        return new MaskOutcome(working, count);
    }

    /**
     * Counts non-overlapping occurrences of a literal substring.
     */
    private static Integer countOccurrences(String text, String target) {
        if (String.isEmpty(target)) {
            return 0;
        }
        return (text.length() - text.replace(target, '').length()) / target.length();
    }

    /**
     * Sorts strings by descending length (simple insertion sort; name lists are small).
     */
    private static void sortByLengthDesc(List<String> values) {
        for (Integer i = 1; i < values.size(); i++) {
            String current = values[i];
            Integer j = i - 1;
            while (j >= 0 && values[j].length() < current.length()) {
                values[j + 1] = values[j];
                j--;
            }
            values[j + 1] = current;
        }
    }


    /**
     * 주어진 이름들과 정확히 일치하는 부분만 길이만큼 '*' 로 바꾼다.
     * 문맥 추측이나 패턴 추론은 하지 않는다. 카운트는 기존 규칙과 동일하게
     * occurrence 단위로 센다.
     */
    private static MaskOutcome maskExactNames(String text, List<String> names) {
        if (String.isBlank(text) || names == null) {
            return new MaskOutcome(text, 0);
        }

        Set<String> targets = new Set<String>();
        for (String name : names) {
            if (String.isNotBlank(name)) {
                targets.add(name.trim());
            }
        }
        if (targets.isEmpty()) {
            return new MaskOutcome(text, 0);
        }

        // 긴 이름부터 처리해 짧은 이름이 긴 이름을 부분적으로 깨뜨리지 않게 한다.
        List<String> sorted = new List<String>(targets);
        sortByLengthDesc(sorted);

        Integer count = 0;
        String working = text;
        for (String name : sorted) {
            if (!working.contains(name)) {
                continue;
            }
            count += countOccurrences(working, name);
            working = working.replace(name, '*'.repeat(name.length()));
        }
        return new MaskOutcome(working, count);
    }
}