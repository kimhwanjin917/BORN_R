/**
 * 팀장 코칭 콘솔 — Tableau 대시보드를 임베드하고, 마크 선택을 받아 조치를 내보낸다.
 * 설계: docs/superpowers/specs/2026-09-02-tableau-lwc-coaching-design.md
 * 스파이크 결과(임베드 경로 확정): docs/68_팀장코칭콘솔_스파이크_결과.md
 *
 * 원칙 — "읽기는 Tableau, 쓰기는 LWC".
 * 이 컴포넌트는 Opportunity 를 단 한 건도 조회하지 않는다. 화면에 이미 보이는 집계값을
 * 선택 컨텍스트로 받아 쓰기 동작(Slack 코칭 / 목표 수정)만 수행한다.
 *
 * 임베드는 JS API v2 다. v3(Embedding API)는 ES 모듈 + 커스텀 엘리먼트 방식인데
 * Lightning Web Security 가 customElements 레지스트리를 격리해 LWC 에서 보이지 않는다
 * (docs/68 전략 A 실패 기록). v2 는 window.tableau 전역 + iframe 직접 생성이라 통과한다.
 */
import { LightningElement, track } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import TABLEAU_API from '@salesforce/resourceUrl/TableauEmbeddingApi';
import sendCoaching from '@salesforce/apex/TeamCoachingController.sendCoaching';
import resolveRmId from '@salesforce/apex/TeamCoachingController.resolveRmId';

const HOST = 'https://prod-kr-a.online.tableau.com';
const SITE = 'sangyoon0617-2d3b3f4c03';
const API_SCRIPT = TABLEAU_API + '/tableau-2.9.2.min.js';

/**
 * `:refresh=yes` 로 서버 뷰 캐시를 우회하면 추출 갱신 직후에도 최신 숫자가 보이지만,
 * 매번 새로 렌더하느라 화면이 눈에 띄게 느려진다 — 2026-09-02 사용자 판단으로 빼 둔다.
 * 데이터 갱신 후 옛 숫자가 보이면 그때 다시 붙인다.
 */
const viewUrl = (contentUrl) => HOST + '/t/' + SITE + '/views/' + contentUrl;

/**
 * 원본 워크북 `근본팀장` 하나만 쓴다 — 퍼널·리스크존까지 들어 있는 전체 화면(docs/67).
 *
 * 압축본 `근본팀장콘솔`(1600×760)과 전환 버튼을 두는 안도 만들어 봤으나,
 * 화면이 오가는 것 자체가 시연에서 어색해 2026-09-02 사용자 결정으로 전체 화면 하나로 고정했다.
 * 압축본은 게시된 채 남아 있고 지금은 쓰지 않는다(67_assets/gen_kbt_console.ps1).
 *
 * 대시보드 비율(1440:1320)대로 컨테이너를 잡는다. 화면 높이에 맞춰 자르면 Tableau 가
 * 축소율 0.57 로 줄여 버려 좌우가 여백이 되고 글자도 절반이 된다 —
 * Tableau 는 고정 크기 대시보드를 `min(가로비, 세로비)` 로 **축소만** 하기 때문이다(확대는 안 한다).
 * 그래서 원본 크기로 크게 띄우고 아래 두 카드(퍼널·리스크존)는 스크롤로 본다.
 */
const VIEW = {
    url: viewUrl('_17882524383710/RM'), // 근본팀장 (원본)
    w: 1600,
    h: 1320,
    fitToScreen: false // 비율대로 크게. 퍼널·리스크존은 스크롤해서 본다
};

/**
 * 페이로드 키는 워크북의 필드 캡션이라 표기가 흔들릴 수 있다.
 * docs/68 인수인계는 필드명 RMId 로, 성공 예시는 캡션 "RM User Id" 로 적혀 있어
 * 어느 쪽이 올지 확정되지 않았다 → 양쪽 다 받는다.
 * 아예 안 오는 시트도 있다(`c1_quota`/`c1_fc`/`c1_won`). 그때만 이름으로 찾되,
 * **정확히 한 명일 때만** 쓴다(TeamCoachingController.resolveRmId). 애매하면 조치를 막는다.
 */
const KEYS_RM_ID = ['RMId', 'RM User Id', 'RM Id', 'RM UserId'];
const KEYS_RM_NAME = ['RM', '담당 RM', 'RM 이름'];
const KEYS_STAGE = ['단계명', '단계'];

/** 화면에 보여줄 값이 아닌 내부 계산 보조 필드. 코칭 문구에 섞이면 읽기 나빠진다. */
const METRIC_NOISE = ['순서', '강조'];

