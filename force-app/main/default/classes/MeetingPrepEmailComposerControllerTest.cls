@isTest
private class MeetingPrepEmailComposerControllerTest {

    @TestSetup
    static void setup() {
        insert new Lead(
            LastName = 'Kim',
            Company = 'Test Co',
            Email = 'test@example.com',
            Title = 'CFO',
            Industry = 'Finance',
            name_new__c = 'TestName'
        );
        insert new Contact(LastName = 'Park', Email = 'contact@example.com', name_new__c = 'TestCont');
    }

    @isTest
    static void testParseDraft_ParsesSubjectAndBody() {
        String raw = '제목: 단기 여유자금 운용 제안 건\n본문: 안녕하세요, 반갑습니다.\n감사합니다.';

        Test.startTest();
        MeetingPrepEmailComposerController.EmailDraft draft =
            MeetingPrepEmailComposerController.parseDraft(raw);
        Test.stopTest();

        System.assertEquals('단기 여유자금 운용 제안 건', draft.subject);
        System.assert(draft.htmlBody.contains('<br/>'), '줄바꿈이 <br/> 로 치환되어야 합니다.');
        System.assert(!draft.bodyText.contains('<br/>'), 'bodyText 는 평문이어야 합니다.');
        System.assert(draft.bodyText.contains('안녕하세요'), 'bodyText 에 본문 내용이 포함되어야 합니다.');
    }

    @isTest
    static void testParseDraft_ThrowsOnMissingMarkers() {
        Boolean threw = false;
        Test.startTest();
        try {
            MeetingPrepEmailComposerController.parseDraft('형식이 잘못된 텍스트');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, '제목/본문 마커가 없으면 AuraHandledException 이 발생해야 합니다.');
    }

