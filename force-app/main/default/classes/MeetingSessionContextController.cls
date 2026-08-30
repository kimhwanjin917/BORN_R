public with sharing class MeetingSessionContextController {
    public class MeetingContext {
        @AuraEnabled public String recordId;
        @AuraEnabled public String objectApiName;
        @AuraEnabled public String objectLabel;
        @AuraEnabled public String recordName;
        @AuraEnabled public String companyName;
        @AuraEnabled public String ownerName;
        @AuraEnabled public String status;
        @AuraEnabled public String briefing;
        @AuraEnabled public String recommendationReason;
        @AuraEnabled public String sanitizedContent;
        @AuraEnabled public Integer maskedCount;
    }

    @AuraEnabled(cacheable=true)
    public static MeetingContext getMeetingContext(Id recordId) {
        MeetingContext result = new MeetingContext();
        result.recordId = String.valueOf(recordId);
        result.maskedCount = 0;
        if (recordId == null) return result;

        Schema.SObjectType objectType = recordId.getSObjectType();
        Schema.DescribeSObjectResult describeResult = objectType.getDescribe();
        String apiName = describeResult.getName();
        result.objectApiName = apiName;
        result.objectLabel = describeResult.getLabel();

        Map<String, Schema.SObjectField> fieldMap = describeResult.fields.getMap();
        List<String> fields = new List<String>{ 'Id' };
        addField(fields, fieldMap, apiName == 'Event' ? 'Subject' : 'Name');
        addField(fields, fieldMap, 'Description');

        if (apiName == 'Opportunity') {
            addField(fields, fieldMap, 'StageName');
            addField(fields, fieldMap, 'Amount');
            addField(fields, fieldMap, 'NextStep');
            fields.add('Account.Name');
            fields.add('Owner.Name');
        } else if (apiName == 'Lead') {
            addField(fields, fieldMap, 'Company');
            addField(fields, fieldMap, 'Status');
            addField(fields, fieldMap, 'Industry');
            addField(fields, fieldMap, 'AnnualRevenue');
            fields.add('Owner.Name');
        } else if (apiName == 'Account') {
            addField(fields, fieldMap, 'Industry');
            addField(fields, fieldMap, 'AnnualRevenue');
            addField(fields, fieldMap, 'Rating');
            fields.add('Owner.Name');
        } else if (apiName == 'Contact') {
            addField(fields, fieldMap, 'Title');
            fields.add('Account.Name');
            fields.add('Owner.Name');
        } else if (apiName == 'Event') {
            addField(fields, fieldMap, 'StartDateTime');
            addField(fields, fieldMap, 'EndDateTime');
            fields.add('What.Name');
            fields.add('Who.Name');
            fields.add('Owner.Name');
        }

        // Opportunity 상세의 '미팅 준비 브리핑'이 저장되는 필드를 최우선으로 본다.
        // 같은 필드를 source of truth 로 써야 두 화면의 추천이 어긋나지 않는다.
        String briefingField = firstExisting(fieldMap, new List<String>{
            'Meeting_Prep_Briefing__c',
            'Company_Briefing__c', 'Account_Briefing__c', 'Briefing__c', 'Meeting_Briefing__c'
        });
        String reasonField = firstExisting(fieldMap, new List<String>{
            'RP_Recommendation_Reason__c', 'Recommendation_Reason__c', 'Recommended_Reason__c', 'RP_Reason__c'
        });
        if (briefingField != null) fields.add(briefingField);
        if (reasonField != null) fields.add(reasonField);

        SObject row = Database.query('SELECT ' + String.join(fields, ',') + ' FROM ' + apiName + ' WHERE Id = :recordId LIMIT 1');
        result.recordName = textValue(row, apiName == 'Event' ? 'Subject' : 'Name');
        result.ownerName = relationshipName(row, 'Owner');
        result.companyName = resolveCompany(apiName, row);
        result.status = resolveStatus(apiName, row);

        String storedBriefing = briefingField == null ? null : textValue(row, briefingField);
        String description = textValue(row, 'Description');
        String storedReason = reasonField == null ? null : textValue(row, reasonField);

        if (String.isNotBlank(storedBriefing) && storedBriefing.contains(SECTION_MARK)) {
            // Opportunity 미팅 준비 브리핑 원문을 그대로 붙이지 않고 짧게 요약한다.
            // 새로 생성하지 않고 이미 저장된 결과만 읽는다(추가 AI 호출 없음).
            Map<String, String> parts = parseBriefingSections(storedBriefing);
            result.briefing = summariseBriefing(parts);
            result.recommendationReason = summariseRecommendation(parts, recordId, apiName);
        } else {
            result.briefing = String.isNotBlank(storedBriefing)
                ? storedBriefing
                : buildBriefing(apiName, row, description);
            result.recommendationReason = String.isNotBlank(storedReason)
                ? storedReason
                : buildRecommendationReason(apiName, row);
        }

        if (apiName == 'Opportunity') loadLatestMasking(recordId, result);
        return result;
    }

    private static void loadLatestMasking(Id opportunityId, MeetingContext result) {
        Map<String, Schema.SObjectType> globals = Schema.getGlobalDescribe();
        if (!globals.containsKey('Meeting_Note__c')) return;
        Map<String, Schema.SObjectField> noteFields = globals.get('Meeting_Note__c').getDescribe().fields.getMap();
        if (!noteFields.containsKey('Opportunity__c') || !noteFields.containsKey('Sanitized_Content__c')) return;

        String countField = firstExisting(noteFields, new List<String>{ 'Masked_Count__c', 'Masking_Count__c' });
        List<String> selected = new List<String>{ 'Sanitized_Content__c' };
        if (countField != null) selected.add(countField);
        List<SObject> notes = Database.query(
            'SELECT ' + String.join(selected, ',') +
            ' FROM Meeting_Note__c WHERE Opportunity__c = :opportunityId' +
            ' ORDER BY CreatedDate DESC LIMIT 1'
        );
        if (notes.isEmpty()) return;
        result.sanitizedContent = textValue(notes[0], 'Sanitized_Content__c');
        if (countField != null && notes[0].get(countField) != null) {
            result.maskedCount = Integer.valueOf(String.valueOf(notes[0].get(countField)));
        }
    }

    private static String resolveCompany(String apiName, SObject row) {
        if (apiName == 'Opportunity' || apiName == 'Contact') return relationshipName(row, 'Account');
        if (apiName == 'Lead') return textValue(row, 'Company');
        if (apiName == 'Account') return textValue(row, 'Name');
        if (apiName == 'Event') {
            String whatName = relationshipName(row, 'What');
            return String.isNotBlank(whatName) ? whatName : relationshipName(row, 'Who');
        }
        return null;
    }

    private static String resolveStatus(String apiName, SObject row) {
        if (apiName == 'Opportunity') return textValue(row, 'StageName');
        if (apiName == 'Lead') return textValue(row, 'Status');
        if (apiName == 'Account') return textValue(row, 'Rating');
        if (apiName == 'Contact') return textValue(row, 'Title');
        if (apiName == 'Event') return textValue(row, 'StartDateTime');
        return null;
    }

    private static String buildBriefing(String apiName, SObject row, String description) {
        List<String> parts = new List<String>();
        if (apiName == 'Opportunity') {
            addPart(parts, '현재 단계', textValue(row, 'StageName'));
            addPart(parts, '다음 단계', textValue(row, 'NextStep'));
        } else if (apiName == 'Lead' || apiName == 'Account') {
            addPart(parts, '산업', textValue(row, 'Industry'));
        } else if (apiName == 'Contact') {
            addPart(parts, '직책', textValue(row, 'Title'));
        } else if (apiName == 'Event') {
            addPart(parts, '미팅 일정', textValue(row, 'StartDateTime'));
        }
        if (String.isNotBlank(description)) parts.add(description);
        return parts.isEmpty() ? '저장된 기업 브리핑이 없습니다.' : String.join(parts, ' · ');
    }

    private static String buildRecommendationReason(String apiName, SObject row) {
        if (apiName == 'Opportunity') {
            String stage = textValue(row, 'StageName');
            return String.isNotBlank(stage)
                ? '현재 영업 단계(' + stage + ')와 미팅 메모의 고객 니즈를 함께 반영합니다.'
                : '기회 정보와 미팅 메모의 고객 니즈를 함께 반영합니다.';
        }
        return '현재 고객 정보와 미팅 메모를 함께 반영해 RP 추천 근거를 구성합니다.';
    }

    private static void addField(List<String> fields, Map<String, Schema.SObjectField> fieldMap, String name) {
        if (fieldMap.containsKey(name)) fields.add(name);
    }
    private static String firstExisting(Map<String, Schema.SObjectField> fieldMap, List<String> candidates) {
        for (String candidate : candidates) if (fieldMap.containsKey(candidate)) return candidate;
        return null;
    }
    private static String textValue(SObject row, String field) {
        if (row == null || String.isBlank(field)) return null;
        try { Object value = row.get(field); return value == null ? null : String.valueOf(value); }
        catch (Exception ignored) { return null; }
    }
    private static String relationshipName(SObject row, String relationship) {
        try {
            SObject related = row.getSObject(relationship);
            return related == null ? null : textValue(related, 'Name');
        } catch (Exception ignored) { return null; }
    }
    private static void addPart(List<String> parts, String label, String value) {
        if (String.isNotBlank(value)) parts.add(label + ' ' + value);
    }

    // ─── 메모 등록 (LWC 전용) ─────────────────────────────────────────────
    //
    // 화면 이동 없이 미팅 메모를 저장한다. 마스킹은 직접 호출하지 않는다 —
    // MeetingNoteTrigger(before insert/update)가 MaskingService.mask() 를 돌려
    // Sanitized_Content__c / Masked_Count__c 를 채우므로, 저장 후 재조회만 한다.
    //
    // 같은 세션에서 다시 등록하면 새 Note 를 만들지 않고 기존 Note 를 update 한다.

    /** 메모 등록 결과 */
    public class SaveResult {
        @AuraEnabled public String meetingNoteId;
        @AuraEnabled public String opportunityId; // docs/60 — 기회 없는 메모는 추천 대상 아님을 화면이 바로 안내
        @AuraEnabled public String sanitizedContent;
        @AuraEnabled public Integer maskedCount;
    }

    @AuraEnabled
    public static SaveResult saveMeetingNote(Id recordId, String rawContent, Id meetingNoteId) {
        if (String.isBlank(rawContent)) {
            throw new AuraHandledException('미팅 내용을 입력해주세요.');
        }

        Meeting_Note__c note = new Meeting_Note__c();

        if (meetingNoteId == null) {
            // 진입 레코드에서 Account / Contact / Opportunity / Event 관계를 해석한다.
            // 해석 규칙은 기존 MeetingNoteContextService 를 그대로 재사용한다.
            MeetingNoteContextService.Request req = new MeetingNoteContextService.Request();
            req.recordId = recordId == null ? null : String.valueOf(recordId);
            List<MeetingNoteContextService.Result> resolved =
                MeetingNoteContextService.resolveContext(
                    new List<MeetingNoteContextService.Request>{ req });

            if (!resolved.isEmpty()) {
                MeetingNoteContextService.Result ctx = resolved[0];
                if (String.isNotBlank(ctx.accountId))     note.Account__c     = ctx.accountId;
                if (String.isNotBlank(ctx.contactId))     note.Contact__c     = ctx.contactId;
                if (String.isNotBlank(ctx.opportunityId)) note.Opportunity__c = ctx.opportunityId;
                if (String.isNotBlank(ctx.eventId))       note.Event_Id__c    = ctx.eventId;
                if (ctx.meetingDate != null)              note.Meeting_Date__c = ctx.meetingDate;
            }
        } else {
            // 재등록: 기존 Note 를 수정한다(중복 생성 방지).
            note.Id = meetingNoteId;
        }

        note.Raw_Content__c = rawContent;

        try {
            upsert note;
        } catch (DmlException e) {
            throw new AuraHandledException(e.getDmlMessage(0));
        }

        // 트리거가 채운 마스킹 결과를 그대로 돌려준다.
        List<Meeting_Note__c> saved = [
            SELECT Id, Sanitized_Content__c, Masked_Count__c, Opportunity__c
            FROM Meeting_Note__c
            WHERE Id = :note.Id
            WITH USER_MODE
            LIMIT 1
        ];

        SaveResult result = new SaveResult();
        result.meetingNoteId = String.valueOf(note.Id);
        result.maskedCount = 0;
        if (!saved.isEmpty()) {
            result.sanitizedContent = saved[0].Sanitized_Content__c;
            result.opportunityId = saved[0].Opportunity__c == null ? null : String.valueOf(saved[0].Opportunity__c);
            if (saved[0].Masked_Count__c != null) {
                result.maskedCount = Integer.valueOf(saved[0].Masked_Count__c);
            }
        }
        return result;
    }

    // ─── 미팅 저장 시 수수료 조건 저장 (docs/58·60 연장) ──────────────────
    //
    // [미팅 저장](meetingNotePad.handlePrimaryAction)이 호출한다. 수수료 조건 계산기 값을
    // 기회에 저장해 상품팀 조건 카드(OpportunityDealChannelService)가 읽을 수 있게 한다.
    // 거래금액→Amount, 제안수익률→RP_Yield__c, 수수료율→Fee_Rate__c, 기간(일)→RP_Maturity_Date__c(오늘+일수).
    // 값이 들어온 항목만 기록. 호출부는 실패해도 미팅 저장 흐름을 막지 않는다.
    @AuraEnabled
    public static void saveDealTerms(Id recordId, Decimal dealAmount, Decimal annualYield, Decimal feeRate, Integer termDays) {
        // 미팅 화면의 recordId 는 Event(00U…)일 수 있다. 메모 저장과 동일하게 연결된 Opportunity 로 해석한다.
        Id opportunityId = resolveOpportunityId(recordId);
        if (opportunityId == null) {
            return;
        }
        Opportunity opp = new Opportunity(Id = opportunityId);
        Boolean hasValue = false;
        if (dealAmount != null)  { opp.Amount = dealAmount; hasValue = true; }
        if (annualYield != null) { opp.RP_Yield__c = annualYield; hasValue = true; }
        if (feeRate != null)     { opp.Fee_Rate__c = feeRate; hasValue = true; }
        if (termDays != null)    { opp.RP_Maturity_Date__c = Date.today().addDays(termDays); hasValue = true; }
        if (hasValue) {
            // 미팅 담당자가 그 기회에 편집 공유가 없을 수 있어(회신 저장과 동일) 시스템 모드로 쓴다.
            new DealTermWriter().save(opp);
        }
    }

    /** 미팅 화면 recordId(Opportunity 또는 Event 등)를 연결된 Opportunity Id 로 해석한다. */
    private static Id resolveOpportunityId(Id recordId) {
        if (recordId == null) {
            return null;
        }
        if (recordId.getSObjectType() == Opportunity.SObjectType) {
            return recordId;
        }
        try {
            MeetingNoteContextService.Request req = new MeetingNoteContextService.Request();
            req.recordId = String.valueOf(recordId);
            List<MeetingNoteContextService.Result> resolved =
                MeetingNoteContextService.resolveContext(new List<MeetingNoteContextService.Request>{ req });
            if (!resolved.isEmpty() && String.isNotBlank(resolved[0].opportunityId)) {
                return (Id) resolved[0].opportunityId;
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'saveDealTerms opp 해석 실패: ' + e.getMessage());
        }
        return null;
    }

    /** 수수료 조건 저장 전용 — 미팅 담당 RM 의 공유 권한과 무관하게 기회에 쓴다. */
    private without sharing class DealTermWriter {
        void save(Opportunity opp) {
            update opp;
        }
    }

    // ─── 상품 추천 조회 (LWC polling 용) ──────────────────────────────────
    //
    // 추천은 Meeting Note 저장 뒤 비동기(Queueable)로 생성되어
    // Product_Recommendation__c 에 기록된다. LWC 는 저장 직후 이 메서드를
    // 짧게 폴링해서 결과가 채워지면 오른쪽 카드에 표시한다.
    // 실패 시에도 예외를 던지지 않는다 — 메모 저장·마스킹 성공 상태를 지켜야 한다.

    /** 추천 폴링 결과 */
    public class RecommendationState {
        @AuraEnabled public Boolean ready;        // 값이 채워졌는가
        @AuraEnabled public Boolean failed;       // 추천 생성이 실패로 기록됐는가
        @AuraEnabled public String recommendation; // 성공 시 추천 본문
        @AuraEnabled public String errorMessage;   // 실패 시 사유
    }

    @AuraEnabled
    public static RecommendationState getRecommendation(Id meetingNoteId) {
        RecommendationState state = new RecommendationState();
        state.ready = false;
        state.failed = false;
        if (meetingNoteId == null) {
            return state;
        }

        Map<String, Schema.SObjectField> noteFields =
            Meeting_Note__c.SObjectType.getDescribe().fields.getMap();
        Schema.SObjectField recoField = noteFields.get('Product_Recommendation__c');
        if (recoField == null || !recoField.getDescribe().isAccessible()) {
            // 필드가 없거나 접근 권한이 없으면 조용히 미완료로 둔다.
            return state;
        }

        List<Meeting_Note__c> notes = [
            SELECT Product_Recommendation__c
            FROM Meeting_Note__c
            WHERE Id = :meetingNoteId
            LIMIT 1
        ];
        if (notes.isEmpty()) {
            return state;
        }

        String stored = notes[0].Product_Recommendation__c;
        if (String.isBlank(stored)) {
            return state;
        }

        state.ready = true;
        if (stored.startsWith(MeetingNoteAgentRecommender.FAILURE_PREFIX)) {
            state.failed = true;
            state.errorMessage =
                stored.substring(MeetingNoteAgentRecommender.FAILURE_PREFIX.length());
        } else {
            state.recommendation = stored;
        }
        return state;
    }

    // ─── 미팅 준비 브리핑 요약 ────────────────────────────────────────────
    //
    // 원문은 Opportunity 의 Meeting_Prep_Briefing__c 에 이미 저장돼 있다.
    // 여기서는 새로 생성하지 않고, 프롬프트 템플릿이 만든 '◆/■' 구조를
    // leadMeetingPrepBriefing LWC 와 동일한 규약으로 읽어 짧게 줄인다.

    private static final String SECTION_MARK = '\u25A0';  // ■
    private static final String GROUP_MARK = '\u25C6';    // ◆

    /** '■ 제목: 본문' 블록을 제목 → 본문 맵으로 만든다. */
    private static Map<String, String> parseBriefingSections(String briefing) {
        Map<String, String> parts = new Map<String, String>();
        if (String.isBlank(briefing)) {
            return parts;
        }
        for (String block : briefing.split(SECTION_MARK)) {
            String chunk = block == null ? '' : block.trim();
            if (chunk.length() == 0) {
                continue;
            }
            // 다음 ◆ 그룹 헤더가 붙어 있으면 잘라낸다.
            Integer groupAt = chunk.indexOf(GROUP_MARK);
            if (groupAt > 0) {
                chunk = chunk.substring(0, groupAt).trim();
            }
            Integer colon = chunk.indexOf(':');
            if (colon <= 0) {
                continue;
            }
            String title = chunk.substring(0, colon).trim();
            String body = chunk.substring(colon + 1).trim();
            if (String.isNotBlank(title) && String.isNotBlank(body) && !parts.containsKey(title)) {
                parts.put(title, body);
            }
        }
        return parts;
    }

    /** 제목 후보 중 먼저 존재하는 본문을 돌려준다. */
    private static String section(Map<String, String> parts, List<String> titles) {
        for (String title : titles) {
            for (String key : parts.keySet()) {
                if (key.contains(title)) {
                    return parts.get(key);
                }
            }
        }
        return null;
    }

    /** 첫 문장 또는 첫 항목만 짧게 남긴다. */
    private static String firstLine(String body, Integer maxLength) {
        if (String.isBlank(body)) {
            return null;
        }
        String line = body.split('\n')[0].trim();
        if (line.startsWith('-')) {
            line = line.substring(1).trim();
        }
        if (maxLength != null && line.length() > maxLength) {
            line = line.substring(0, maxLength).trim() + '\u2026';
        }
        return line;
    }

    /** 앞쪽 항목 몇 개만 뽑는다(미팅 포인트용). */
    private static List<String> topBullets(String body, Integer howMany) {
        List<String> picked = new List<String>();
        if (String.isBlank(body)) {
            return picked;
        }
        for (String raw : body.split('\n')) {
            String line = raw == null ? '' : raw.trim();
            if (line.startsWith('-')) {
                line = line.substring(1).trim();
            }
            if (String.isBlank(line)) {
                continue;
            }
            picked.add(line.length() > 60 ? line.substring(0, 60).trim() + '\u2026' : line);
            if (picked.size() >= howMany) {
                break;
            }
        }
        return picked;
    }

    /** 기업 브리핑: 추천상품 · 재무 · 최근 동향 · 미팅 포인트 2개. */
    private static String summariseBriefing(Map<String, String> parts) {
        List<String> lines = new List<String>();

        String product = firstLine(section(parts, new List<String>{ '추천상품', '추천 상품' }), 40);
        if (String.isNotBlank(product)) {
            lines.add('추천: ' + product);
        }
        String finance = firstLine(section(parts, new List<String>{ '재무 하이라이트', '재무' }), 90);
        if (String.isNotBlank(finance)) {
            lines.add(finance);
        }
        String trend = firstLine(section(parts, new List<String>{ '최근 동향', '동향', '시그널' }), 90);
        if (String.isNotBlank(trend)) {
            lines.add(trend);
        }
        for (String point : topBullets(section(parts, new List<String>{ '미팅 포인트', '미팅포인트' }), 2)) {
            lines.add('\u00B7 ' + point);
        }

        return lines.isEmpty()
            ? '저장된 미팅 준비 브리핑이 없습니다.'
            : String.join(lines, '\n');
    }

    /** RP 추천 관점: 추천상품 · 유사 WON 확률 · 추천 근거 · 확인할 질문. */
    private static String summariseRecommendation(
        Map<String, String> parts, Id recordId, String apiName
    ) {
        List<String> lines = new List<String>();

        String product = firstLine(section(parts, new List<String>{ '추천상품', '추천 상품' }), 40);
        if (String.isNotBlank(product)) {
            lines.add('추천 상품: ' + product);
        }

        // 유사 WON 확률은 Opportunity 화면과 같은 집계 로직을 그대로 재사용한다.
        if (apiName == 'Opportunity') {
            try {
                MeetingPrepBriefingController.SimilarWonCardResult won =
                    MeetingPrepBriefingController.getSimilarWon(recordId);
                if (won != null && won.insufficientData != true && won.wonRate != null) {
                    lines.add('유사 거래 WON 확률: ' + won.wonRate.setScale(1) + '%');
                }
            } catch (Exception ignored) {
                // 집계 실패는 브리핑 표시를 막지 않는다.
            }
        }

        String reason = firstLine(
            section(parts, new List<String>{ '추천 근거', '추천근거', '한줄 요약' }), 110
        );
        if (String.isNotBlank(reason)) {
            lines.add('추천 근거: ' + reason);
        }
        List<String> asks = topBullets(section(parts, new List<String>{ '미팅 포인트', '미팅포인트' }), 1);
        if (!asks.isEmpty()) {
            lines.add('확인할 질문: ' + asks[0]);
        }

        return lines.isEmpty()
            ? 'Opportunity에서 미팅 준비 브리핑을 먼저 생성하면 추천 관점을 확인할 수 있습니다.'
            : String.join(lines, '\n');
    }
}