/**
 * 지표를 읽는 순서로 고정한다.
 *
 * 워크북이 주는 순서는 시트 배치 순이라 `진행 중 → 목표 → 리스크 → 파이프라인 → 달성`
 * 처럼 뒤죽박죽이다. 목표부터 달성·달성률로 이어지는 순서가 사람이 읽는 순서다.
 * 여기 없는 지표는 뒤에 그대로 붙인다 — 워크북이 새 값을 보내도 조용히 사라지지 않게.
 *
 * `label` 은 화면 표기. 값에 이미 `억` 이 붙어 있어 `(억)` 은 뗀다.
 */
/**
 * 마크 하나에는 그 시트의 값만 실려 온다 — 달성률 칸을 누르면 달성률뿐이다.
 * 한 번의 클릭으로 RM 전체 현황을 보여주려고, 화면에 이미 떠 있는 이 시트들에서
 * 같은 RM 의 행을 읽어 합친다.
 *
 * 스펙 2.3 은 `getSummaryDataAsync` 를 "숫자 출처가 흐려진다"는 이유로 폐기했었다.
 * 2026-09-02 되살리기로 한 근거: **같은 뷰·같은 추출에서 읽으므로 왼쪽 화면의 숫자 그대로**이고,
 * Salesforce 를 조회하는 것이 아니라 Opportunity 접근 금지 원칙도 그대로 지켜진다.
 * 목표 수정·자동 새로고침을 걷어낸 뒤라 "실시간처럼 보일" 여지도 없다.
 */
const SUMMARY_SHEETS = ['c1_quota', 'c1_fc', 'c1_won', 'c1_attain'];

/**
 * 퍼널에서 단계를 고르면 워크북의 필터 액션이 리스크존을 그 단계로 걸러 준다.
 * 그때 **차트에 실제로 그려진 딜**을 세어 보여준다 — 화면의 동그라미와 숫자가 어긋나지 않게.
 *
 * 2026-09-02 리스크 재설계로 차트의 숨은 필터를 없앴다 — 이제 해석 줄·차트·KPI·이 패널이 같은 수를 말한다.
 * 그래도 패널은 차트에 그려진 행을 직접 세는 방식을 유지한다. 나중에 워크북에 필터가 생겨도 어긋나지 않게.
 *
 * 위험 신호 수 열은 워크북 정의상 마감 경과·무접촉 3주·평균 2배 체류 중 해당 개수(0~3)다.
 *
 * 필터 적용 시점과 읽는 시점이 겹치므로, 값이 바뀔 때까지 몇 번 다시 읽는다.
 * 끝내 안 바뀌면 실제로 같은 값일 수 있으니 마지막에 읽은 것을 쓴다.
 */
const RISK_SHEET = 'c4_bub';
// 2026-09-02 리스크 재설계 후 차트 열은 `위험 신호 수`(0~3). 2개 이상이 위험, 1개가 주의. 옛 `심각도` 도 받아 둔다.
const RISK_SEVERITY_KEYS = ['위험 신호 수', '심각도'];
const RISK_HIGH_MIN = 2;
const RISK_RETRY = 4;
const RISK_RETRY_MS = 350;

const METRIC_ORDER = [
    { match: '목표', label: '목표' },
    { match: '누적 달성', label: '누적 달성' },
    { match: '달성률', label: '달성률' },
    { match: 'Forecast', label: 'Forecast' },
    { match: '평균 체류', label: '평균 체류' },
    { match: '진행 중', label: '진행 중' },
    { match: '파이프라인', label: '파이프라인' },
    { match: '리스크', label: '리스크 거래' }
];

/**
 * Tableau JS API v2 는 크기를 px 문자열로만 받으므로 CSS 가 아니라 JS 에서 계산한다.
 */
const MIN_VIZ_PX = 560;

/** onFirstInteractive 가 끝내 안 오는 경우에도 스피너가 영원히 돌지 않게 하는 상한. */
const VIZ_LOAD_TIMEOUT_MS = 20000;

export default class TeamCoachingConsole extends LightningElement {
    @track selection = null; // { rmId, rmName, stage, metrics: [{key,label,value}], multi }
    @track draft = '';

    /** 퍼널 단계를 골랐을 때만 채워진다 — { high, medium, total }. */
    @track stageRisk = null;

    vizError = '';
    vizReady = false;
    busy = false;
    busyMessage = '';

    /** 화면을 떠나면 배경 작업을 멈춘다. */
    destroyed = false;

    /**
     * 선택이 바뀔 때마다 올린다. 이름 조회와 요약 읽기가 각각 비동기로 돌아오는데,
     * 늦게 온 응답이 새 선택을 덮어쓰면 안 된다.
     */
    selectionToken = 0;

    viz;
    resizeObserver;
    lastVizWidth = 0;
    lastRiskSignature = '';
    scriptLoaded = false;
    vizStarted = false;

    // ─── 라이프사이클 ────────────────────────────────────────────────────

