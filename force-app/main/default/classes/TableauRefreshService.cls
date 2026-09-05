/**
 * Tableau Cloud 추출 새로고침 콜아웃. 팀장 코칭 콘솔에서 목표를 수정한 뒤
 * 대시보드 숫자를 즉시 갱신하기 위해 호출한다 (설계: docs/superpowers/specs/2026-09-02-…, 5.2).
 *
 * 나가는 것은 "새로고침하라"는 명령 한 줄이며 데이터를 싣지 않는다 — 이 기능으로
 * 새로운 데이터 반출 경로가 생기지 않는다(스펙 8장).
 *
 * 인증: Named Credential "Tableau" (PAT). 토큰은 코드·로그 어디에도 남기지 않고
 * Named Credential 병합 필드로만 주입한다. 필요한 org 설정은 클래스 하단 주석 참조.
 *
 * 실패해도 예외를 밖으로 던지지 않는다 — 저장은 이미 끝났고, 대시보드는 다음 정시에
 * 어차피 갱신된다. 시연이 멈추지 않는 것이 최우선(스펙 9장).
 */
public with sharing class TableauRefreshService {

    /** Named Credential 이름. org UI에서 사용자가 생성한다(배포 불가 유형). */
    private static final String NC = 'callout:Tableau';
    private static final String API = '/api/3.19';
    private static final Integer TIMEOUT_MS = 120000;

    /** Tableau Cloud 사이트 contentUrl (docs/67). 비밀값이 아니다. */
    @TestVisible
    private static final String SITE_CONTENT_URL = 'sangyoon0617-2d3b3f4c03';

    /** 팀장 대시보드가 쓰는 데이터 원본 TL_Opp2 (docs/63). */
    @TestVisible
    private static final String DATASOURCE_ID = '878b44bc-e610-4a2d-bb0a-956fec70a339';

    public class RefreshResult {
        @AuraEnabled public Boolean success { get; set; }
        /** 화면에 그대로 보여줄 문구. 실패해도 사용자가 다음 행동을 알 수 있게 쓴다. */
        @AuraEnabled public String message { get; set; }
        @AuraEnabled public String jobId { get; set; }
        /** 이미 다른 갱신 작업이 돌고 있어 새 작업을 걸지 않은 경우. 기다릴 작업 ID 가 없다. */
        @AuraEnabled public Boolean alreadyRunning { get; set; }

        private RefreshResult(Boolean success, String message, String jobId) {
            this.alreadyRunning = false;
            this.success = success;
            this.message = message;
            this.jobId = jobId;
        }
    }

    /**
     * 새로고침 작업의 진행 상태. LWC 가 이 값을 보고 폴링을 멈춘다.
     * 어떤 실패도 예외로 던지지 않는다 — 화면이 멈추지 않는 것이 우선이다.
     */
    public class JobStatus {
        /** true 면 더 기다릴 필요가 없다(성공이든 실패든). */
        @AuraEnabled public Boolean done { get; set; }
        @AuraEnabled public Boolean success { get; set; }
        @AuraEnabled public String message { get; set; }

        private JobStatus(Boolean done, Boolean success, String message) {
            this.done = done;
            this.success = success;
            this.message = message;
        }
    }

    /**
     * 새로고침 작업이 끝났는지 확인한다.
     *
     * 왜 필요한가: `refresh` 는 202 를 즉시 돌려주지만 실제 작업은 큐를 거쳐 뒤늦게 끝난다.
     * 2026-09-02 실측 — 요청 후 **14초 뒤 시작, 28초 뒤 완료**. 고정 대기로는 맞출 수 없어
     * LWC 가 이 메서드를 주기적으로 불러 완료를 기다린다.
     *
     * 폴링 루프를 Apex 안에 두지 않는 이유: 한 트랜잭션의 콜아웃 한도·시간 제한에 걸린다.
     */
    public static JobStatus getJobStatus(String jobId) {
        if (String.isBlank(jobId)) {
            return new JobStatus(true, false, '작업 ID 가 없어 진행 상태를 확인할 수 없습니다.');
        }
        try {
            Session session = signIn();
            HttpResponse res = get(NC + API + '/sites/' + session.siteId + '/jobs/' + jobId, session.token);
            if (res.getStatusCode() != 200) {
                return new JobStatus(true, false, '진행 상태를 확인하지 못했습니다(HTTP ' + res.getStatusCode() + ').');
            }

            Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            Map<String, Object> job = (Map<String, Object>) root.get('job');
            if (job == null) {
                return new JobStatus(true, false, '진행 상태 응답을 읽지 못했습니다.');
            }

            // 진행 중에는 finishCode 가 비어 있거나 -1 로 온다. 완료 시 0 = 성공, 그 외 = 실패.
            String finishCode = job.get('finishCode') == null ? '' : String.valueOf(job.get('finishCode'));
            if (String.isBlank(finishCode) || finishCode == '-1') {
                return new JobStatus(false, false, '갱신 중입니다…');
            }
            if (finishCode == '0') {
                return new JobStatus(true, true, '대시보드를 갱신했습니다.');
            }
            String notes = job.get('notes') == null ? '' : ' (' + String.valueOf(job.get('notes')) + ')';
            return new JobStatus(true, false, '추출 갱신이 실패했습니다' + notes);
        } catch (Exception e) {
            // 상태 확인이 실패해도 저장은 이미 끝났다. 기다림만 멈춘다.
            return new JobStatus(true, false, '진행 상태를 확인하지 못했습니다: ' + e.getMessage());
        }
    }

    /**
     * TL_Opp2 추출을 즉시 새로고침한다. 요청은 즉시 202 로 돌아오고 작업은 뒤이어 큐에서 돈다.
     * 호출 전에 DML이 커밋되어 있어야 한다(같은 트랜잭션에서 DML 뒤 콜아웃은 불가) —
     * 그래서 컨트롤러가 저장과 새로고침을 별개 호출로 나눠 둔다.
     */
    public static RefreshResult refreshTeamDatasource() {
        try {
            Session session = signIn();
            return startRefresh(session);
        } catch (Exception e) {
            // 새로고침 실패가 저장을 되돌리지는 않는다. 사실대로 알리고 정상 종료한다.
            return new RefreshResult(false, '저장되었습니다. 대시보드는 다음 정시에 반영됩니다. (' + e.getMessage() + ')', null);
        }
    }

    // ─── Tableau REST ────────────────────────────────────────────────────

    private class Session {
        String token;
        String siteId;
    }

    /**
     * PAT 로그인. 자격증명은 Named Credential 병합 필드로만 들어간다 —
     * Apex 코드에도, 디버그 로그에도 PAT 값이 남지 않는다.
     * (Named Credential 의 "Allow Merge Fields in HTTP Body" 가 켜져 있어야 한다)
     */
    private static Session signIn() {
        String body =
            '{"credentials":{' +
                '"personalAccessTokenName":"{!$Credential.UserName}",' +
                '"personalAccessTokenSecret":"{!$Credential.Password}",' +
                '"site":{"contentUrl":"' + SITE_CONTENT_URL + '"}' +
            '}}';

        HttpResponse res = send(NC + API + '/auth/signin', body, null);
        if (res.getStatusCode() != 200) {
            throw new TableauRefreshException('Tableau 로그인 실패(HTTP ' + res.getStatusCode() + ') — PAT 만료 여부를 확인하세요.');
        }

        Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        Map<String, Object> creds = (Map<String, Object>) root.get('credentials');
        if (creds == null || creds.get('token') == null) {
            throw new TableauRefreshException('Tableau 로그인 응답에 토큰이 없습니다.');
        }

        Session session = new Session();
        session.token = String.valueOf(creds.get('token'));
        session.siteId = String.valueOf(((Map<String, Object>) creds.get('site')).get('id'));
        return session;
    }

    private static RefreshResult startRefresh(Session session) {
        String path = API + '/sites/' + session.siteId + '/datasources/' + DATASOURCE_ID + '/refresh';
        HttpResponse res = send(NC + path, '{}', session.token);

        // 409 는 같은 데이터 원본에 이미 갱신 작업이 걸려 있다는 뜻이다. 실패가 아니라 중복 요청이며,
        // 진행 중인 그 작업이 끝나면 우리가 원한 결과도 함께 반영된다. 실패로 표시하면 사실과 다르다.
        if (res.getStatusCode() == 409) {
            RefreshResult already = new RefreshResult(true, '이미 갱신이 진행 중입니다. 곧 반영됩니다.', null);
            already.alreadyRunning = true;
            return already;
        }

        // 202 Accepted 가 정상. 200 으로 오는 경우도 있어 둘 다 성공으로 본다.
        if (res.getStatusCode() != 202 && res.getStatusCode() != 200) {
            throw new TableauRefreshException('추출 새로고침 요청 거부(HTTP ' + res.getStatusCode() + ')');
        }
        return new RefreshResult(true, '대시보드를 갱신했습니다.', extractJobId(res.getBody()));
    }

    private static String extractJobId(String responseBody) {
        try {
            Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(responseBody);
            Map<String, Object> job = (Map<String, Object>) root.get('job');
            return job == null ? null : String.valueOf(job.get('id'));
        } catch (Exception ignored) {
            return null; // 작업 ID 는 참고용이라 못 읽어도 성공 판정을 바꾸지 않는다
        }
    }

    private static HttpResponse get(String endpoint, String authToken) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('GET');
        req.setHeader('Accept', 'application/json');
        req.setHeader('X-Tableau-Auth', authToken);
        req.setTimeout(TIMEOUT_MS);
        return new Http().send(req);
    }

    private static HttpResponse send(String endpoint, String body, String authToken) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Accept', 'application/json');
        if (String.isNotBlank(authToken)) {
            req.setHeader('X-Tableau-Auth', authToken);
        }
        req.setTimeout(TIMEOUT_MS);
        req.setBody(body);
        return new Http().send(req);
    }

    public class TableauRefreshException extends Exception {}

    /*
     * ─── org 설정 (사용자가 UI 에서 직접. 배포 불가 유형) ──────────────────
     * Named Credential  이름: Tableau
     *   URL                       https://prod-kr-a.online.tableau.com
     *   Authentication Protocol   Password Authentication
     *   Username                  = Tableau 개인 액세스 토큰(PAT) 이름
     *   Password                  = PAT 시크릿
     *   Generate Authorization Header    끔  (Tableau 는 X-Tableau-Auth 를 쓴다)
     *   Allow Merge Fields in HTTP Body  켬  (이게 꺼져 있으면 로그인 실패)
     *
     * 실배포 전: PAT 는 개인 귀속이라 퇴사 시 중단·로그 귀속 문제가 있다.
     * Connected App(서비스 계정)으로 전환할 것(스펙 8장).
     */
}