@IsTest
private class TableauRefreshServiceTest {

    /** 로그인 → 새로고침 두 번의 호출을 순서대로 흉내 낸다. */
    private class TableauMock implements HttpCalloutMock {
        private Integer signInStatus;
        private Integer refreshStatus;
        private String signInBody;
        public List<String> calledEndpoints = new List<String>();
        public String refreshAuthHeader;

        private TableauMock(Integer signInStatus, String signInBody, Integer refreshStatus) {
            this.signInStatus = signInStatus;
            this.signInBody = signInBody;
            this.refreshStatus = refreshStatus;
        }

        public HttpResponse respond(HttpRequest req) {
            calledEndpoints.add(req.getEndpoint());
            HttpResponse res = new HttpResponse();
            if (req.getEndpoint().contains('/auth/signin')) {
                res.setStatusCode(signInStatus);
                res.setBody(signInBody);
            } else {
                refreshAuthHeader = req.getHeader('X-Tableau-Auth');
                res.setStatusCode(refreshStatus);
                res.setBody('{"job":{"id":"job-1"}}');
            }
            return res;
        }
    }

    private static String signInOk() {
        return '{"credentials":{"token":"tok-abc","site":{"id":"site-1"}}}';
    }

    @IsTest
    static void refreshSucceedsAndPassesAuthToken() {
        TableauMock mock = new TableauMock(200, signInOk(), 202);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        TableauRefreshService.RefreshResult result = TableauRefreshService.refreshTeamDatasource();
        Test.stopTest();

        Assert.isTrue(result.success, '202 응답이면 성공이어야 한다');
        Assert.areEqual('job-1', result.jobId, '작업 ID 를 읽어야 한다');
        Assert.areEqual('tok-abc', mock.refreshAuthHeader, '로그인에서 받은 토큰을 새로고침 호출에 실어야 한다');
        Assert.areEqual(2, mock.calledEndpoints.size(), '로그인 + 새로고침 두 번 호출한다');
        Assert.isTrue(mock.calledEndpoints[1].contains('/datasources/'), '데이터 원본 새로고침 경로여야 한다');
    }

    @IsTest
    static void refreshAcceptsHttp200() {
        Test.setMock(HttpCalloutMock.class, new TableauMock(200, signInOk(), 200));

        Test.startTest();
        TableauRefreshService.RefreshResult result = TableauRefreshService.refreshTeamDatasource();
        Test.stopTest();

        Assert.isTrue(result.success, '200 도 성공으로 본다');
    }

    @IsTest
    static void signInFailureIsReportedWithoutThrowing() {
        // PAT 만료 상황. 화면이 깨지지 않고 안내 문구로 대체되어야 한다(스펙 9장).
        Test.setMock(HttpCalloutMock.class, new TableauMock(401, '{"error":"unauthorized"}', 202));

        Test.startTest();
        TableauRefreshService.RefreshResult result = TableauRefreshService.refreshTeamDatasource();
        Test.stopTest();

        Assert.isFalse(result.success, '로그인 실패는 실패로 표시한다');
        Assert.isTrue(result.message.contains('다음 정시'), '저장은 유지된다는 안내가 있어야 한다');
        Assert.isTrue(result.message.contains('PAT'), '원인을 짚어 줘야 한다');
    }

    @IsTest
    static void missingTokenInResponseIsHandled() {
        Test.setMock(HttpCalloutMock.class, new TableauMock(200, '{"credentials":{}}', 202));

        Test.startTest();
        TableauRefreshService.RefreshResult result = TableauRefreshService.refreshTeamDatasource();
        Test.stopTest();

        Assert.isFalse(result.success, '토큰이 없으면 실패로 처리한다');
    }

    @IsTest
    static void refreshAlreadyRunningIsNotAFailure() {
        // 409 = 같은 데이터 원본에 이미 갱신 작업이 걸려 있다. 실패 문구를 띄우면 사실과 다르다.
        Test.setMock(HttpCalloutMock.class, new TableauMock(200, signInOk(), 409));

        Test.startTest();
        TableauRefreshService.RefreshResult result = TableauRefreshService.refreshTeamDatasource();
        Test.stopTest();

        Assert.isTrue(result.success, '중복 요청은 실패가 아니다');
        Assert.isTrue(result.alreadyRunning, '이미 진행 중임을 알려야 한다');
        Assert.isNull(result.jobId, '새 작업을 걸지 않았으므로 기다릴 작업 ID 가 없다');
        Assert.isTrue(result.message.contains('이미 갱신이 진행 중'), '사용자가 상황을 알 수 있어야 한다');
    }