    renderedCallback() {
        // 기본 textarea 라 값을 직접 넣어 준다. 같은 값이면 건드리지 않는다(입력 중 커서가 튄다).
        const draftEl = this.template.querySelector('textarea.draft');
        if (draftEl && draftEl.value !== this.draft) {
            draftEl.value = this.draft;
        }

        // 뷰 컨테이너는 한 번만 채운다. 재렌더마다 Viz 를 만들면 iframe 이 계속 쌓인다.
        if (this.vizStarted) {
            return;
        }
        const box = this.template.querySelector('.viz-box');
        if (!box) {
            return;
        }
        this.vizStarted = true;
        // 이 시점의 clientWidth 는 Lightning 페이지 폭이 아직 안 잡혀 절반쯤으로 나온다(실측 878/1556).
        // 그대로 쓰면 Tableau 축소율이 0.6 으로 떨어져 좌우가 여백투성이가 된다. 한 프레임 미룬다.
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        requestAnimationFrame(() => this.initViz(box));
    }

    disconnectedCallback() {
        this.destroyed = true;
        if (this.resizeObserver) {
            this.resizeObserver.disconnect();
            this.resizeObserver = null;
        }
        this.disposeViz();
    }

    // ─── Tableau 임베드 ──────────────────────────────────────────────────

    async initViz(box) {
        try {
            if (!this.scriptLoaded) {
                await loadScript(this, API_SCRIPT);
                this.scriptLoaded = true;
            }
            if (!window.tableau || !window.tableau.Viz) {
                throw new Error('Tableau JS API 전역(window.tableau)이 노출되지 않았습니다.');
            }
            await this.createViz(box);
            this.watchResize(box);
        } catch (e) {
            // CSP 신뢰 사이트 누락·정적 리소스 문제 등. 화면을 죽이지 않고 직접 링크로 대체한다(스펙 9장).
            this.vizError = this.describe(e);
            this.vizStarted = false;
        }
    }

    /**
     * Viz 를 만든다. onFirstInteractive 로 완료를 알린다.
     */
    createViz(box) {
        // 높이를 넣기 전에 폭을 재야 한다 — box 는 이미 배치돼 있어 clientWidth 가 나온다.
        const height = this.vizHeightPx(box);
        box.style.height = height;

        return new Promise((resolve) => {
            let settled = false;
            const done = () => {
                if (!settled) {
                    settled = true;
                    resolve();
                }
            };
            this.viz = new window.tableau.Viz(box, VIEW.url, {
                hideTabs: true,
                // 툴바는 감춘다. 세로 공간을 돌려받고, 다운로드·공유 진입점도 함께 사라진다(스펙 8장).
                hideToolbar: true,
                width: '100%',
                height: height,
                onFirstInteractive: () => {
                    this.onVizReady();
                    done();
                }
            });
            // 렌더가 끝나지 않아도 스피너가 영원히 돌지는 않게 한다.
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(done, VIZ_LOAD_TIMEOUT_MS);
        });
    }

    onVizReady() {
        this.vizReady = true;
        try {
            this.viz.addEventListener(window.tableau.TableauEventName.MARKS_SELECTION, (ev) =>
                this.onMarksSelection(ev)
            );
        } catch (e) {
            this.vizError = '뷰는 떴지만 선택 이벤트를 붙이지 못했습니다: ' + this.describe(e);
        }
    }

    disposeViz() {
        try {
            if (this.viz) {
                this.viz.dispose();
            }
        } catch (e) {
            // 이미 정리된 경우. 화면을 떠나는 중이라 알릴 대상이 없다.
        }
        this.viz = null;
    }

    onMarksSelection(ev) {
        ev.getMarksAsync()
            .then((marks) => this.applyMarks(marks))
            .catch((e) => {
                this.vizError = '선택 내용을 읽지 못했습니다: ' + this.describe(e);
            });
    }

