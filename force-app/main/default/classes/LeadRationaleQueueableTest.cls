/**
 * LeadRationaleQueueable 테스트.
 * 프롬프트 템플릿 호출은 stubResponse seam 으로 대체해, 상위 Lead 선정·응답 파싱·필드 저장을 검증한다.
 *
 * 팀 동결 파일 TestDataFactory 는 건드리지 않고 Lead 는 이 클래스 헬퍼로 만든다.
 */
@isTest
private class LeadRationaleQueueableTest {

    private static final String SAMPLE_RESPONSE =
        '요약: 현금성자산 비율이 높아 RP 적합도 우수\n'
        + '상세: 우선순위 88점. 현금성자산이 320억으로 니즈 규모가 크고, 전년 대비 40% 증가해 최신 공시 점수도 높다.';

    @isTest
    static void shouldStoreRationale_WhenTopLeadHasScore() {
        Lead lead = createLead('Top Lead', 88);
        LeadRationaleQueueable.stubResponse = SAMPLE_RESPONSE;

        Test.startTest();
        System.enqueueJob(new LeadRationaleQueueable(10));
        Test.stopTest();

        Lead saved = [
            SELECT Priority_Rationale_Summary__c, Priority_Rationale_Detail__c, Priority_Rationale_Updated_At__c
            FROM Lead WHERE Id = :lead.Id
        ];
        Assert.areEqual(
            '현금성자산 비율이 높아 RP 적합도 우수',
            saved.Priority_Rationale_Summary__c,
            '요약 마커 뒤 텍스트가 요약 필드에 저장돼야 한다'
        );
        Assert.isTrue(
            saved.Priority_Rationale_Detail__c.startsWith('우선순위 88점'),
            '상세 마커 뒤 텍스트가 상세 필드에 저장돼야 한다'
        );
        Assert.areNotEqual(null, saved.Priority_Rationale_Updated_At__c, '갱신 시각이 기록돼야 한다');
    }

    @isTest
    static void shouldSkipLead_WhenScoreIsNull() {
        Lead lead = createLead('No Score Lead', null);
        LeadRationaleQueueable.stubResponse = SAMPLE_RESPONSE;

        Test.startTest();
        System.enqueueJob(new LeadRationaleQueueable(10));
        Test.stopTest();

        Lead saved = [SELECT Priority_Rationale_Summary__c FROM Lead WHERE Id = :lead.Id];
        Assert.areEqual(null, saved.Priority_Rationale_Summary__c, '점수 없는 Lead 는 사유 생성 대상이 아니다');
    }

    @isTest
    static void shouldLimitToTopCount_WhenMoreLeadsThanLimit() {
        // 상위 2건만 대상으로 지정하고 3건을 만들어, 최하위 1건이 제외되는지 검증한다.
        Lead high1 = createLead('High 1', 90);
        Lead high2 = createLead('High 2', 80);
        Lead low = createLead('Low', 10);
        LeadRationaleQueueable.stubResponse = SAMPLE_RESPONSE;

        Test.startTest();
        System.enqueueJob(new LeadRationaleQueueable(2));
        Test.stopTest();

        Map<Id, Lead> byId = new Map<Id, Lead>([
            SELECT Priority_Rationale_Summary__c FROM Lead
            WHERE Id IN (:high1.Id, :high2.Id, :low.Id)
        ]);
        Assert.areNotEqual(null, byId.get(high1.Id).Priority_Rationale_Summary__c, '상위 1위는 생성돼야 한다');
        Assert.areNotEqual(null, byId.get(high2.Id).Priority_Rationale_Summary__c, '상위 2위는 생성돼야 한다');
        Assert.areEqual(null, byId.get(low.Id).Priority_Rationale_Summary__c, '한도 밖 최하위는 제외돼야 한다');
    }

    @isTest
    static void shouldParseDetailOnly_WhenSummaryMarkerMissing() {
        LeadRationaleQueueable queueable = new LeadRationaleQueueable();
        LeadRationaleQueueable.RationaleText parsed = queueable.parseResponse('상세: 첫 줄 근거\n둘째 줄');

        Assert.areEqual('첫 줄 근거', parsed.summary, '요약 마커가 없으면 상세 첫 줄을 요약으로 쓴다');
        Assert.isTrue(parsed.detail.contains('둘째 줄'), '상세는 마커 뒤 전체를 담는다');
    }

    @isTest
    static void shouldReturnNull_WhenTemplateResponseBlank() {
        LeadRationaleQueueable queueable = new LeadRationaleQueueable();
        LeadRationaleQueueable.stubResponse = '';

        Id leadId = createLead('Blank Resp Lead', 50).Id;
        LeadRationaleQueueable.RationaleText result = queueable.generateRationale(leadId);

        Assert.areEqual(null, result, '빈 응답이면 null 을 돌려 해당 Lead 를 갱신에서 제외한다');
    }

    // ─── 헬퍼 ──────────────────────────────────────────────────────────────

    private static Integer brnSeq = 3000000;

    private static Lead createLead(String company, Integer score) {
        Integer seq = brnSeq++;
        Lead lead = new Lead(
            LastName = 'Tester' + seq,
            Company = company,
            Status = '신규',
            IsConverted = false,
            Email = 'tester' + seq + '@example.com',
            Priority_Score__c = score,
            name_new__c = 'Tester',
            Business_Registration_Number__c = String.valueOf(seq)
        );
        Database.DMLOptions dml = new Database.DMLOptions();
        dml.DuplicateRuleHeader.AllowSave = true;
        lead.setOptions(dml);
        insert lead;
        return lead;
    }
}