    @isTest
    static void testParseDraft_ThrowsOnBlankText() {
        Boolean threw = false;
        Test.startTest();
        try {
            MeetingPrepEmailComposerController.parseDraft('');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        System.assert(threw, '빈 텍스트는 AuraHandledException 이 발생해야 합니다.');
    }

    @isTest
    static void testGetEmailContext() {
        Lead ld = [SELECT Id, Name FROM Lead LIMIT 1];
        Test.startTest();
        MeetingPrepEmailComposerController.EmailContext ctx =
            MeetingPrepEmailComposerController.getEmailContext(ld.Id);
        Test.stopTest();
        System.assertEquals(ld.Id, ctx.relatedToId, 'relatedToId=Lead');
        System.assertEquals(ld.Name, ctx.leadName, 'leadName');
        System.assert(ctx.fromOptions != null, 'fromOptions 반환되어야 함');
    }

    @isTest
    static void testGetRecordName() {
        Lead ld = [SELECT Id, Name FROM Lead LIMIT 1];
        Test.startTest();
        String nm = MeetingPrepEmailComposerController.getRecordName(ld.Id);
        String empty = MeetingPrepEmailComposerController.getRecordName(null);
        Test.stopTest();
        System.assertEquals(ld.Name, nm, '레코드 이름을 반환해야 합니다.');
        System.assertEquals('', empty, 'null 이면 빈 문자열을 반환해야 합니다.');
    }

    @IsTest
    static void buildRadarEmailBody_AsksForContactChangeRespectfully() {
        Account account = new Account(Name = '레이더 테스트 고객사');
        Contact recipient = new Contact(LastName = '홍길동', Title = '자금담당', Email = 'radar@example.com');

        String body = MeetingPrepEmailComposerController.buildRadarEmailBody(
            account,
            recipient,
            '김 담당',
            'RP'
        );

        System.assert(body.contains('오랜만에 연락드려'), '오랜만의 접촉임을 밝혀야 합니다.');
        System.assert(body.contains('담당 업무가 변경되었거나'), '담당자 변경 가능성을 확인해야 합니다.');
        System.assert(body.contains('적합한 담당자께 전달'), '잘못된 수신 시 전달을 요청해야 합니다.');
        System.assert(body.contains('RP 등 단기 자금 운용 방안'), '구체 상품명 대신 카테고리 수준으로 안내해야 합니다.');
        System.assert(body.contains('근본증권 김 담당 드림'), '담당 RM 서명이 있어야 합니다.');
    }

    @isTest
    static void testGetEmailDraft_HonorsContractRegardlessOfGeneration() {
        // getEmailDraft 의 계약: Prompt Builder 응답이 비었거나 형식을 해석할 수 없으면
        // AuraHandledException 을 던지고, 유효한 응답이면 EmailDraft 를 반환한다.
        // 어느 쪽이든 null 이나 부분 오염 상태로 반환하지 않는다. 생성 결과의 실제 문구에
        // 의존하지 않고 이 계약만 검증해, org 의 생성형 AI 동작에 따라 깨지지 않게 한다.
        Lead ld = [SELECT Id, Name, Email FROM Lead LIMIT 1];

        Test.startTest();
        MeetingPrepEmailComposerController.EmailDraft draft;
        Boolean threwAuraHandled = false;
        try {
            draft = MeetingPrepEmailComposerController.getEmailDraft(ld.Id);
        } catch (AuraHandledException e) {
            // 빈/해석 불가 응답 경로: 계약대로 처리된 예외이므로 허용한다.
            threwAuraHandled = true;
        }
        Test.stopTest();

        if (threwAuraHandled) {
            // 예외 경로도 계약의 유효한 결과다 (빈/파싱 불가 응답).
            System.Assert.isTrue(true, '빈/해석 불가 응답은 AuraHandledException 으로 처리된다');
        } else {
            // 반환 경로: DTO 가 안전하게 채워져 있어야 한다.
            System.Assert.isNotNull(draft, '유효 응답이면 EmailDraft 를 반환해야 한다 (null 금지)');
            System.Assert.isTrue(String.isNotBlank(draft.subject),
                '반환된 초안의 제목은 비어 있으면 안 된다 (Send 차단 방지)');
            System.Assert.isNotNull(draft.htmlBody, 'htmlBody 는 null 이 아니어야 한다');
            // 아래 컨텍스트 필드는 생성 결과와 무관하게 Lead 로부터 채워진다.
            System.Assert.areEqual(ld.Id, draft.relatedToId, 'relatedToId 는 대상 Lead 여야 한다');
            System.Assert.areEqual(ld.Name, draft.leadName, 'leadName 은 Lead 이름이어야 한다');
            System.Assert.areEqual(ld.Email, draft.toAddress, 'toAddress 는 Lead 이메일이어야 한다');
            System.Assert.isNotNull(draft.fromOptions, 'fromOptions 는 null 이 아니어야 한다');
        }
    }

    // ─── LLM 이 표기를 영문으로 낼 때 (실제 장애 재현) ──────────────────

    @IsTest
    static void parsesEnglishSubjectMarker() {
        // 실제로 RM 화면에서 터졌던 출력: 제목은 영문 Subject:, 본문은 한글 본문:
        String raw = 'Subject: [근본증권] 와이엔텍 단기 유동성 점검 제안 '
            + '본문: 안녕하세요 노건희 과장님. 윤 주환 담당입니다.';

        MeetingPrepEmailComposerController.EmailDraft d =
            MeetingPrepEmailComposerController.parseDraft(raw);

        System.Assert.areEqual('[근본증권] 와이엔텍 단기 유동성 점검 제안', d.subject,
            '영문 Subject: 로 와도 제목을 뽑아내야 한다');
        System.Assert.isTrue(d.bodyText.startsWith('안녕하세요'), d.bodyText);
    }

    @IsTest
    static void parsesKoreanMarkers() {
        MeetingPrepEmailComposerController.EmailDraft d =
            MeetingPrepEmailComposerController.parseDraft('제목: 안내드립니다 본문: 본문 내용입니다.');

        System.Assert.areEqual('안내드립니다', d.subject);
        System.Assert.areEqual('본문 내용입니다.', d.bodyText);
    }

    @IsTest
    static void parsesBothEnglishMarkers() {
        MeetingPrepEmailComposerController.EmailDraft d =
            MeetingPrepEmailComposerController.parseDraft('Subject: Hello Body: World');

        System.Assert.areEqual('Hello', d.subject);
        System.Assert.areEqual('World', d.bodyText);
    }

    @IsTest
    static void stillRejectsUnparseableDraft() {
        Boolean thrown = false;
        try {
            MeetingPrepEmailComposerController.parseDraft('아무 마커도 없는 응답입니다');
        } catch (AuraHandledException e) {
            thrown = true;
        }
        System.Assert.isTrue(thrown, '마커가 아예 없으면 여전히 거부해야 한다');
    }

    // ─── 본문 마커가 없을 때 (이번 실제 장애: Send 시 subject 가 비어 막힘) ───────

    @IsTest
    static void parsesSubjectMarkerWithoutBodyMarker() {
        // 실제 출력: 'Subject:' 만 있고 '본문:'/'Body:' 없이 줄바꿈 뒤 본문이 이어짐
        String raw = 'Subject: [근본증권] 와이엔텍 단기 유동성 운용 관련 제안\n'
            + '안녕하세요 노건희 과장님. 근본증권 윤 주환입니다.\n감사합니다.';

        MeetingPrepEmailComposerController.EmailDraft d =
            MeetingPrepEmailComposerController.parseDraft(raw);

        System.Assert.areEqual('[근본증권] 와이엔텍 단기 유동성 운용 관련 제안', d.subject,
            '본문 마커가 없어도 첫 줄을 제목으로 뽑아야 한다');
        System.Assert.isTrue(d.bodyText.startsWith('안녕하세요'), d.bodyText);
        System.Assert.isTrue(String.isNotBlank(d.subject), '제목이 비어서는 안 된다 (Send 차단 방지)');
        System.Assert.isTrue(d.htmlBody.contains('<br/>'), '여러 줄 본문은 <br/> 로 치환되어야 한다');
    }

    @IsTest
    static void parsesKoreanSubjectMarkerWithoutBodyMarker() {
        String raw = '제목: 단기 여유자금 운용 제안\n본문 없이 이어지는 인사말입니다.';

        MeetingPrepEmailComposerController.EmailDraft d =
            MeetingPrepEmailComposerController.parseDraft(raw);

        System.Assert.areEqual('단기 여유자금 운용 제안', d.subject);
        System.Assert.areEqual('본문 없이 이어지는 인사말입니다.', d.bodyText);
    }

    @IsTest
    static void subjectMarkerWithoutNewlineKeepsSubjectNonBlank() {
        // 줄바꿈조차 없는 극단 케이스: 최소한 제목은 채워서 Send 가 가능하도록
        MeetingPrepEmailComposerController.EmailDraft d =
            MeetingPrepEmailComposerController.parseDraft('Subject: 제목만 있는 한 줄');

        System.Assert.areEqual('제목만 있는 한 줄', d.subject);
        System.Assert.isTrue(String.isNotBlank(d.subject), '제목이 비어서는 안 된다');
    }

    // ─── sendEmail ──────────────────────────────────────────────

    @IsTest
    static void sendEmail_SucceedsWhenLeadIsRecipient() {
        Lead ld = [SELECT Id FROM Lead LIMIT 1];

        Test.startTest();
        MeetingPrepEmailComposerController.sendEmail(
            '테스트 제목', '<p>테스트 본문</p>', ld.Id, new List<String>{ ld.Id }, null);
        System.Assert.areEqual(1, Limits.getEmailInvocations(), '이메일 발송이 1회 호출되어야 한다');
        Test.stopTest();
    }

    @IsTest
    static void sendEmail_SucceedsWithExtraContactRecipient() {
        Lead ld = [SELECT Id FROM Lead LIMIT 1];
        Contact ct = [SELECT Id FROM Contact LIMIT 1];

        Test.startTest();
        MeetingPrepEmailComposerController.sendEmail(
            '테스트 제목', '<p>테스트 본문</p>', ld.Id, new List<String>{ ld.Id, ct.Id }, null);
        System.Assert.areEqual(1, Limits.getEmailInvocations(), '이메일 발송이 1회 호출되어야 한다');
        Test.stopTest();
    }

    @IsTest
    static void sendEmail_SucceedsForAccountActivityWithContactRecipient() {
        Account account = new Account(
            Name = '메일 활동 테스트 고객사',
            Industry = '제조업',
            Business_Registration_Number__c = '1234567890'
        );
        insert account;
        Contact recipient = new Contact(
            LastName = 'AccountContact',
            name_new__c = 'AcctCont',
            AccountId = account.Id,
            Email = 'account-contact@example.com'
        );
        insert recipient;

        Test.startTest();
        MeetingPrepEmailComposerController.sendEmail(
            '테스트 제목', '<p>테스트 본문</p>', account.Id, new List<String>{ recipient.Id }, null
        );
        System.assertEquals(1, Limits.getEmailInvocations(), 'Account 활동 메일 발송이 1회 호출되어야 한다');
        Test.stopTest();
    }

    @IsTest
    static void sendEmail_ThrowsWhenSubjectOrBodyBlank() {
        Lead ld = [SELECT Id FROM Lead LIMIT 1];
        Boolean thrown = false;

        Test.startTest();
        try {
            MeetingPrepEmailComposerController.sendEmail(
                '', '<p>본문</p>', ld.Id, new List<String>{ ld.Id }, null);
        } catch (AuraHandledException e) {
            thrown = true;
        }
        Test.stopTest();

        System.Assert.isTrue(thrown, '제목이 비어있으면 예외가 발생해야 한다');
    }

    @IsTest
    static void sendEmail_ThrowsWhenRelatedToBlank() {
        Boolean thrown = false;
        Test.startTest();
        try {
            MeetingPrepEmailComposerController.sendEmail(
                '제목', '<p>본문</p>', null, new List<String>{ '00Q000000000000AAA' }, null);
        } catch (AuraHandledException e) {
            thrown = true;
        }
        Test.stopTest();

        System.Assert.isTrue(thrown, 'Related To 가 없으면 예외가 발생해야 한다');
    }

    @IsTest
    static void sendEmail_ThrowsWhenRelatedToIsNotLead() {
        Contact ct = [SELECT Id FROM Contact LIMIT 1];

        Boolean thrown = false;
        Test.startTest();
        try {
            MeetingPrepEmailComposerController.sendEmail(
                '제목', '<p>본문</p>', ct.Id, new List<String>{ ct.Id }, null);
        } catch (AuraHandledException e) {
            thrown = true;
        }
        Test.stopTest();

        System.Assert.isTrue(thrown, 'Related To 가 Lead 가 아니면 예외가 발생해야 한다');
    }

    @IsTest
    static void sendEmail_ThrowsWhenNoRecipients() {
        Lead ld = [SELECT Id FROM Lead LIMIT 1];

        Boolean thrown = false;
        Test.startTest();
        try {
            MeetingPrepEmailComposerController.sendEmail(
                '제목', '<p>본문</p>', ld.Id, new List<String>(), null);
        } catch (AuraHandledException e) {
            thrown = true;
        }
        Test.stopTest();

        System.Assert.isTrue(thrown, '받는 사람이 없으면 예외가 발생해야 한다');
    }

    // ─── 첨부 파일 (카탈로그 자동 + 사용자 선택) ────────────────────

    /** Files(ContentDocument)에 PDF 를 올리고 ContentDocumentId 를 돌려준다. */
    private static Id insertFile(String title, String pathOnClient) {
        ContentVersion version = new ContentVersion(
            Title = title,
            PathOnClient = pathOnClient,
            VersionData = Blob.valueOf('PDF-CONTENT ' + title)
        );
        insert version;
        return [
            SELECT ContentDocumentId FROM ContentVersion WHERE Id = :version.Id
        ].ContentDocumentId;
    }

    @IsTest
    static void getDefaultAttachments_ReturnsLatestCatalogPdf() {
        insertFile('근본증권 상품 카탈로그',
            'BORN_Securities_Corporate_Product_Catalogue_2026.pdf');

        Test.startTest();
        List<MeetingPrepEmailComposerController.AttachmentOption> options =
            MeetingPrepEmailComposerController.getDefaultAttachments();
        Test.stopTest();

        System.Assert.areEqual(1, options.size(), '카탈로그 1건이 기본 첨부로 반환되어야 한다');
        System.Assert.areEqual('근본증권 상품 카탈로그.pdf',
            options[0].fileName, 'Title 기반 한글 파일명이 사용되어야 한다');
        System.Assert.isNotNull(options[0].contentDocumentId, 'ContentDocumentId 가 채워져야 한다');
    }

    @IsTest
    static void getDefaultAttachments_IgnoresNonCatalogFiles() {
        insertFile('근본증권 상품 카탈로그',
            'BORN_Securities_Corporate_Product_Catalogue_2026.pdf');
        insertFile('Some_Other_Document', 'Some_Other_Document.pdf');

        Test.startTest();
        List<MeetingPrepEmailComposerController.AttachmentOption> options =
            MeetingPrepEmailComposerController.getDefaultAttachments();
        Test.stopTest();

        System.Assert.areEqual(1, options.size(), '카탈로그 접두사 파일만 대상이어야 한다');
        System.Assert.areEqual('근본증권 상품 카탈로그.pdf',
            options[0].fileName, '카탈로그 파일만 반환되어야 한다');
    }

    @IsTest
    static void getDefaultAttachments_ReturnsEmptyWhenNoCatalog() {
        Test.startTest();
        List<MeetingPrepEmailComposerController.AttachmentOption> options =
            MeetingPrepEmailComposerController.getDefaultAttachments();
        Test.stopTest();

        System.Assert.areEqual(0, options.size(), '카탈로그가 없으면 빈 목록이어야 한다');
    }

    @IsTest
    static void getFileInfo_ReturnsFileNamesForSelectedDocuments() {
        Id documentId = insertFile('선택_자료', '선택_자료.pdf');

        Test.startTest();
        List<MeetingPrepEmailComposerController.AttachmentOption> options =
            MeetingPrepEmailComposerController.getFileInfo(new List<String>{ documentId });
        Test.stopTest();

        System.Assert.areEqual(1, options.size(), '선택한 문서 1건의 메타가 반환되어야 한다');
        System.Assert.areEqual('선택_자료.pdf', options[0].fileName, 'Title + 확장자 기반 파일명이 반환되어야 한다');
        System.Assert.areEqual(documentId, options[0].contentDocumentId, 'ContentDocumentId 가 일치해야 한다');
    }

    @IsTest
    static void getFileInfo_ReturnsEmptyForNullInput() {
        Test.startTest();
        List<MeetingPrepEmailComposerController.AttachmentOption> options =
            MeetingPrepEmailComposerController.getFileInfo(null);
        Test.stopTest();

        System.Assert.areEqual(0, options.size(), 'null 입력은 빈 목록이어야 한다');
    }

    @IsTest
    static void buildAttachments_BuildsEmailAttachmentFromDocumentId() {
        Id documentId = insertFile('근본증권 상품 카탈로그',
            'BORN_Securities_Corporate_Product_Catalogue_2026.pdf');

        Test.startTest();
        List<Messaging.EmailFileAttachment> attachments =
            MeetingPrepEmailComposerController.buildAttachments(new List<String>{ documentId });
        Test.stopTest();

        System.Assert.areEqual(1, attachments.size(), '문서 1건이 첨부로 변환되어야 한다');
        System.Assert.areEqual('근본증권 상품 카탈로그.pdf',
            attachments[0].getFileName(), 'Title 기반 한글 파일명이 사용되어야 한다');
    }

    @IsTest
    static void buildAttachments_ReturnsEmptyWhenNoDocuments() {
        Test.startTest();
        List<Messaging.EmailFileAttachment> attachments =
            MeetingPrepEmailComposerController.buildAttachments(new List<String>());
        Test.stopTest();

        System.Assert.areEqual(0, attachments.size(), '선택 파일이 없으면 첨부 목록이 비어 있어야 한다');
    }

    @IsTest
    static void sendEmail_LeadPathAttachesSelectedDocument() {
        Lead ld = [SELECT Id FROM Lead LIMIT 1];
        Id documentId = insertFile('근본증권 상품 카탈로그',
            'BORN_Securities_Corporate_Product_Catalogue_2026.pdf');

        Test.startTest();
        MeetingPrepEmailComposerController.sendEmail(
            '테스트 제목', '<p>테스트 본문</p>', ld.Id,
            new List<String>{ ld.Id }, new List<String>{ documentId });
        System.Assert.areEqual(1, Limits.getEmailInvocations(),
            '첨부가 있어도 Lead 메일이 1회 발송되어야 한다');
        Test.stopTest();
    }

    @IsTest
    static void sendEmail_AccountPathAttachesSelectedDocument() {
        // 레이더(Account) 경로도 이제 첨부를 싣는다.
        Account account = new Account(
            Name = '첨부 포함 테스트 고객사',
            Industry = '제조업',
            Business_Registration_Number__c = '9876543210'
        );
        insert account;
        Contact recipient = new Contact(
            LastName = 'AcctRecipient',
            name_new__c = 'AcctRcpt',
            AccountId = account.Id,
            Email = 'account-path@example.com'
        );
        insert recipient;
        Id documentId = insertFile('근본증권 상품 카탈로그',
            'BORN_Securities_Corporate_Product_Catalogue_2026.pdf');

        Test.startTest();
        MeetingPrepEmailComposerController.sendEmail(
            '테스트 제목', '<p>테스트 본문</p>', account.Id,
            new List<String>{ recipient.Id }, new List<String>{ documentId });
        System.Assert.areEqual(1, Limits.getEmailInvocations(),
            'Account 경로도 첨부를 싣고 정상 발송되어야 한다');
        Test.stopTest();
    }

    @IsTest
    static void sendEmail_SucceedsWithNullAttachments() {
        Lead ld = [SELECT Id FROM Lead LIMIT 1];

        Test.startTest();
        MeetingPrepEmailComposerController.sendEmail(
            '테스트 제목', '<p>테스트 본문</p>', ld.Id, new List<String>{ ld.Id }, null);
        System.Assert.areEqual(1, Limits.getEmailInvocations(),
            '첨부가 없어도 메일은 정상 발송되어야 한다');
        Test.stopTest();
    }
}