    /**
     * 마크 → 선택 컨텍스트.
     * 선택을 해제하면 마크 0건 이벤트가 온다(docs/68) → 패널을 비운다.
     */
    applyMarks(marks) {
        const rows = (marks || []).map((mark) => {
            const rec = {};
            mark.getPairs().forEach((pair) => {
                rec[pair.fieldName] = pair.formattedValue;
            });
            return rec;
        });

        if (!rows.length) {
            this.clearSelection();
            return;
        }

        // 여러 칸을 한꺼번에 선택해도 조치 대상은 한 명이어야 한다. 첫 마크를 기준으로 삼는다.
        const row = rows[0];
        const rmName = this.pick(row, KEYS_RM_NAME);
        const selection = {
            rmId: this.pick(row, KEYS_RM_ID),
            rmName,
            // 퍼널은 RM 없이 단계만 온다. 단계 캡션이 뭘로 오든 잡히도록 첫 차원 값으로 물러선다.
            stage: this.pick(row, KEYS_STAGE) || (rmName ? '' : this.firstDimension(row)),
            metrics: this.toMetrics(row),
            multi: rows.length > 1 ? rows.length : 0
        };

        this.selectionToken++;
        const token = this.selectionToken;
        this.stageRisk = null;

        if (!rmName) {
            // 팀 전체 단계 지표. 이름 조회도, 다른 시트 합치기도 대상이 없다.
            // 보낼 대상이 없으므로 초안도 만들지 않는다.
            this.selection = selection;
            this.draft = '';
            this.loadStageRisk(token);
            return;
        }

        // 이 시트에는 RMId 가 실려 오지 않는다(워크북을 동결해 둬서 넣을 수 없다).
        // 이름으로 찾는다 — 정확히 한 명일 때만 Apex 가 돌려준다.
        const rmIdPromise = selection.rmId
            ? Promise.resolve(selection.rmId)
            : this.resolveByName(selection, token);

        // 마크에는 그 시트 값만 온다. 나머지 지표는 화면의 다른 시트에서 읽어 채운다.
        //
        // 여기서 selection 을 먼저 넣으면 패널이 마크 값만으로 한 번 그려지고, 잠시 뒤 합쳐진
        // 지표로 헤더·타일이 끼어들며 화면이 밀린다(2026-09-02 사용자 지적 "버퍼링").
        // 그래서 합치기가 끝난 뒤 한 번에 넣는다 — 대기 표시는 두지 않는다(시연 방침).
        //
        // 이름 조회도 같이 기다린다. rmId 가 늦게 오면 그 사이 `blockedReason` 경고 박스가
        // 떴다가 사라지면서 아래 내용이 위로 당겨진다 — 그것도 밀림으로 보인다.
        this.showRmSelection(selection, token, rmIdPromise);
    }

    /**
     * 고른 단계의 리스크 건수를 읽어 온다.
     * 워크북이 필터를 적용하는 데 시간이 걸려, 값이 바뀔 때까지 몇 번 다시 읽는다.
     */
    async loadStageRisk(token) {
        const before = this.lastRiskSignature;
        let counted = null;
        try {
            for (let i = 0; i < RISK_RETRY; i++) {
                // eslint-disable-next-line no-await-in-loop
                await this.sleep(RISK_RETRY_MS);
                if (this.destroyed || token !== this.selectionToken) {
                    return;
                }
                // eslint-disable-next-line no-await-in-loop
                counted = await this.countPlottedRisk();
                if (counted && counted.signature !== before) {
                    break; // 필터가 반영됐다
                }
            }
        } catch (e) {
            return; // 못 읽으면 리스크 칸을 그냥 안 보여준다
        }

        if (!counted || token !== this.selectionToken) {
            return;
        }
        this.lastRiskSignature = counted.signature;
        if (!counted.total) {
            this.stageRisk = null;
            return;
        }
        this.stageRisk = {
            split: counted.split,
            high: counted.split ? counted.high + '건' : '',
            medium: counted.split ? counted.medium + '건' : '',
            total: counted.total + '건'
        };
    }

    /** 리스크존 차트에 실제로 그려진 딜을 위험도별로 센다. 현재 필터가 적용된 상태로 온다. */
    async countPlottedRisk() {
        if (!this.viz) {
            return null;
        }
        const dashboard = this.viz.getWorkbook().getActiveSheet();
        if (!dashboard || typeof dashboard.getWorksheets !== 'function') {
            return null;
        }
        const sheet = dashboard
            .getWorksheets()
            .find((candidate) => this.sheetName(candidate) === RISK_SHEET);
        if (!sheet) {
            return null;
        }

        const table = await sheet.getSummaryDataAsync({ maxRows: 500 });
        const columns = table.getColumns().map((column) =>
            typeof column.getFieldName === 'function' ? column.getFieldName() : column.fieldName
        );
        // 열 이름이 `심각도` 로 올지 `집계(심각도)` 로 올지 확정할 수 없다 — 포함 여부로 찾는다.
        // 정확히 일치를 요구했다가 열을 못 찾아 HIGH 가 전부 0 으로 세어진 적이 있다(2026-09-02).
        const severityIndex = columns.findIndex(
            (name) => RISK_SEVERITY_KEYS.some((key) => String(name).indexOf(key) >= 0)
        );
        const rows = table.getData();
        const total = rows.length;
        if (severityIndex < 0) {
            // 위험도를 못 읽으면 나누지 않는다. 틀린 구분을 보여주느니 합계만 말한다.
            return { split: false, total, signature: total + ':?' };
        }

        let high = 0;
        rows.forEach((cells) => {
            // 값이 '2' 로 올지 '2.0' 으로 올지 모른다. 숫자로 견준다.
            if (Number(this.cellText(cells[severityIndex]).replace(/[^0-9.-]/g, '')) >= RISK_HIGH_MIN) {
                high++;
            }
        });
        return { split: true, high, medium: total - high, total, signature: total + ':' + high };
    }

