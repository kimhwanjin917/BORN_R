/**
 * 스파이크 — 폐기 대상 코드. 목적은 "답"이지 재사용이 아니다.
 * 검증 질문 (docs/superpowers/specs/2026-09-02-tableau-lwc-coaching-design.md 11장)
 *   1) LWC 안에서 근본팀장 뷰가 렌더링되는가
 *   2) 마크를 클릭하면 선택 이벤트가 LWC JS까지 도달하는가
 *   3) 페이로드에서 RM·단계 값을 읽을 수 있는가
 * 전략 3개를 각각 눌러보고 어디까지 되는지 로그로 확인한다.
 */
import { LightningElement, track } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import TABLEAU_API from '@salesforce/resourceUrl/TableauEmbeddingApi';

const HOST = 'https://prod-kr-a.online.tableau.com';
const SITE = 'sangyoon0617-2d3b3f4c03';
const VIEW = '_17882524383710/RM'; // 워크북 근본팀장 / 뷰 RM
const VIEW_URL = HOST + '/t/' + SITE + '/views/' + VIEW;

export default class TableauEmbedSpike extends LightningElement {
    @track lines = [];
    @track payload = '(아직 선택 없음)';
    v3Loading;
    vizB;

    get logText() {
        return this.lines.length ? this.lines.join('\n') : '(대기)';
    }

    get payloadText() {
        return this.payload;
    }

    get box() {
        return this.template.querySelector('.vizbox');
    }

    log(msg, obj) {
        const t = new Date().toISOString().substr(11, 12);
        let line = t + '  ' + msg;
        if (obj !== undefined) {
            line += ' :: ' + this.safe(obj);
        }
        this.lines = [...this.lines, line];
        // eslint-disable-next-line no-console
        console.log('[tableauSpike]', line);
    }

    safe(o) {
        try {
            if (o instanceof Error) return o.name + ': ' + o.message;
            if (typeof o === 'string') return o;
            return JSON.stringify(o).substr(0, 800);
        } catch (e) {
            return String(o);
        }
    }

    reset() {
        const b = this.box;
        while (b && b.firstChild) {
            b.removeChild(b.firstChild);
        }
        this.lines = [];
        this.payload = '(아직 선택 없음)';
        this.log('초기화. 뷰 URL', VIEW_URL);
    }

    connectedCallback() {
        this.log('컴포넌트 로드. 정적 리소스', TABLEAU_API);
    }

    /* ---------- 전략 A: Embedding API v3 (ES 모듈 + 웹 컴포넌트) ---------- */

    async runA() {
        this.reset();
        this.log('A 시작 — v3 모듈 주입');
        try {
            await this.loadV3Module();
            this.log('A: 모듈 스크립트 onload 도달');
            const defined = await this.waitForCustomElement('tableau-viz', 8000);
            this.log('A: customElements.get("tableau-viz")', defined ? '정의됨' : '❌ 정의 안 됨');
            if (!defined) {
                this.log('A: 여기서 멈추면 LWS가 모듈 실행 또는 커스텀 엘리먼트 등록을 막은 것');
                return;
            }
            const viz = document.createElement('tableau-viz');
            viz.setAttribute('src', VIEW_URL);
            viz.setAttribute('toolbar', 'bottom');
            viz.setAttribute('hide-tabs', '');
            viz.style.width = '100%';
            viz.style.height = '100%';

            viz.addEventListener('firstinteractive', () => {
                this.log('A: ✅ firstinteractive — 뷰 렌더 완료');
            });
            viz.addEventListener('vizloaderror', (e) => {
                this.log('A: ❌ vizloaderror', e && e.detail);
            });
            viz.addEventListener('markselectionchanged', (e) => {
                this.log('A: ✅ markselectionchanged 도달');
                this.dumpV3Marks(e);
            });

            this.box.appendChild(viz);
            this.log('A: <tableau-viz> DOM 삽입 완료. 렌더 대기…');
        } catch (err) {
            this.log('A: ❌ 예외', err);
        }
    }

    loadV3Module() {
        if (this.v3Loading) return this.v3Loading;
        this.v3Loading = new Promise((resolve, reject) => {
            try {
                const s = document.createElement('script');
                s.type = 'module';
                s.src = TABLEAU_API + '/tableau.embedding.3.15.0.min.js';
                s.onload = () => resolve('onload');
                s.onerror = () => reject(new Error('module script onerror (CORS/CSP 의심)'));
                document.head.appendChild(s);
                this.log('A: script[type=module] head 삽입', s.src);
            } catch (e) {
                reject(e);
            }
        });
        return this.v3Loading;
    }

