/**
 * SlackCmdtDeployer 테스트.
 * Apex Metadata API 를 통한 Slack__mdt 레코드 배포 요청 구성(createRecord)과
 * 배포 완료 콜백(handleResult)의 성공/실패 경로를 검증한다.
 *
 * enqueueDeployment 는 테스트 컨텍스트에서 실제 배포를 수행하지 않으므로,
 * 콜백은 Metadata.DeployResult 를 직접 구성해 결정론적으로 검증한다.
 */
@isTest
private class SlackCmdtDeployerTest {

    @isTest
    static void shouldBuildContainer_WhenCreateRecordCalled() {
        // When: 레코드 배포를 요청한다.
        // 컨테이너 구성 로직은 실행되지만, enqueueDeployment 는 테스트 컨텍스트에서
        // AsyncException('Metadata cannot be deployed from within a test')을 던진다.
        Test.startTest();
        try {
            SlackCmdtDeployer.createRecord(
                'Acme_Org',
                'Acme Org',
                '00Dxx0000001gP0',
                'Acme',
                'https://acme.my.salesforce.com',
                'acme.my.salesforce.com',
                'E01ABC',
                'owner@acme.com'
            );
            Assert.fail('테스트 컨텍스트에서는 메타데이터 배포가 허용되지 않아 예외가 발생해야 한다');
        } catch (System.AsyncException e) {
            // Then: 배포 enqueue 직전까지 컨테이너 구성이 정상 수행됨을 의미한다
            Assert.isTrue(e.getMessage().contains('deployed'),
                '테스트 컨텍스트의 메타데이터 배포 제한 예외여야 한다');
        }
        Test.stopTest();
    }

    @isTest
    static void shouldHandleSuccess_WhenDeploySucceeds() {
        // Given
        Metadata.DeployResult result = new Metadata.DeployResult();
        result.status = Metadata.DeployStatus.Succeeded;
        Metadata.DeployCallbackContext context = new Metadata.DeployCallbackContext();

        // When / Then: 성공 콜백이 예외 없이 처리되어야 한다
        Test.startTest();
        new SlackCmdtDeployer().handleResult(result, context);
        Test.stopTest();
    }

    @isTest
    static void shouldHandleFailure_WhenDeployFails() {
        // Given
        Metadata.DeployResult result = new Metadata.DeployResult();
        result.status = Metadata.DeployStatus.Failed;
        result.errorMessage = 'field integrity exception';
        Metadata.DeployCallbackContext context = new Metadata.DeployCallbackContext();

        // When / Then: 실패 콜백이 예외 없이 처리되어야 한다
        Test.startTest();
        new SlackCmdtDeployer().handleResult(result, context);
        Test.stopTest();
    }
}