    /** 이름으로 RM 을 특정한다. 못 찾으면 rmId 가 비어 있어 조치 버튼이 잠긴 채로 남는다. */
    resolveByName(selection, token) {
        return resolveRmId({ rmName: selection.rmName })
            .then((rmId) => {
                // 결과를 여기서 화면에 반영하면 안 된다. 이 시점의 `this.selection` 은 아직
                // 이전 선택이라, 그 RM 카드에 새 rmId 가 붙어 엉뚱한 사람에게 보내질 수 있다.
                // 값만 돌려주고, 화면 반영은 showRmSelection 이 한 번에 한다.
                return !rmId || token !== this.selectionToken ? null : rmId;
            })
            .catch(() => {
                // 조회 실패는 조용히 넘긴다. 버튼이 잠긴 채로 남고 사유가 화면에 이미 떠 있다.
                return null;
            });
    }

    clearSelection() {
        // 토큰을 올려야 앞서 나간 비동기 응답(이름 조회·요약 읽기)이 뒤늦게 와서 패널을 되살리지 못한다.
        this.selectionToken++;
        this.selection = null;
        this.draft = '';
        this.stageRisk = null;
    }

    // ─── 코칭 문구 ───────────────────────────────────────────────────────

    /**
     * 초안은 페이로드에 실제로 온 값만 쓴다.
     * 스펙 5.1 예시 문구에는 팀 평균이 들어가지만 페이로드에 오지 않으므로 넣지 않는다 —
     * 화면에 없는 숫자를 지어내면 그 문구가 그대로 RM 에게 발송된다.
     */
    buildDraft(selection) {
        const dwell = this.metricValue(selection, '체류');
        let head;
        if (selection.stage && dwell) {
            head = `${selection.rmName} 님, ${selection.stage} 단계 평균 체류가 ${dwell}로 확인됩니다.`;
        } else if (selection.stage) {
            head = `${selection.rmName} 님, ${selection.stage} 단계 현황 확인 부탁드립니다.`;
        } else {
            head = `${selection.rmName} 님, 현재 파이프라인 현황 공유 부탁드립니다.`;
        }

        const lines = selection.metrics.map((metric) => `- ${metric.label}: ${metric.value}`);
        const body = lines.length ? ['', ...lines] : [];
        return [head, ...body, '', '진행 상황 공유 부탁드립니다.'].join('\n');
    }

    handleDraftChange(event) {
        this.draft = event.target.value;
    }

    async handleSend() {
        if (!this.canAct) {
            return;
        }
        if (!this.draft || !this.draft.trim()) {
            this.toast('보낼 메시지가 비어 있습니다.', '', 'warning');
            return;
        }
        this.setBusy('Slack 으로 보내는 중…');
        try {
            const result = await sendCoaching({
                rmUserId: this.selection.rmId,
                rmName: this.selection.rmName,
                stageLabel: this.selection.stage,
                message: this.draft
            });
            // Slack 이 실패해도 Task 는 남는다. 부분 성공을 사실대로 표시한다(스펙 9장).
            this.toast(
                result.summary,
                result.channelName ? '채널: #' + result.channelName : '',
                result.slackSent ? 'success' : 'warning'
            );
        } catch (e) {
            this.toast('코칭 발송에 실패했습니다.', this.describe(e), 'error');
        } finally {
            this.clearBusy();
        }
    }



    /** RM 이 실려 온 선택인가. 퍼널처럼 단계만 오는 마크는 조치 대상이 없다. */
    get hasRm() {
        return !!(this.selection && this.selection.rmName);
    }

    /** 패널 제목 — RM 이름, 없으면 단계명. */
    get headTitle() {
        if (!this.selection) {
            return '';
        }
        return this.selection.rmName || this.selection.stage || '선택한 항목';
    }

    /** RM 이름이 제목을 차지했을 때만 단계를 뱃지로 따로 보인다. */
    get showStageBadge() {
        return !!(this.selection && this.selection.rmName && this.selection.stage);
    }

    get hasSelection() {
        return !!this.selection;
    }

    /** RM User Id 가 없으면 조치를 막는다. 이름 문자열로 추측 매칭하지 않는다(스펙 4·9장). */
    get canAct() {
        return !!(this.selection && this.selection.rmId) && !this.busy;
    }

    get actionsDisabled() {
        return !this.canAct;
    }

    get blockedReason() {
        if (!this.selection || this.selection.rmId || !this.selection.rmName) {
            return '';
        }
        return '이 RM 을 특정하지 못했습니다. 이름이 겹치거나 사용자를 찾을 수 없습니다.';
    }

