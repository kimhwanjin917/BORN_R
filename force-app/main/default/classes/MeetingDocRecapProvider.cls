/**
 * 프롬프트 템플릿 "Document_Recap"(Flex, 백로그 27번 — 미팅 직전 복기용 리포트·가계약서 요약) 의 grounding 용 Apex.
 *
 * Prompt Builder 에서 리소스로 추가하면 템플릿 본문의 {!$Apex:MeetingDocRecapProvider.Prompt} 자리에
 *   1) 해당 Opportunity 의 최근 미팅 메모 **마스킹본**(Meeting_Note__c.Sanitized_Content__c, 최신순 최대 3건)
 *   2) Opportunity 에 첨부된 파일 목록(제목·확장자·크기) — 텍스트 계열(txt/md/csv/html) 파일은 본문 발췌 포함
 * 을 텍스트로 주입한다. 딜 조건(금액·상품·RP수익률·만기 등)은 템플릿이 Opportunity 머지 필드로 직접 참조한다.
 *
 * 보안 원칙: Raw_Content__c(원문)는 어떤 경우에도 조회·포함하지 않는다. 조회는 실행 사용자 권한(WITH USER_MODE).
 * PDF/Office 파일은 Apex 에서 본문을 추출할 수 없으므로 파일명·크기만 나열한다(템플릿에 그 사실을 명시).
 *
 * Flex 템플릿용 Apex 는 @InvocableMethod 에 CapabilityType 을 지정하지 않는다 (이 org 에서 컴파일 거부 — 15번 작업 때 확인).
 * Request 멤버 이름은 템플릿 입력(apiName)과 같아야 한다: RelatedOpportunity (Object: Opportunity).
 * 권한이 없거나 데이터가 없으면 예외 대신 안내 문구를 돌려줘서 프롬프트는 항상 생성되게 한다.
 */