    waitForCustomElement(tag, timeoutMs) {
        return new Promise((resolve) => {
            const started = Date.now();
            const tick = () => {
                let defined = false;
                try {
                    defined = !!(window.customElements && window.customElements.get(tag));
                } catch (e) {
                    this.log('A: customElements 접근 예외', e);
                    resolve(false);
                    return;
                }
                if (defined) {
                    resolve(true);
                    return;
                }
                if (Date.now() - started > timeoutMs) {
                    resolve(false);
                    return;
                }
                // eslint-disable-next-line @lwc/lwc/no-async-operation
                setTimeout(tick, 250);
            };
            tick();
        });
    }

    dumpV3Marks(e) {
        Promise.resolve()
            .then(() => e.detail.getMarksAsync())
            .then((marks) => {
                const tables = marks && marks.data ? marks.data : [];
                const out = [];
                tables.forEach((tbl) => {
                    const cols = (tbl.columns || []).map((c) => c.fieldName);
                    (tbl.data || []).forEach((row) => {
                        const rec = {};
                        row.forEach((cell, i) => {
                            rec[cols[i]] =
                                cell.formattedValue !== undefined ? cell.formattedValue : cell.value;
                        });
                        out.push(rec);
                    });
                });
                this.payload = JSON.stringify(out, null, 2);
                this.log('A: 마크 개수', out.length);
                if (out.length) {
                    this.log('A: 필드명 목록', Object.keys(out[0]));
                }
            })
            .catch((err) => this.log('A: ❌ getMarksAsync 실패', err));
    }

    /* ---------- 전략 B: JS API v2 (클래식 스크립트 · loadScript) ---------- */

    async runB() {
        this.reset();
        this.log('B 시작 — v2 클래식 로드');
        try {
            await loadScript(this, TABLEAU_API + '/tableau-2.9.2.min.js');
            this.log('B: loadScript 성공. window.tableau 타입', typeof window.tableau);
            if (!window.tableau || !window.tableau.Viz) {
                this.log('B: ❌ window.tableau.Viz 없음 — LWS가 전역 노출을 막았을 가능성');
                return;
            }
            const options = {
                hideTabs: true,
                hideToolbar: false,
                width: '100%',
                height: '600px',
                onFirstInteractive: () => {
                    this.log('B: ✅ onFirstInteractive — 뷰 렌더 완료');
                    try {
                        this.vizB.addEventListener(
                            window.tableau.TableauEventName.MARKS_SELECTION,
                            (ev) => {
                                this.log('B: ✅ MARKS_SELECTION 도달');
                                this.dumpV2Marks(ev);
                            }
                        );
                        this.log('B: 이벤트 리스너 등록 완료');
                    } catch (e2) {
                        this.log('B: ❌ 리스너 등록 실패', e2);
                    }
                }
            };
            this.vizB = new window.tableau.Viz(this.box, VIEW_URL, options);
            this.log('B: Viz 생성 호출 완료. 렌더 대기…');
        } catch (err) {
            this.log('B: ❌ 예외', err);
        }
    }

    dumpV2Marks(ev) {
        ev.getMarksAsync()
            .then((marks) => {
                const out = marks.map((m) => {
                    const rec = {};
                    m.getPairs().forEach((p) => {
                        rec[p.fieldName] = p.formattedValue;
                    });
                    return rec;
                });
                this.payload = JSON.stringify(out, null, 2);
                this.log('B: 마크 개수', out.length);
                if (out.length) {
                    this.log('B: 필드명 목록', Object.keys(out[0]));
                }
            })
            .catch((e) => this.log('B: ❌ getMarksAsync 실패', e));
    }

    /* ---------- 전략 C: 순수 iframe (렌더만 확인, 이벤트 없음) ---------- */

    runC() {
        this.reset();
        this.log('C 시작 — 순수 iframe (이벤트 불가, 렌더/CSP만 확인)');
        const f = document.createElement('iframe');
        f.src = VIEW_URL + '?:embed=y&:showVizHome=n&:toolbar=bottom';
        f.style.width = '100%';
        f.style.height = '100%';
        f.style.border = '0';
        f.onload = () => this.log('C: iframe onload (CSP 통과. 내용 표시 여부는 눈으로 확인)');
        f.onerror = () => this.log('C: ❌ iframe onerror');
        this.box.appendChild(f);
        this.log('C: iframe 삽입', f.src);
    }
}