    /**
     * 선택한 마크를 요약 화면으로 바꾼다. 클릭한 시트에 따라 오는 값이 다르다:
     *   팀원 KPI → 목표·달성·달성률·Forecast·진행 중·파이프라인·리스크 (7개)
     *   히트맵    → 평균 체류 (1개)
     * 그래서 성과 요약과 병목 카드 두 모습으로 갈린다.
     *
     * **없는 값은 만들지 않는다.** 진행 바도 화면에 온 `"62%"` 를 읽어 그릴 뿐이고,
     * 못 읽으면 바를 감추고 숫자만 남긴다.
     */
    get summary() {
        if (!this.selection) {
            return null;
        }
        const metrics = this.selection.metrics || [];
        const by = (label) => metrics.find((metric) => metric.label === label);

        const attain = by('달성률');
        const dwell = by('평균 체류');
        const tiles = [
            { key: 'quota', label: '목표', metric: by('목표') },
            { key: 'won', label: '누적 달성', metric: by('누적 달성') },
            { key: 'forecast', label: 'Forecast', metric: by('Forecast') },
            { key: 'pipe', label: '파이프라인', metric: by('파이프라인') }
        ]
            .filter((tile) => tile.metric)
            .map((tile) => ({ key: tile.key, label: tile.label, value: tile.metric.value }));

        const chips = [];
        const open = by('진행 중');
        const risk = by('리스크 거래');
        // 정의는 워크북 계산식 그대로다. 시연에서 "기준이 뭔가" 라는 질문이 나오는 자리라 화면에 붙여 둔다.
        if (open) {
            chips.push({
                key: 'open',
                label: '진행 중',
                value: open.value,
                className: 'chip',
                hint: '아직 종결되지 않은 거래 (수주·실주 제외)'
            });
        }
        if (risk) {
            chips.push({
                key: 'risk',
                label: '리스크',
                value: risk.value,
                className: 'chip chip--danger',
                hint: '마감 경과 · 3주 무접촉 · 단계 평균 2배 체류 — 둘 이상이면 위험, 하나면 주의'
            });
        }

        // 위에서 쓴 값 외에 워크북이 새로 보내는 지표가 있으면 라벨-값 줄로 그대로 붙인다.
        const known = ['달성률', '평균 체류', '목표', '누적 달성', 'Forecast', '파이프라인', '진행 중', '리스크 거래'];
        const extras = metrics.filter((metric) => known.indexOf(metric.label) < 0);

        return {
            attainText: attain ? attain.value : '',
            attainPercent: attain ? this.toPercent(attain.value) : null,
            dwell: dwell ? this.toDwell(dwell.value) : null,
            tiles,
            chips,
            extras
        };
    }

    /** 체류일은 "어느 단계" 인지가 붙어야 뜻이 통한다. */
    get dwellLabel() {
        const stage = this.selection && this.selection.stage;
        return stage ? stage + ' 단계 평균 체류' : '평균 체류';
    }

    get hasKpiSummary() {
        const summary = this.summary;
        return !!(summary && (summary.attainText || summary.tiles.length));
    }

    get hasStageSummary() {
        const summary = this.summary;
        return !!(summary && summary.dwell);
    }

    /** `"62%"` → 62. 못 읽으면 null 이고, 그러면 바를 그리지 않는다. */
    toPercent(text) {
        const matched = String(text || '').match(/-?\d+(\.\d+)?/);
        if (!matched) {
            return null;
        }
        return Math.max(0, Math.min(100, Number(matched[0])));
    }

    get attainBarStyle() {
        const summary = this.summary;
        return summary && summary.attainPercent !== null ? `width: ${summary.attainPercent}%;` : 'width: 0;';
    }

    get showAttainBar() {
        const summary = this.summary;
        return !!(summary && summary.attainPercent !== null);
    }

    /**
     * `"23일"` → 심각도까지 붙인다.
     * 21일 기준은 제가 정한 값이 아니라 워크북 계산식(`DwellDays >= 21` = 정체)과 같다.
     */
    toDwell(text) {
        const days = this.toDays(text);
        let tone = 'ok';
        let note = '';
        if (days !== null && days >= 21) {
            tone = 'danger';
            note = '21일 이상 정체 구간';
        } else if (days !== null && days >= 14) {
            tone = 'warn';
            note = '체류가 길어지는 중';
        }
        return { text: String(text || ''), tone, note, className: 'bignum bignum--' + tone };
    }

    toDays(text) {
        const matched = String(text || '').match(/\d+/);
        return matched ? Number(matched[0]) : null;
    }