public with sharing class MeetingDocRecapProvider {

    @TestVisible private static final Integer MAX_NOTES = 3;
    @TestVisible private static final Integer MAX_FILES = 10;
    /** 텍스트 파일 본문 발췌 상한(문자). */
    @TestVisible private static final Integer MAX_TEXT_EXCERPT = 4000;
    /** 본문 발췌를 시도할 텍스트 계열 확장자. */
    @TestVisible private static final Set<String> TEXT_EXTENSIONS = new Set<String>{ 'txt', 'md', 'csv', 'html', 'htm' };
    /** 본문을 읽을 텍스트 파일 크기 상한(바이트) — 힙 보호. */
    @TestVisible private static final Integer MAX_TEXT_FILE_BYTES = 200 * 1024;

    @TestVisible private static final String NO_NOTE_MESSAGE = '(이 영업기회에 저장된 미팅 메모가 없습니다. 지난 미팅 내용은 "기록 없음"으로 쓰고 지어내지 마세요.)';
    @TestVisible private static final String NO_NOTE_ACCESS_MESSAGE = '(미팅 메모 조회 권한이 없어 지난 미팅 내용을 제공할 수 없습니다. 지어내지 마세요.)';
    @TestVisible private static final String NO_FILE_MESSAGE = '(첨부된 자료 파일이 없습니다.)';
    @TestVisible private static final String NO_FILE_ACCESS_MESSAGE = '(첨부 파일 조회 권한이 없습니다.)';

    @InvocableMethod(
        label='미팅 전 자료 요약 프롬프트: 최근 마스킹본·첨부 자료 grounding'
        description='영업기회의 최근 미팅 메모 마스킹본(최대 3건)과 첨부 파일 목록(텍스트 파일은 본문 발췌)을 텍스트로 묶어 Document_Recap 프롬프트 템플릿에 주입합니다. 원문(Raw_Content__c)은 포함하지 않습니다.'
    )
    public static List<Response> getRecapContext(List<Request> requests) {
        List<Response> responses = new List<Response>();
        if (requests == null || requests.isEmpty()) {
            return responses;
        }
        for (Request request : requests) {
            Response response = new Response();
            Id opportunityId = request != null && request.RelatedOpportunity != null ? request.RelatedOpportunity.Id : null;
            response.Prompt = buildContext(opportunityId);
            responses.add(response);
        }
        return responses;
    }

    @TestVisible
    private static String buildContext(Id opportunityId) {
        if (opportunityId == null) {
            return '[지난 미팅 메모(마스킹본)]\n' + NO_NOTE_MESSAGE + '\n\n[첨부 자료]\n' + NO_FILE_MESSAGE;
        }
        return '[지난 미팅 메모(마스킹본, 최신순)]\n' + buildNotesText(opportunityId)
            + '\n\n[첨부 자료]\n' + buildFilesText(opportunityId);
    }

    /** 최근 Meeting_Note 마스킹본 최대 MAX_NOTES 건. Raw_Content__c 는 조회하지 않는다. */
    @TestVisible
    private static String buildNotesText(Id opportunityId) {
        List<Meeting_Note__c> notes;
        try {
            notes = [
                SELECT Id, Name, CreatedDate, Masked_Count__c, Sanitized_Content__c
                FROM Meeting_Note__c
                WHERE Opportunity__c = :opportunityId
                WITH USER_MODE
                ORDER BY CreatedDate DESC
                LIMIT :MAX_NOTES
            ];
        } catch (QueryException e) {
            return NO_NOTE_ACCESS_MESSAGE;
        }
        if (notes.isEmpty()) {
            return NO_NOTE_MESSAGE;
        }
        List<String> blocks = new List<String>();
        Integer index = 1;
        for (Meeting_Note__c note : notes) {
            String content = String.isBlank(note.Sanitized_Content__c) ? '(마스킹본 비어 있음)' : note.Sanitized_Content__c.trim();
            blocks.add('[메모 ' + index + '] ' + note.CreatedDate.format('yyyy-MM-dd')
                + ' (' + note.Name + ', 마스킹 ' + (note.Masked_Count__c == null ? 0 : note.Masked_Count__c.intValue()) + '건)\n'
                + content);
            index++;
        }
        return String.join(blocks, '\n\n');
    }

    /** Opportunity 첨부 파일 목록 + 텍스트 파일 본문 발췌. */
    @TestVisible
    private static String buildFilesText(Id opportunityId) {
        List<ContentVersion> versions;
        try {
            Set<Id> documentIds = new Set<Id>();
            for (ContentDocumentLink link : [
                SELECT ContentDocumentId
                FROM ContentDocumentLink
                WHERE LinkedEntityId = :opportunityId
                WITH USER_MODE
            ]) {
                documentIds.add(link.ContentDocumentId);
            }
            if (documentIds.isEmpty()) {
                return NO_FILE_MESSAGE;
            }
            versions = [
                SELECT Id, Title, FileExtension, ContentSize, LastModifiedDate
                FROM ContentVersion
                WHERE ContentDocumentId IN :documentIds AND IsLatest = true
                WITH USER_MODE
                ORDER BY LastModifiedDate DESC
                LIMIT :MAX_FILES
            ];
        } catch (QueryException e) {
            return NO_FILE_ACCESS_MESSAGE;
        }
        if (versions.isEmpty()) {
            return NO_FILE_MESSAGE;
        }

        List<String> blocks = new List<String>();
        Integer index = 1;
        for (ContentVersion version : versions) {
            String ext = String.isBlank(version.FileExtension) ? '' : version.FileExtension.toLowerCase();
            String line = '[자료 ' + index + '] ' + version.Title
                + (String.isBlank(ext) ? '' : ' (.' + ext + ')')
                + ', ' + formatSize(version.ContentSize)
                + ', 수정일 ' + version.LastModifiedDate.format('yyyy-MM-dd');
            String excerpt = extractTextExcerpt(version, ext);
            if (excerpt != null) {
                line += '\n본문 발췌:\n' + excerpt;
            } else {
                line += '\n(본문 자동 추출 불가 형식 — 파일명과 딜 조건 필드만 근거로 요약)';
            }
            blocks.add(line);
            index++;
        }
        return String.join(blocks, '\n\n');
    }

    /** txt/md/csv/html 파일이면 본문을 읽어 발췌(HTML 태그 제거). 그 외/너무 큰 파일은 null. */
    @TestVisible
    private static String extractTextExcerpt(ContentVersion version, String ext) {
        if (!TEXT_EXTENSIONS.contains(ext)) {
            return null;
        }
        if (version.ContentSize == null || version.ContentSize > MAX_TEXT_FILE_BYTES) {
            return null;
        }
        try {
            Blob body = [SELECT VersionData FROM ContentVersion WHERE Id = :version.Id WITH USER_MODE LIMIT 1].VersionData;
            if (body == null || body.size() == 0) {
                return null;
            }
            String text = body.toString();
            if (ext == 'html' || ext == 'htm') {
                text = stripHtml(text);
            }
            text = text.trim();
            if (String.isBlank(text)) {
                return null;
            }
            if (text.length() > MAX_TEXT_EXCERPT) {
                text = text.substring(0, MAX_TEXT_EXCERPT) + '\n…(이하 생략)';
            }
            return text;
        } catch (Exception e) {
            return null;
        }
    }

    @TestVisible
    private static String stripHtml(String html) {
        String text = html.replaceAll('(?is)<(script|style)[^>]*>.*?</\\1>', ' ');
        text = text.replaceAll('(?i)<br\\s*/?>', '\n').replaceAll('(?i)</(p|div|li|tr|h[1-6])>', '\n');
        text = text.replaceAll('<[^>]+>', ' ');
        text = text.replace('&nbsp;', ' ').replace('&amp;', '&').replace('&lt;', '<').replace('&gt;', '>').replace('&quot;', '"');
        text = text.replaceAll('[ \\t]+', ' ').replaceAll('\\n\\s*\\n+', '\n');
        return text;
    }

    @TestVisible
    private static String formatSize(Integer bytes) {
        if (bytes == null) {
            return '크기 미상';
        }
        if (bytes < 1024) {
            return bytes + 'B';
        }
        if (bytes < 1024 * 1024) {
            return (bytes / 1024) + 'KB';
        }
        Decimal mb = Decimal.valueOf(bytes).divide(1024 * 1024, 1);
        return mb + 'MB';
    }

    // ─── Request / Response (이름은 템플릿 입력/출력과 일치해야 함) ───

    public class Request {
        @InvocableVariable(required=true label='RelatedOpportunity' description='요약 대상 영업기회 (템플릿 입력 RelatedOpportunity)')
        public Opportunity RelatedOpportunity;
    }

    public class Response {
        @InvocableVariable(required=true label='Prompt' description='템플릿에 주입할 grounding 텍스트')
        public String Prompt;
    }
}