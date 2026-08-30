public with sharing class MeetingPrepEmailComposerController {

    private static final String PROMPT_TEMPLATE_NAME = 'Meeting_Prep_Email_Draft';
    private static final String RADAR_PROMPT_TEMPLATE_NAME = 'Opportunity_Radar_Email_Draft';
    // 맞춤 메일에 자동 첨부할 RP 고객용 브로슈어를 찾는 기준.
    // 상품 Id/Name 은 하드코딩하지 않고, 활성 RP 상품(Family='RP', IsActive=true)에
    // 이 제목 계열로 실제 연결된 파일만 대상으로 한다.
    @TestVisible
    private static final String BROCHURE_RP_FAMILY = 'RP';
    @TestVisible
    private static final String BROCHURE_TITLE_PREFIX = 'BORN_Securities_RP_Customer_Brochure';
    private static final String BROCHURE_CONTENT_TYPE = 'application/pdf';
    /**
     * 프롬프트 템플릿은 '제목:' · '본문:' 을 요구하지만 LLM 이 'Subject:' 로 내는 일이 실제로 있었다
     * (한쪽만 영문으로 섞여 나오기도 한다). 형식이 한 번 어긋났다고 화면이 죽으면 안 되므로
     * 두 표기를 모두 받아들인다. 먼저 나오는 마커를 기준으로 자른다.
     */
    @TestVisible
    private static final List<String> SUBJECT_MARKERS = new List<String>{ '제목:', 'Subject:' };
    @TestVisible
    private static final List<String> BODY_MARKERS = new List<String>{ '본문:', 'Body:' };
    @TestVisible
    private static final List<String> BODY_FALLBACK_MARKERS = new List<String>{
        '안녕하세요', '안녕하십니까'
    };

    public class EmailDraft {
        @AuraEnabled public String subject;
        @AuraEnabled public String htmlBody;
        @AuraEnabled public String bodyText;
        @AuraEnabled public String toAddress;
        @AuraEnabled public String relatedToId;
        @AuraEnabled public String leadName;
        @AuraEnabled public String fromAddress;
        @AuraEnabled public List<String> fromOptions;
        @AuraEnabled public String recipientId;
        @AuraEnabled public String recipientName;
        @AuraEnabled public String recipientTitle;
        @AuraEnabled public String accountName;
        @AuraEnabled public String recipientNote;
    }

    public class EmailContext {
        @AuraEnabled public String toAddress;
        @AuraEnabled public String relatedToId;
        @AuraEnabled public String leadName;
        @AuraEnabled public String fromAddress;
        @AuraEnabled public List<String> fromOptions;
    }

    // 창을 즉시 띄우기 위한 빠른 컨텍스트 (LLM 호출 없음)
    @AuraEnabled(cacheable=false)
    public static EmailContext getEmailContext(Id leadId) {
        Lead leadRecord = [
            SELECT Id, Name, Email FROM Lead WHERE Id = :leadId WITH USER_MODE LIMIT 1
        ];
        EmailContext ctx = new EmailContext();
        ctx.toAddress = leadRecord.Email;
        ctx.relatedToId = leadRecord.Id;
        ctx.leadName = leadRecord.Name;
        ctx.fromAddress = UserInfo.getUserEmail();
        ctx.fromOptions = buildFromOptions();
        return ctx;
    }

    @AuraEnabled(cacheable=true)
    public static String getRecordName(Id recordId) {
        if (recordId == null) {
            return '';
        }
        String objName = recordId.getSObjectType().getDescribe().getName();
        List<SObject> rows = Database.query(
            'SELECT Name FROM ' + String.escapeSingleQuotes(objName) + ' WHERE Id = :recordId WITH USER_MODE LIMIT 1'
        );
        return rows.isEmpty() ? '' : String.valueOf(rows[0].get('Name'));
    }

    private static List<String> buildFromOptions() {
        List<String> options = new List<String>();
        String userEmail = UserInfo.getUserEmail();
        if (String.isNotBlank(userEmail)) {
            options.add(userEmail);
        }
        // OrgWideEmailAddress is a setup object. For users without View Setup and
        // Configuration, Salesforce can omit it from the Apex describe and a direct
        // SOQL query fails with "sObject type ... is not supported". The mail
        // composer still works with the user's own address, so treat org-wide
        // addresses as an optional enhancement rather than a hard dependency.
        if (!Schema.getGlobalDescribe().containsKey('OrgWideEmailAddress')) {
            return options;
        }
        try {
            for (OrgWideEmailAddress owa : [
                SELECT Address FROM OrgWideEmailAddress WHERE Purpose = 'UserSelection'
            ]) {
                if (String.isNotBlank(owa.Address) && !options.contains(owa.Address)) {
                    options.add(owa.Address);
                }
            }
        } catch (Exception ignored) {
            // Some restricted profiles expose the type in describe but still cannot
            // query it. Do not block composing a mail for that user.
        }
        return options;
    }

    @AuraEnabled(cacheable=false)
    public static EmailDraft getEmailDraft(Id leadId) {
        try {
            Lead leadRecord = [
                SELECT Id, Company, Name, Title, Industry, Email, Owner.Name
                FROM Lead
                WHERE Id = :leadId
                WITH USER_MODE
                LIMIT 1
            ];

            Invocable.Action action = Invocable.Action.createCustomAction('generatePromptResponse', PROMPT_TEMPLATE_NAME);
            action.setInvocationParameter('Input:RelatedLead', leadRecord);
            List<Invocable.Action.Result> results = action.invoke();

            if (results == null || results.isEmpty() || !results[0].isSuccess()) {
                String errorDetail = (results != null && !results.isEmpty())
                    ? String.valueOf(results[0].getErrors())
                    : '알 수 없는 오류';
                throw new AuraHandledException('메일 초안 생성 응답이 비어 있습니다: ' + errorDetail);
            }

            Object rawResponse = results[0].getOutputParameters().get('promptResponse');
            if (rawResponse == null) {
                throw new AuraHandledException('메일 초안 생성 응답이 비어 있습니다.');
            }

            EmailDraft draft = parseDraft(String.valueOf(rawResponse));
            draft.toAddress = leadRecord.Email;
            draft.relatedToId = leadRecord.Id;
            draft.leadName = leadRecord.Name;
            draft.fromAddress = UserInfo.getUserEmail();
            draft.fromOptions = buildFromOptions();
            return draft;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('첫 접촉 메일 초안 생성 중 오류가 발생했습니다: ' + e.getMessage());
        }
    }

    /**
     * 기회 레이더의 Account 추천을 고객사 담당자 확인 메일로 바꾼다.
     * 현재 등록된 Contact를 자동 수신인으로 쓰되, 담당자 변경 가능성을 본문에서
     * 정중하게 확인하도록 해 오래된 연락처로 단정하지 않는다.
     */
    @AuraEnabled(cacheable=false)
    public static EmailDraft getOpportunityRadarEmailDraft(Id accountId, Id recommendationId) {
        try {
            if (accountId == null || accountId.getSObjectType() != Account.SObjectType) {
                throw new AuraHandledException('메일을 보낼 고객사 정보가 없습니다.');
            }
            if (recommendationId == null) {
                throw new AuraHandledException('메일에 연결할 추천을 선택해 주세요.');
            }

            Account accountRecord = [
                SELECT Id, Name, Industry, Owner.Name
                FROM Account
                WHERE Id = :accountId
                WITH USER_MODE
                LIMIT 1
            ];
            Recommendation__c recommendation = [
                SELECT Id, Account__c, Product__r.Name, Product__r.Family, Type__c
                FROM Recommendation__c
                WHERE Id = :recommendationId AND Account__c = :accountId
                WITH USER_MODE
                LIMIT 1
            ];
            List<Contact> contacts = [
                SELECT Id, Name, Title, Email, LastModifiedDate
                FROM Contact
                WHERE AccountId = :accountId AND Email != null
                WITH USER_MODE
                ORDER BY LastModifiedDate DESC, CreatedDate DESC
                LIMIT 1
            ];
            if (contacts.isEmpty()) {
                throw new AuraHandledException('이 고객사에 이메일이 등록된 연락처가 없습니다. 담당자를 확인해 주세요.');
            }

            Contact recipient = contacts[0];
            String ownerName = accountRecord.Owner == null || String.isBlank(accountRecord.Owner.Name)
                ? UserInfo.getName() : accountRecord.Owner.Name;
            String subject = '[근본증권] ' + accountRecord.Name + ' 자금 운용 관련 인사';
            String productFamily = recommendation.Product__r == null ? null : recommendation.Product__r.Family;
            EmailDraft draft = buildRadarPromptDraft(accountRecord, recipient, ownerName, productFamily);
            if (draft == null) {
                draft = new EmailDraft();
                draft.subject = subject;
                draft.bodyText = buildRadarEmailBody(accountRecord, recipient, ownerName, productFamily);
            }
            draft.htmlBody = draft.bodyText.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('\n', '<br/>');
            draft.toAddress = recipient.Email;
            draft.relatedToId = accountRecord.Id;
            draft.accountName = accountRecord.Name;
            draft.recipientId = recipient.Id;
            draft.recipientName = recipient.Name;
            draft.recipientTitle = recipient.Title;
            draft.recipientNote = '현재 고객사에 등록된 이메일 보유 연락처 중 최근 수정된 담당자를 수신인으로 선택했습니다. 담당자가 변경되었다면 알려주시거나 적합한 담당자께 전달해 달라는 문구가 본문에 포함됩니다.';
            draft.fromAddress = UserInfo.getUserEmail();
            draft.fromOptions = buildFromOptions();
            return draft;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('담당자 메일 초안 생성 중 오류가 발생했습니다: ' + e.getMessage());
        }
    }

    @TestVisible
    private static EmailDraft buildRadarPromptDraft(Account accountRecord, Contact recipient, String ownerName, String productFamily) {
        try {
            Invocable.Action action = Invocable.Action.createCustomAction('generatePromptResponse', RADAR_PROMPT_TEMPLATE_NAME);
            action.setInvocationParameter('Input:RelatedAccount', accountRecord);
            action.setInvocationParameter('Input:RelatedContact', recipient);
            action.setInvocationParameter(
                'Input:RecommendationContext',
                '추천 상품군: ' + (productFamily == null ? '정보 없음' : productFamily)
                    + '\n작성 목적: 오랜만에 연락하는 고객사 담당자에게 현재 담당자와 자금 운용 니즈를 확인하는 재접촉 메일'
            );
            List<Invocable.Action.Result> results = action.invoke();
            if (results == null || results.isEmpty() || !results[0].isSuccess()) {
                return null;
            }
            Object rawResponse = results[0].getOutputParameters().get('promptResponse');
            if (rawResponse == null || String.isBlank(String.valueOf(rawResponse))) {
                return null;
            }
            EmailDraft draft = parseDraft(String.valueOf(rawResponse));
            if (String.isBlank(draft.subject) || String.isBlank(draft.bodyText)) {
                return null;
            }
            return draft;
        } catch (Exception ignored) {
            // The deterministic Radar copy remains available until the Prompt Builder
            // template is manually published in the org.
            return null;
        }
    }

    @TestVisible
    private static String buildRadarEmailBody(Account accountRecord, Contact recipient, String ownerName, String productFamily) {
        String recipientName = String.isBlank(recipient.Name) ? '담당자' : recipient.Name;
        String accountName = String.isBlank(accountRecord.Name) ? '귀사' : accountRecord.Name;
        String productLine = productFamily == WalletShareService.FAMILY_RP || productFamily == WalletShareService.FAMILY_CASH_MGMT
            ? 'RP 등 단기 자금 운용 방안'
            : '금융 방안';
        return '안녕하세요, ' + recipientName + '님.\n\n'
            + '오랜만에 연락드려 조심스럽게 인사드립니다.\n'
            + accountName + '의 자금 운용과 관련해, 현재 상황에 맞는 ' + productLine + '을 함께 검토해 볼 수 있을 것 같아 연락드렸습니다.\n'
            + '현재 운용 중인 자금의 기간과 필요하신 유동성을 먼저 여쭙고, 그에 맞는 방안을 안내드리고자 합니다.\n'
            + '혹시 담당 업무가 변경되었거나 제가 잘못 연락드린 경우라면, 번거로우시겠지만 적합한 담당자께 전달해 주시거나 알려주시면 감사하겠습니다.\n'
            + '가능하시다면 이번 주 중 15분 내외로 간단히 통화할 수 있을까요? 편하신 시간에 부담 없이 회신 부탁드립니다.\n\n'
            + '감사합니다.\n근본증권 ' + ownerName + ' 드림';
    }

    /**
     * 맞춤 메일 초안을 지정된 Lead 및 추가 수신자에게 발송한다.
     *
     * @param subject 메일 제목
     * @param htmlBody HTML 형식의 메일 본문
     * @param relatedToId 활동으로 연결할 Lead Id
     * @param recipientIds 수신 대상 Lead/Contact Id 목록
     */
    @AuraEnabled
    public static void sendEmail(
        String subject,
        String htmlBody,
        Id relatedToId,
        List<String> recipientIds
    ) {
        try {
            if (String.isBlank(subject) || String.isBlank(htmlBody)) {
                throw new AuraHandledException('제목과 본문을 입력해 주세요.');
            }
            if (relatedToId == null || (relatedToId.getSObjectType() != Lead.SObjectType && relatedToId.getSObjectType() != Account.SObjectType)) {
                throw new AuraHandledException('메일을 연결할 Lead 또는 고객사 정보가 없습니다.');
            }
            if (recipientIds == null || recipientIds.isEmpty()) {
                throw new AuraHandledException('받는 사람을 한 명 이상 선택해 주세요.');
            }

            List<Id> leadRecipientIds = new List<Id>();
            List<Id> contactRecipientIds = new List<Id>();
            Set<Id> seenRecipientIds = new Set<Id>();
            for (String recipientIdText : recipientIds) {
                if (String.isBlank(recipientIdText)) {
                    continue;
                }
                Id recipientId;
                try {
                    recipientId = (Id) recipientIdText;
                } catch (Exception e) {
                    throw new AuraHandledException('받는 사람 정보를 확인할 수 없습니다.');
                }
                if (seenRecipientIds.contains(recipientId)) {
                    continue;
                }
                seenRecipientIds.add(recipientId);
                if (recipientId.getSObjectType() == Lead.SObjectType) {
                    leadRecipientIds.add(recipientId);
                } else if (recipientId.getSObjectType() == Contact.SObjectType) {
                    contactRecipientIds.add(recipientId);
                } else {
                    throw new AuraHandledException('Lead 또는 Contact만 받는 사람으로 선택할 수 있습니다.');
                }
            }
            if (leadRecipientIds.isEmpty() && contactRecipientIds.isEmpty()) {
                throw new AuraHandledException('받는 사람을 한 명 이상 선택해 주세요.');
            }
            if (relatedToId.getSObjectType() == Account.SObjectType && !leadRecipientIds.isEmpty()) {
                throw new AuraHandledException('고객사 메일은 해당 고객사의 Contact 수신인만 선택할 수 있습니다.');
            }

            List<String> toAddresses = new List<String>();
            Set<String> seenAddresses = new Set<String>();
            if (!leadRecipientIds.isEmpty()) {
                for (Lead recipient : [
                    SELECT Email
                    FROM Lead
                    WHERE Id IN :leadRecipientIds
                    WITH USER_MODE
                ]) {
                    addEmailAddress(toAddresses, seenAddresses, recipient.Email);
                }
            }
            if (!contactRecipientIds.isEmpty()) {
                for (Contact recipient : [
                    SELECT Email, AccountId
                    FROM Contact
                    WHERE Id IN :contactRecipientIds
                    WITH USER_MODE
                ]) {
                    if (relatedToId.getSObjectType() == Account.SObjectType && recipient.AccountId != relatedToId) {
                        throw new AuraHandledException('고객사에 연결된 담당자만 수신인으로 선택할 수 있습니다.');
                    }
                    addEmailAddress(toAddresses, seenAddresses, recipient.Email);
                }
            }
            if (toAddresses.isEmpty()) {
                throw new AuraHandledException('선택한 받는 사람에게 이메일 주소가 없습니다.');
            }

            Messaging.SingleEmailMessage message = new Messaging.SingleEmailMessage();
            if (relatedToId.getSObjectType() == Lead.SObjectType) {
                // TargetObjectId는 활동 연결용으로만 사용하고 실제 수신자는 검증한 목록으로 지정한다.
                message.setTargetObjectId(relatedToId);
                message.setTreatTargetObjectAsRecipient(false);
            } else {
                // Account 활동은 Contact를 TargetObjectId로 삼고, Account를 WhatId로 연결한다.
                // TargetObjectId는 활동 연결용으로만 사용하며 실제 수신인은 검증한 목록으로 지정한다.
                if (contactRecipientIds.isEmpty()) {
                    throw new AuraHandledException('고객사 메일은 Contact 수신인이 필요합니다.');
                }
                message.setTargetObjectId(contactRecipientIds[0]);
                message.setTreatTargetObjectAsRecipient(false);
                message.setWhatId(relatedToId);
            }
            message.setToAddresses(toAddresses);
            message.setSubject(subject.trim());
            message.setHtmlBody(htmlBody);
            message.setSaveAsActivity(true);
            // Lead 맞춤 메일 경로에서만 RP 고객용 브로슈어를 자동 첨부한다.
            // Account(레이더 등) 경로에는 첨부하지 않는다. 브로슈어가 없으면 첨부 없이 발송된다.
            if (relatedToId.getSObjectType() == Lead.SObjectType) {
                List<Messaging.EmailFileAttachment> attachments = buildBrochureAttachments();
                if (!attachments.isEmpty()) {
                    message.setFileAttachments(attachments);
                }
            }
            Messaging.sendEmail(new Messaging.SingleEmailMessage[]{ message });
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('메일 발송 중 오류가 발생했습니다.');
        }
    }

    /**
     * 활성 RP 상품(Family='RP', IsActive=true)에 연결된 고객용 브로슈어 파일을
     * EmailFileAttachment 목록으로 만든다. 상품·파일 Id 를 하드코딩하지 않고
     * 파일 제목이 브로슈어 계열(BROCHURE_TITLE_PREFIX)인 것만, 각 문서의 최신
     * ContentVersion 1건씩만 첨부한다. 브로슈어가 없으면 빈 목록을 돌려준다.
     */
    @TestVisible
    private static List<Messaging.EmailFileAttachment> buildBrochureAttachments() {
        List<Messaging.EmailFileAttachment> attachments = new List<Messaging.EmailFileAttachment>();

        Set<Id> rpProductIds = new Set<Id>();
        for (Product2 product : [
            SELECT Id FROM Product2 WHERE Family = :BROCHURE_RP_FAMILY AND IsActive = true WITH USER_MODE
        ]) {
            rpProductIds.add(product.Id);
        }
        if (rpProductIds.isEmpty()) {
            return attachments;
        }

        String titlePattern = BROCHURE_TITLE_PREFIX + '%';
        Set<Id> documentIds = new Set<Id>();
        for (ContentDocumentLink link : [
            SELECT ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId IN :rpProductIds
              AND ContentDocument.Title LIKE :titlePattern
            WITH USER_MODE
        ]) {
            documentIds.add(link.ContentDocumentId);
        }
        if (documentIds.isEmpty()) {
            return attachments;
        }

        // 각 문서의 최신 버전(IsLatest=true) 1건만 첨부한다. 동일 브로슈어가
        // 여러 버전이어도 최신 하나만, 다른 파일이 섞여 있어도 브로슈어만 대상이다.
        for (ContentVersion version : [
            SELECT Title, PathOnClient, VersionData
            FROM ContentVersion
            WHERE ContentDocumentId IN :documentIds AND IsLatest = true
            WITH USER_MODE
        ]) {
            Messaging.EmailFileAttachment attachment = new Messaging.EmailFileAttachment();
            String fileName = String.isNotBlank(version.PathOnClient)
                ? version.PathOnClient
                : version.Title + '.pdf';
            attachment.setFileName(fileName);
            attachment.setBody(version.VersionData);
            attachment.setContentType(BROCHURE_CONTENT_TYPE);
            attachments.add(attachment);
        }
        return attachments;
    }

    private static void addEmailAddress(
        List<String> addresses,
        Set<String> seenAddresses,
        String address
    ) {
        if (String.isNotBlank(address) && !seenAddresses.contains(address)) {
            addresses.add(address);
            seenAddresses.add(address);
        }
    }

    /** 주어진 표기들 중 가장 먼저 나오는 것을 돌려준다. 하나도 없으면 null. */
    @TestVisible
    private static String firstMarker(String text, List<String> markers, Integer fromIndex) {
        String found = null;
        Integer bestIdx = -1;
        for (String marker : markers) {
            Integer idx = text.indexOf(marker, fromIndex);
            if (idx != -1 && (bestIdx == -1 || idx < bestIdx)) {
                bestIdx = idx;
                found = marker;
            }
        }
        return found;
    }

    @TestVisible
    private static EmailDraft parseDraft(String rawText) {
        if (String.isBlank(rawText)) {
            throw new AuraHandledException('메일 초안 생성 결과가 비어 있습니다.');
        }

        String subjectMarker = firstMarker(rawText, SUBJECT_MARKERS, 0);
        Integer subjectIdx = subjectMarker == null ? -1 : rawText.indexOf(subjectMarker);
        String bodyMarker = subjectIdx == -1 ? null : firstMarker(rawText, BODY_MARKERS, subjectIdx + 1);
        Integer bodyIdx = bodyMarker == null ? -1 : rawText.indexOf(bodyMarker, subjectIdx + 1);
        if (subjectIdx == -1) {
            throw new AuraHandledException('메일 초안 형식을 해석할 수 없습니다: ' + rawText);
        }

        String subjectLine;
        String bodyText;
        if (bodyIdx != -1 && bodyIdx > subjectIdx) {
            subjectLine = rawText.substring(subjectIdx + subjectMarker.length(), bodyIdx).trim();
            bodyText = rawText.substring(bodyIdx + bodyMarker.length()).trim();
        } else {
            // The prompt occasionally returns "Subject:" followed by a newline
            // and the body without the optional "Body:" marker. Parse that common
            // response shape instead of rejecting an otherwise usable draft.
            String remainder = rawText.substring(subjectIdx + subjectMarker.length()).trim();
            Integer lineBreakIdx = remainder.indexOf('\n');
            if (lineBreakIdx > -1) {
                subjectLine = remainder.substring(0, lineBreakIdx).trim();
                bodyText = remainder.substring(lineBreakIdx + 1).trim();
            } else {
                String fallbackMarker = firstMarker(remainder, BODY_FALLBACK_MARKERS, 0);
                Integer fallbackIdx = fallbackMarker == null
                    ? -1 : remainder.indexOf(fallbackMarker);
                if (fallbackIdx <= 0) {
                    // 제목만 반환된 경우에도 제목을 보존한다. 본문은 사용자가
                    // 직접 작성하거나 Send 단계의 필수값 검증에서 안내한다.
                    subjectLine = remainder;
                    bodyText = '';
                } else {
                    subjectLine = remainder.substring(0, fallbackIdx).trim();
                    bodyText = remainder.substring(fallbackIdx).trim();
                }
            }
        }
        if (String.isBlank(subjectLine)) {
            throw new AuraHandledException('메일 초안 형식을 해석할 수 없습니다: ' + rawText);
        }

        EmailDraft draft = new EmailDraft();
        draft.subject = subjectLine;
        draft.bodyText = bodyText;
        draft.htmlBody = bodyText.replace('\n', '<br/>');
        return draft;
    }
}