    get multiNote() {
        return this.selection && this.selection.multi
            ? `${this.selection.multi}개 마크가 선택되어 첫 번째 항목 기준으로 표시합니다.`
            : '';
    }

    get vizUrl() {
        return VIEW.url;
    }

    // ─── 유틸 ────────────────────────────────────────────────────────────

    /** 컨테이너 실제 폭. clientWidth 는 소수점을 버려 종종 1px 작게 나온다. */
    vizWidthPx(box) {
        const rect = box ? box.getBoundingClientRect() : null;
        return rect && rect.width ? Math.round(rect.width) : 0;
    }

    /**
     * 대시보드 비율로 높이를 내되, **화면에 남은 높이를 넘지 않게** 자른다.
     * 비율만 쓰면 창이 넓을 때 뷰가 화면 밖으로 나가 스크롤이 생긴다 — 한 화면에 담는 것이 목적이다.
     */
    vizHeightPx(box) {
        const width = this.vizWidthPx(box);
        if (!width) {
            return Math.max(MIN_VIZ_PX, Math.round((window.innerHeight || 900) - 200)) + 'px';
        }
        return Math.max(MIN_VIZ_PX, this.fitHeight(box, width)) + 'px';
    }

    /** 비율 높이와 "화면에 남은 높이" 중 작은 쪽. */
    fitHeight(box, width) {
        // Tableau 는 고정 크기 대시보드를 축소만 한다(확대는 안 한다). 폭이 VIEW.w 를 넘으면
        // 뷰는 원본 크기에서 멈추는데 비율 높이만 계속 커져 아래가 빈 채로 스크롤이 길어진다.
        // 그래서 원본 높이를 상한으로 건다.
        const ratio = Math.min(Math.round((width * VIEW.h) / VIEW.w), VIEW.h);
        if (!VIEW.fitToScreen) {
            return ratio; // 전체 화면 모드는 스크롤을 감수하고 크게 띄운다
        }
        const rect = box ? box.getBoundingClientRect() : null;
        const room = rect ? Math.round((window.innerHeight || 900) - rect.top - 10) : 0;
        return room > MIN_VIZ_PX ? Math.min(ratio, room) : ratio;
    }

    /**
     * 창 크기가 바뀌면 뷰도 따라가게 한다.
     * 이게 없으면 최대화·창 조절 후 Tableau 축소율이 옛 폭에 묶여 좌우 여백이 다시 생긴다.
     */
    watchResize(box) {
        if (this.resizeObserver || typeof ResizeObserver === 'undefined') {
            return;
        }
        this.resizeObserver = new ResizeObserver(() => {
            const width = this.vizWidthPx(box);
            if (!width || Math.abs(width - this.lastVizWidth) < 24) {
                return; // 미세한 흔들림에는 반응하지 않는다
            }
            this.lastVizWidth = width;
            const height = Math.max(MIN_VIZ_PX, this.fitHeight(box, width));
            box.style.height = height + 'px';
            try {
                if (this.viz) {
                    this.viz.setFrameSize(width, height);
                }
            } catch (e) {
                // 뷰가 아직 준비 전이거나 이미 정리된 경우. 다음 리사이즈에 다시 맞춘다.
            }
        });
        this.resizeObserver.observe(box);
        this.lastVizWidth = this.vizWidthPx(box);
    }

    /** RM 없이 오는 마크(퍼널)에서 제목으로 쓸 첫 차원 값. 집계·식별자 열은 건너뛴다. */
    firstDimension(row) {
        const key = Object.keys(row).find(
            (name) =>
                name.indexOf('집계(') !== 0 &&
                KEYS_RM_ID.indexOf(name) < 0 &&
                KEYS_RM_NAME.indexOf(name) < 0
        );
        return key ? String(row[key]).trim() : '';
    }

    pick(row, keys) {
        for (const key of keys) {
            const value = row[key];
            if (value !== undefined && value !== null && String(value).trim() !== '') {
                return String(value).trim();
            }
        }
        return '';
    }

