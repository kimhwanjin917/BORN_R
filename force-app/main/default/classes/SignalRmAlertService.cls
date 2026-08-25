/**
 * 임계 이상(Relevance_Score__c·Confidence__c)인 ExternalSignal__c 발생 시
 * 담당 RM(= Account.OwnerId)에게 알림을 보내는 서비스.
 *
 * 트리거는 record-triggered Flow 가 담당하고(신규 ExternalSignal__c 생성 감지),
 * Flow 는 이 클래스의 @InvocableMethod(evaluate)를 호출한다. 핵심 로직(임계 판정·
 * RM 매핑·발송 위임)은 모두 Apex 에 있어 단위 테스트로 커버된다.
 *
 * 임계값은 DART_Setting__mdt.Default 의
 * Signal_Relevance_Threshold__c / Signal_Confidence_Threshold__c 에서 읽는다.
 * 실제 알림 발송·재처리·관리자 알림은 SignalRmAlertQueueable 이 담당한다.
 * (현재 발송 수단은 Salesforce Custom Notification. Slack 연동은 보류 상태이며
 *  발송부만 교체하면 Slack 로 전환 가능하다.)
 */
public with sharing class SignalRmAlertService {
    @TestVisible
    private static final Decimal DEFAULT_RELEVANCE_THRESHOLD = 70;
    @TestVisible
    private static final Decimal DEFAULT_CONFIDENCE_THRESHOLD = 60;

    /**
     * record-triggered Flow 가 호출하는 진입점. 신규 ExternalSignal__c 레코드 Id 를 받아
     * 임계 통과 건만 담당 RM 알림 대상으로 큐잉한다.
     *
     * @param signalIds 평가할 ExternalSignal__c 레코드 Id 목록(Flow 에서 전달)
     */
    @InvocableMethod(label='신규 공시 RM 알림 평가' description='임계 이상 공시 시그널을 담당 RM에게 알림')
    public static void evaluate(List<Id> signalIds) {
        if (signalIds == null || signalIds.isEmpty()) {
            return;
        }

        Decimal relevanceThreshold = getRelevanceThreshold();
        Decimal confidenceThreshold = getConfidenceThreshold();

        // 임계 통과 시그널 → 담당 RM(Account.OwnerId) 매핑
        Map<Id, Id> ownerBySignalId = new Map<Id, Id>();
        for (ExternalSignal__c signal : [
            SELECT Id, Relevance_Score__c, Confidence__c, Account__c, Account__r.OwnerId
            FROM ExternalSignal__c
            WHERE Id IN :signalIds
            WITH USER_MODE
        ]) {
            if (signal.Account__c == null || signal.Account__r.OwnerId == null) {
                continue;
            }
            if (!meetsThreshold(signal, relevanceThreshold, confidenceThreshold)) {
                continue;
            }
            ownerBySignalId.put(signal.Id, signal.Account__r.OwnerId);
        }

        if (!ownerBySignalId.isEmpty()) {
            System.enqueueJob(new SignalRmAlertQueueable(ownerBySignalId));
        }
    }

    @TestVisible
    private static Boolean meetsThreshold(
        ExternalSignal__c signal,
        Decimal relevanceThreshold,
        Decimal confidenceThreshold
    ) {
        Boolean relevanceOk = signal.Relevance_Score__c != null
            && signal.Relevance_Score__c >= relevanceThreshold;
        Boolean confidenceOk = signal.Confidence__c != null
            && signal.Confidence__c >= confidenceThreshold;
        return relevanceOk && confidenceOk;
    }

    private static Decimal getRelevanceThreshold() {
        DART_Setting__mdt setting = DART_Setting__mdt.getInstance('Default');
        if (setting == null || setting.Signal_Relevance_Threshold__c == null) {
            return DEFAULT_RELEVANCE_THRESHOLD;
        }
        return setting.Signal_Relevance_Threshold__c;
    }

    private static Decimal getConfidenceThreshold() {
        DART_Setting__mdt setting = DART_Setting__mdt.getInstance('Default');
        if (setting == null || setting.Signal_Confidence_Threshold__c == null) {
            return DEFAULT_CONFIDENCE_THRESHOLD;
        }
        return setting.Signal_Confidence_Threshold__c;
    }
}