    /** 로그인 → 작업 상태 조회. 상태 응답 본문을 케이스마다 갈아 끼운다. */
    private class JobMock implements HttpCalloutMock {
        private Integer jobStatus;
        private String jobBody;
        public String jobEndpoint;
        public String jobMethod;

        private JobMock(Integer jobStatus, String jobBody) {
            this.jobStatus = jobStatus;
            this.jobBody = jobBody;
        }

        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            if (req.getEndpoint().contains('/auth/signin')) {
                res.setStatusCode(200);
                res.setBody(signInOk());
                return res;
            }
            jobEndpoint = req.getEndpoint();
            jobMethod = req.getMethod();
            res.setStatusCode(jobStatus);
            res.setBody(jobBody);
            return res;
        }
    }

    @IsTest
    static void jobStatusReportsCompletion() {
        Test.setMock(HttpCalloutMock.class, new JobMock(200, '{"job":{"id":"job-1","finishCode":"0","progress":"100"}}'));

        Test.startTest();
        TableauRefreshService.JobStatus status = TableauRefreshService.getJobStatus('job-1');
        Test.stopTest();

        Assert.isTrue(status.done, 'finishCode 0 이면 끝난 것이다');
        Assert.isTrue(status.success, 'finishCode 0 은 성공이다');
    }

    @IsTest
    static void jobStatusReportsStillRunning() {
        // 큐에 있는 동안에는 finishCode 가 비어서 온다(2026-09-02 실측).
        JobMock mock = new JobMock(200, '{"job":{"id":"job-1","progress":"0"}}');
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        TableauRefreshService.JobStatus status = TableauRefreshService.getJobStatus('job-1');
        Test.stopTest();

        Assert.isFalse(status.done, 'finishCode 가 없으면 아직 진행 중이다');
        Assert.areEqual('GET', mock.jobMethod, '작업 조회는 GET 이다');
        Assert.isTrue(mock.jobEndpoint.contains('/jobs/job-1'), '작업 조회 경로여야 한다');
    }

    @IsTest
    static void jobStatusTreatsMinusOneAsRunning() {
        Test.setMock(HttpCalloutMock.class, new JobMock(200, '{"job":{"id":"job-1","finishCode":"-1"}}'));

        Test.startTest();
        TableauRefreshService.JobStatus status = TableauRefreshService.getJobStatus('job-1');
        Test.stopTest();

        Assert.isFalse(status.done, 'finishCode -1 은 아직 진행 중이다');
    }

    @IsTest
    static void jobStatusReportsFailureWithNotes() {
        Test.setMock(HttpCalloutMock.class, new JobMock(200, '{"job":{"id":"job-1","finishCode":"1","notes":"자격증명 없음"}}'));

        Test.startTest();
        TableauRefreshService.JobStatus status = TableauRefreshService.getJobStatus('job-1');
        Test.stopTest();

        Assert.isTrue(status.done, '실패도 기다림을 멈춰야 한다');
        Assert.isFalse(status.success, 'finishCode 0 이 아니면 실패다');
        Assert.isTrue(status.message.contains('자격증명 없음'), '원인을 그대로 전달해야 한다');
    }

    @IsTest
    static void jobStatusWithoutJobIdDoesNotCallout() {
        Test.startTest();
        TableauRefreshService.JobStatus status = TableauRefreshService.getJobStatus('');
        Test.stopTest();

        Assert.isTrue(status.done, '작업 ID 가 없으면 기다릴 것이 없다');
        Assert.isFalse(status.success, '확인하지 못한 것은 성공이 아니다');
        Assert.areEqual(0, Limits.getCallouts(), '콜아웃 없이 즉시 끝나야 한다');
    }

    @IsTest
    static void jobStatusHandlesHttpError() {
        Test.setMock(HttpCalloutMock.class, new JobMock(500, '{}'));

        Test.startTest();
        TableauRefreshService.JobStatus status = TableauRefreshService.getJobStatus('job-1');
        Test.stopTest();

        Assert.isTrue(status.done, '조회가 안 되면 폴링을 멈춘다 — 화면이 계속 돌면 안 된다');
        Assert.isFalse(status.success, 'HTTP 오류는 성공이 아니다');
    }

    @IsTest
    static void refreshRejectionIsHandled() {
        Test.setMock(HttpCalloutMock.class, new TableauMock(200, signInOk(), 500));

        Test.startTest();
        TableauRefreshService.RefreshResult result = TableauRefreshService.refreshTeamDatasource();
        Test.stopTest();

        Assert.isFalse(result.success, '새로고침 거부는 실패로 표시한다');
        Assert.isNull(result.jobId, '실패 시 작업 ID 는 없다');
    }
}