    /**
     * "집계(평균 체류)" → { label: '평균 체류', value: '32일' }
     * 보조 필드를 걸러내고 METRIC_ORDER 순서로 세운다. 목록에 없는 것은 뒤에 붙인다.
     */
    toMetrics(row) {
        const raw = Object.keys(row)
            .filter((key) => key.indexOf('집계(') === 0)
            .map((key) => ({
                key,
                label: key.replace('집계(', '').replace(/\)$/, ''),
                value: row[key]
            }));
        return this.orderMetrics(raw);
    }

    /**
     * 보조 필드를 걸러내고 METRIC_ORDER 순서로 세운다. 같은 지표가 여러 시트에서 오면 첫 값만 쓴다.
     * 목록에 없는 것은 뒤에 그대로 붙인다 — 워크북이 새 값을 보내도 조용히 사라지지 않게.
     */
    orderMetrics(raw) {
        const usable = raw.filter(
            (metric) =>
                metric.value !== undefined &&
                metric.value !== null &&
                String(metric.value).trim() !== '' &&
                !METRIC_NOISE.some((noise) => metric.label.indexOf(noise) >= 0)
        );

        const ordered = [];
        const taken = [];
        METRIC_ORDER.forEach((spec) => {
            const hit = usable.find((metric) => metric.label.indexOf(spec.match) >= 0);
            if (hit) {
                ordered.push({ key: hit.key, label: spec.label, value: hit.value });
                taken.push(hit.key);
            }
        });
        usable.forEach((metric) => {
            const known = METRIC_ORDER.some((spec) => metric.label.indexOf(spec.match) >= 0);
            if (!known && taken.indexOf(metric.key) < 0) {
                ordered.push(metric);
            }
        });
        return ordered;
    }

    /**
     * 화면에 떠 있는 시트들에서 이 RM 의 행을 읽어 마크 값과 합친다.
     * 못 읽으면 조용히 넘어간다 — 마크에서 온 값만으로도 화면은 성립한다.
     */
    async showRmSelection(selection, token, rmIdPromise) {
        // 시트 구성이 바뀌었거나 API 가 응답하지 않으면 마크 값만으로도 화면은 성립한다.
        const [extra, rmId] = await Promise.all([
            this.readRmMetrics(selection.rmName).catch(() => []),
            rmIdPromise
        ]);

        // 읽는 사이 다른 마크를 골랐으면 이 결과는 버린다.
        if (token !== this.selectionToken) {
            return;
        }

        let final = selection;
        if (extra.length) {
            final = { ...final, metrics: this.orderMetrics([...(final.metrics || []), ...extra]) };
        }
        if (!final.rmId && rmId) {
            final = { ...final, rmId };
        }
        this.selection = final;
        this.draft = this.buildDraft(final);
    }

    async readRmMetrics(rmName) {
        if (!this.viz || !rmName) {
            return [];
        }
        const dashboard = this.viz.getWorkbook().getActiveSheet();
        if (!dashboard || typeof dashboard.getWorksheets !== 'function') {
            return [];
        }
        const sheets = dashboard
            .getWorksheets()
            .filter((sheet) => SUMMARY_SHEETS.indexOf(this.sheetName(sheet)) >= 0);

        const out = [];
        for (const sheet of sheets) {
            // eslint-disable-next-line no-await-in-loop
            const table = await sheet.getSummaryDataAsync({ ignoreSelection: true, maxRows: 200 });
            out.push(...this.rowMetrics(table, rmName, this.sheetName(sheet)));
        }
        return out;
    }

    sheetName(sheet) {
        return typeof sheet.getName === 'function' ? sheet.getName() : sheet.name;
    }

    /** 요약 데이터에서 이 RM 의 행을 찾아 라벨-값으로 편다. 컬럼명은 캡션(`누적 달성(억)`)으로 온다. */
    rowMetrics(table, rmName, sheetKey) {
        const columns = table.getColumns().map((column) =>
            typeof column.getFieldName === 'function' ? column.getFieldName() : column.fieldName
        );
        const nameIndex = columns.findIndex((name) => KEYS_RM_NAME.indexOf(name) >= 0);
        if (nameIndex < 0) {
            return [];
        }
        const row = table.getData().find((cells) => this.cellText(cells[nameIndex]) === rmName);
        if (!row) {
            return [];
        }
        return columns
            .map((name, index) => ({
                key: sheetKey + ':' + name,
                label: name.replace(/\(억\)$/, '').trim(),
                value: this.cellText(row[index]),
                skip: index === nameIndex || KEYS_RM_ID.indexOf(name) >= 0
            }))
            .filter((metric) => !metric.skip)
            .map((metric) => ({ key: metric.key, label: metric.label, value: metric.value }));
    }

    cellText(cell) {
        if (cell === undefined || cell === null) {
            return '';
        }
        if (cell.formattedValue !== undefined) {
            return String(cell.formattedValue);
        }
        return cell.value === undefined ? String(cell) : String(cell.value);
    }

    metricValue(selection, labelPart) {
        const hit = selection.metrics.find((metric) => metric.label.indexOf(labelPart) >= 0);
        return hit ? hit.value : '';
    }

    sleep(ms) {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        return new Promise((resolve) => setTimeout(resolve, ms));
    }

    setBusy(message) {
        this.busy = true;
        this.busyMessage = message;
    }

    clearBusy() {
        this.busy = false;
        this.busyMessage = '';
    }

    describe(e) {
        if (!e) {
            return '';
        }
        if (e.body && e.body.message) {
            return e.body.message;
        }
        return e.message || String(e);
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant, mode: 'dismissable' }));
    }
}