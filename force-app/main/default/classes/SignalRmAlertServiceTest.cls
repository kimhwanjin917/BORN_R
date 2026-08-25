/**
 * SignalRmAlertService / SignalRmAlertQueueable 테스트.
 * 임계 판정, 담당 RM(Account.OwnerId) 매핑, 알림 발송, 실패 시 재처리·관리자 알림을 검증한다.
 * 실제 Custom Notification 발송·이메일 발송은 @TestVisible 훅으로 우회해 결정론적으로 확인한다.
 */
@isTest
private class SignalRmAlertServiceTest {
    private static final String CORP_CODE = '00126380';

    // 임계 통과(연관성 90 ≥ 70, 신뢰도 80 ≥ 60) 시그널을 생성한다.
    private static ExternalSignal__c buildSignal(Id accountId, Decimal relevance, Decimal confidence) {
        return new ExternalSignal__c(
            Account__c = accountId,
            External_Key__c = CORP_CODE + '_' + relevance + '_' + confidence,
            Signal_Type__c = '공시',
            Title__c = '유형자산 취득결정',
            Relevance_Score__c = relevance,
            Confidence__c = confidence
        );
    }

    @isTest
    static void shouldNotifyRm_WhenSignalInsertedViaFlow() {
        // Given: 임계 통과 시그널을 insert 하면 record-triggered Flow 가 evaluate 를 호출한다.
        // (Flow → Apex → Queueable 엔드투엔드 검증) RM = Account.OwnerId(= 생성 사용자)
        User dartUser = TestDataFactory.createDartUser();
        System.runAs(dartUser) {
            Account account = TestDataFactory.createAccount(CORP_CODE, true);
            ExternalSignal__c signal = buildSignal(account.Id, 90, 80);
            SignalRmAlertQueueable.sentNotifications.clear();

            // When: insert → Flow 가 자동으로 평가·큐잉 → stopTest 에서 Queueable 실행
            Test.startTest();
            insert signal;
            Test.stopTest();

            // Then: 담당 RM 에게 알림 1건이 발송되어야 한다
            Assert.areEqual(1, SignalRmAlertQueueable.sentNotifications.size(),
                '임계 통과 시그널 insert 시 Flow 경로로 RM 알림 1건이 발송되어야 한다');
            Assert.areEqual(dartUser.Id, SignalRmAlertQueueable.sentNotifications[0],
                'Account.OwnerId(RM)에게 발송되어야 한다');
        }
    }

    @isTest
    static void shouldNotEnqueue_WhenBelowThreshold() {
        // Given: 신뢰도 미달(50 < 60) → 알림 대상 아님
        User dartUser = TestDataFactory.createDartUser();
        System.runAs(dartUser) {
            Account account = TestDataFactory.createAccount(CORP_CODE, true);
            ExternalSignal__c signal = buildSignal(account.Id, 90, 50);
            insert signal;

            // When
            Test.startTest();
            SignalRmAlertService.evaluate(new List<Id>{ signal.Id });
            Test.stopTest();

            // Then
            Assert.areEqual(0, SignalRmAlertQueueable.sentNotifications.size(),
                '임계 미달 시 알림이 발송되지 않아야 한다');
        }
    }

    @isTest
    static void shouldSkip_WhenAccountOrOwnerMissing() {
        // Given: Account 미연결 시그널 → RM 을 특정할 수 없어 스킵
        User dartUser = TestDataFactory.createDartUser();
        System.runAs(dartUser) {
            ExternalSignal__c signal = buildSignal(null, 90, 80);
            insert signal;

            // When
            Test.startTest();
            SignalRmAlertService.evaluate(new List<Id>{ signal.Id });
            Test.stopTest();

            // Then
            Assert.areEqual(0, SignalRmAlertQueueable.sentNotifications.size(),
                'Account/Owner 없으면 알림 대상이 아니다');
        }
    }

    @isTest
    static void shouldDoNothing_WhenEmptyInput() {
        // When / Then: 빈 입력은 조용히 종료
        Test.startTest();
        SignalRmAlertService.evaluate(new List<Id>());
        SignalRmAlertService.evaluate(null);
        Test.stopTest();
        Assert.areEqual(0, SignalRmAlertQueueable.sentNotifications.size(),
            '입력이 없으면 아무것도 발송되지 않아야 한다');
    }

    @isTest
    static void shouldMeetThreshold_UsesDefaultsWhenSettingBlank() {
        // 기본 임계값(연관성 70, 신뢰도 60) 경계 검증
        ExternalSignal__c pass = buildSignal(null, 70, 60);
        ExternalSignal__c failRelevance = buildSignal(null, 69, 60);
        ExternalSignal__c failConfidence = buildSignal(null, 70, 59);
        ExternalSignal__c nullScores = new ExternalSignal__c();

        Test.startTest();
        Assert.isTrue(
            SignalRmAlertService.meetsThreshold(pass,
                SignalRmAlertService.DEFAULT_RELEVANCE_THRESHOLD,
                SignalRmAlertService.DEFAULT_CONFIDENCE_THRESHOLD),
            '경계값(70/60)은 통과해야 한다');
        Assert.isFalse(
            SignalRmAlertService.meetsThreshold(failRelevance,
                SignalRmAlertService.DEFAULT_RELEVANCE_THRESHOLD,
                SignalRmAlertService.DEFAULT_CONFIDENCE_THRESHOLD),
            '연관성 미달은 통과하지 않아야 한다');
        Assert.isFalse(
            SignalRmAlertService.meetsThreshold(failConfidence,
                SignalRmAlertService.DEFAULT_RELEVANCE_THRESHOLD,
                SignalRmAlertService.DEFAULT_CONFIDENCE_THRESHOLD),
            '신뢰도 미달은 통과하지 않아야 한다');
        Assert.isFalse(
            SignalRmAlertService.meetsThreshold(nullScores,
                SignalRmAlertService.DEFAULT_RELEVANCE_THRESHOLD,
                SignalRmAlertService.DEFAULT_CONFIDENCE_THRESHOLD),
            '점수가 null 이면 통과하지 않아야 한다');
        Test.stopTest();
    }

    @isTest
    static void shouldReEnqueue_WhenSendFailsAndRetriesRemain() {
        // Given: 발송 실패를 주입 → execute 의 catch(handleFailure)가 재큐 경로를 타야 한다(첫 시도).
        SignalRmAlertQueueable.forceSendFailure = true;
        Map<Id, Id> ownerBySignalId = new Map<Id, Id>{ UserInfo.getUserId() => UserInfo.getUserId() };

        // When
        Test.startTest();
        new SignalRmAlertQueueable(ownerBySignalId).execute(null);
        Test.stopTest();

        // Then
        Assert.isNotNull(SignalRmAlertQueueable.retryEnqueued,
            '일시적 실패 시 재시도가 재큐되어야 한다');
        Assert.areEqual(0, SignalRmAlertQueueable.sentEmails.size(),
            '재시도가 남아있으면 관리자 알림은 아직 발송되지 않아야 한다');
    }

    @isTest
    static void shouldNotifyAdmin_WhenFailsFinally() {
        // Given: 최종 실패 시 관리자 알림 경로
        SignalRmAlertQueueable.testAdminEmail = 'admin@example.com';
        Map<Id, Id> ownerBySignalId = new Map<Id, Id>{ UserInfo.getUserId() => UserInfo.getUserId() };
        SignalRmAlertQueueable queueable = new SignalRmAlertQueueable(ownerBySignalId);

        // When
        Test.startTest();
        queueable.notifyAdmin(
            new SignalRmAlertQueueable.SignalRmAlertException('발송 실패'), 3);
        Test.stopTest();

        // Then
        Assert.areEqual(1, SignalRmAlertQueueable.sentEmails.size(),
            '최종 실패 시 관리자 이메일 1건이 발송되어야 한다');
        Assert.areEqual(new List<String>{ 'admin@example.com' },
            SignalRmAlertQueueable.sentEmails[0].getToAddresses(),
            '설정된 관리자 주소로 발송되어야 한다');
    }

    @isTest
    static void shouldSendViaExecute_WhenQueueableRuns() {
        // Given: execute() 정상 경로(sendNotifications)를 직접 검증.
        // 임계 미달(신뢰도 50) 시그널을 insert 해 record-triggered Flow 의 자동 큐잉을 피하고,
        // execute 를 직접 호출해 발송 1건만 결정론적으로 검증한다.
        User dartUser = TestDataFactory.createDartUser();
        System.runAs(dartUser) {
            Account account = TestDataFactory.createAccount(CORP_CODE, true);
            ExternalSignal__c signal = buildSignal(account.Id, 90, 50);
            insert signal;

            Map<Id, Id> ownerBySignalId = new Map<Id, Id>{ signal.Id => dartUser.Id };
            SignalRmAlertQueueable.sentNotifications.clear();

            // When
            Test.startTest();
            new SignalRmAlertQueueable(ownerBySignalId).execute(null);
            Test.stopTest();

            // Then
            Assert.areEqual(1, SignalRmAlertQueueable.sentNotifications.size(),
                'execute 정상 실행 시 알림 1건이 발송되어야 한다');
            Assert.areEqual(dartUser.Id, SignalRmAlertQueueable.sentNotifications[0],
                '대상 RM 에게 발송되어야 한다');
        }
    }

    @isTest
    static void shouldResolveNotificationType_WhenExists() {
        // Custom Notification Type 이 배포되어 있으면 Id 를 반환해야 한다
        SignalRmAlertQueueable queueable =
            new SignalRmAlertQueueable(new Map<Id, Id>());
        Test.startTest();
        Id typeId = queueable.getNotificationTypeId();
        Test.stopTest();
        Assert.isNotNull(typeId, 'DART_Signal_RM_Alert 알림 타입 Id 가 조회되어야 한다');
    }
}