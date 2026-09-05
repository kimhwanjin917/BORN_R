import { LightningElement, api, track, wire } from 'lwc';
import { NavigationMixin, CurrentPageReference } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import BONI from '@salesforce/resourceUrl/BoniImages'; // 보니 로더(스피너 대체)
import getRadar from '@salesforce/apex/OpportunityRadarController.getRadar';
import resolveAccountId from '@salesforce/apex/OpportunityRadarController.resolveAccountId';

const EOK = 100000000;
const PRIORITY_SCORE = 75;
// 녹색 '우선 공략' 존의 X축 경계 — 최대 화이트스페이스 대비 비율.
// 2026-09-03: 0.25에서 완화. 점수 75점을 넘긴 계정이 공백 규모 때문에 존 밖에 그려져,
// 상단 KPI·목록 배지(점수>=75 기준)와 그림이 어긋나 존이 비어 보이던 것을 맞춘 값.
const ZONE_WS_RATIO = 0.15;
const CHART = { width: 1000, height: 700, left: 78, right: 964, top: 44, bottom: 600 };
const EOK_UNIT = 100000000;
const NICE_TICKS = [0, 500, 1000, 2000, 3000, 5000, 7000, 10000, 15000, 20000, 30000, 50000]; // 억
const PAGE_SIZE = 10;
const TYPE_CLASS = { 업셀: 'upsell', 크로스셀: 'crosssell', 만기차환: 'rollover' };
const num = (v) => (v == null || v === '' ? null : Number(v));

/**
 * 고객 성장 기회 레이더 — wallet share × propensity radar with next-best-action recommendations.
 * Works on an App Page (all accounts) or an Account record page (recordId → single account).
 */
export default class WalletOpportunityRadar extends NavigationMixin(LightningElement) {
    @api recordId;
    @track data;
    isLoading = true;
    error;
    segment = '전체';
    scope = 'all'; // Apex downgrades to 'mine' unless the user has Opportunity_Radar_View_All
    searchTerm = '';
    selectedId;
    page = 1;
    isSummaryExpanded = false;
    get boniLoadingUrl() { return BONI + '/chart.png'; }
    emailComposerOpen = false;
    emailAccountId;
    emailRecommendationId;

    @wire(CurrentPageReference)
    handlePageRef(pageRef) {
        // Deep link: /lightning/n/Opportunity_Radar?c__accountId=001... preselects that account (app-page mode)
        const target = pageRef?.state?.c__accountId || pageRef?.state?.c__whatId;
        if (target && target !== this.deepLinkId) {
            this.deepLinkId = target;
            this.applyDeepLink(target);
        }
    }

    connectedCallback() {
        this.load(false);
    }

    async applyDeepLink(recordId) {
        try {
            const accountId = recordId.startsWith('001') ? recordId : await resolveAccountId({ recordId });
            if (!accountId) return;
            this.selectedId = accountId;
            this.searchTerm = '';
            this.segment = '전체';
            if (this.data && !this.data.accounts.some((a) => a.accountId === accountId) && this.data.canViewAll && this.scope !== 'all') {
                this.scope = 'all';
                this.load(false);
            }
        } catch (e) {
            this.toastError(e);
        }
    }

    get segmentOptions() {
        const industries = [...new Set((this.data?.accounts || []).map((a) => a.industry).filter(Boolean))].sort();
        return [{ label: '전체 산업군', value: '전체' }, ...industries.map((i) => ({ label: i, value: i }))];
    }

    get isRecordMode() {
        return Boolean(this.recordId);
    }

    get isAppMode() {
        return !this.recordId;
    }

    get canViewAll() {
        return Boolean(this.data?.canViewAll) && this.isAppMode;
    }

    get scopeOptions() {
        return [{ label: '내 담당 고객', value: 'mine' }, { label: '전체 고객', value: 'all' }];
    }

    get recentOutcomeLabel() {
        return '최근 30일 · 종결된 추천';
    }

    get scopeLabel() {
        return this.data?.scope === 'all' ? '전체 고객' : '내 담당 고객';
    }

    get generatedLabel() {
        if (!this.data?.generatedAt) return '';
        return new Date(this.data.generatedAt).toLocaleString('ko-KR', { hour: '2-digit', minute: '2-digit' }) + ' 기준';
    }

    // ---------- filtering / ranking ----------
    /** Every account the server returned, normalised and ranked, before any filter is applied. */
    get allAccounts() {
        const rows = (this.data?.accounts || [])
            .map((a) => ({ ...a, share: num(a.share), wallet: num(a.wallet), reportedWallet: num(a.reportedWallet), ourBalance: num(a.ourBalance), whitespace: num(a.whitespace), propensity: num(a.propensity), priority: num(a.priority),
                recommendations: (a.recommendations || []).map((r) => ({ ...r, score: num(r.score), expectedAmount: num(r.expectedAmount) })),
                families: (a.families || []).map((f) => ({ ...f, wallet: num(f.wallet), reportedWallet: num(f.reportedWallet), ourBalance: num(f.ourBalance), share: num(f.share) })) }))
            .sort((a, b) => (b.priority || 0) - (a.priority || 0));
        return rows.map((a, i) => ({ ...a, rank: i + 1 }));
    }

    get rankedAccounts() {
        return this.allAccounts
            .filter((a) => this.segment === '전체' || a.industry === this.segment)
            .filter((a) => !this.searchTerm || a.name.toLowerCase().includes(this.searchTerm.toLowerCase()))
            .map((a, i) => ({ ...a, rank: i + 1 }));  // renumber 1..n so a filtered table still reads 1, 2, 3
    }

    get hasRows() {
        return this.rankedAccounts.length > 0;
    }

    /**
     * Resolved against the UNFILTERED list on purpose. Looking it up in the filtered list meant that
     * searching, switching industry or flipping scope silently dropped the chosen customer and showed
     * whatever sat at rank 1 instead, which reads as the panel jumping to another company on its own.
     */
    get selected() {
        const picked = this.allAccounts.find((a) => a.accountId === this.selectedId);
        if (picked) return picked;
        return this.rankedAccounts[0] || this.allAccounts[0] || null;
    }

    // ---------- KPIs ----------
    get kpis() {
        const list = this.rankedAccounts;
        const whitespace = list.reduce((s, a) => s + (a.whitespace || 0), 0);
        const shares = list.filter((a) => a.share != null);
        const avg = shares.length ? shares.reduce((s, a) => s + a.share, 0) / shares.length : 0;
        const priority = list.filter((a) => (a.propensity || 0) >= PRIORITY_SCORE && a.whitespace > 0).length;
        const expected = list.reduce((s, a) => s + a.recommendations.reduce((t, r) => t + (r.expectedAmount || 0), 0), 0);
        return [
            { label: '총 화이트스페이스', value: this.eok(whitespace), note: '접근가능 지갑 − 우리 잔액' },
            { label: '평균 지갑 점유율', value: this.pct(avg), note: `${list.length}개 고객 평균` },
            { label: '우선 공략 고객', value: `${priority}개`, note: `성공 가능성 ${PRIORITY_SCORE}점 이상` },
            { label: '추천 예상 금액', value: this.eok(expected), note: '상위 추천 합계' }
        ];
    }

    // ---------- chart ----------
    get priorityScore() { return PRIORITY_SCORE; }

    get chartCount() {
        return `${this.rankedAccounts.length}개 기업`;
    }

    // ---------- chart (sqrt x-scale, collision-avoided labels) ----------
    get chartMaxWs() {
        return Math.max(...this.rankedAccounts.map((a) => a.whitespace || 0), EOK_UNIT);
    }

    xPos(ws) {
        const f = Math.sqrt(Math.max(ws || 0, 0) / this.chartMaxWs);
        return CHART.left + f * (CHART.right - CHART.left);
    }

    yPos(score) {
        const clamped = Math.min(Math.max(score || 0, 0), 100);
        return CHART.bottom - (clamped / 100) * (CHART.bottom - CHART.top);
    }

    get chartPoints() {
        const list = this.rankedAccounts;
        const maxWallet = Math.max(...list.map((a) => a.wallet || 0), 1);
        const placed = [];
        const pts = list.map((a) => {
            const prop = a.propensity || 0;
            const cx = this.xPos(a.whitespace);
            const cy = this.yPos(prop);
            const r = 9 + Math.sqrt((a.wallet || 0) / maxWallet) * 22;
            const selected = a.accountId === this.selected?.accountId;
            return { id: a.accountId, cx, cy, r, selected, name: a.name, prop,
                cls: `radar-marker ${TYPE_CLASS[a.topType] || "none"}${selected ? " selected" : ""}`,
                title: `${a.name} · 공백 ${this.eok(a.whitespace)} · 가능성 ${prop}점 · 지갑 ${this.eok(a.wallet)}` };
        });
        // labels: right of bubble by default; flip left near right edge; push down on overlap
        const LH = 16, W = 11;
        pts.sort((p, q) => p.cy - q.cy || p.cx - q.cx);
        pts.forEach((p) => {
            const w = p.name.length * W + 8;
            let x = p.cx + p.r + 6, anchor = "start";
            if (x + w > CHART.right - 4) { x = p.cx - p.r - 6; anchor = "end"; }
            let y = p.cy + 4;
            const x0 = anchor === "start" ? x : x - w;
            for (let guard = 0; guard < 12; guard++) {
                const hit = placed.find((b) => !(x0 + w < b.x0 || x0 > b.x1 || y - LH > b.y1 || y < b.y0));
                if (!hit) break;
                y = hit.y1 + LH - 2;
            }
            placed.push({ x0, x1: x0 + w, y0: y - LH, y1: y });
            p.lx = x; p.ly = y; p.anchor = anchor;
            p.labelCls = `marker-label${p.selected ? " selected" : ""}`;
        });
        return pts;
    }

    get xTicks() {
        const maxEok = this.chartMaxWs / EOK_UNIT;
        return NICE_TICKS.filter((t) => t <= maxEok * 1.02).map((t) => ({
            x: this.xPos(t * EOK_UNIT), label: t === 0 ? "0" : this.eok(t * EOK_UNIT)
        }));
    }

    get yTicks() {
        return [0, 20, 40, 60, 80, 100].map((v) => ({ y: this.yPos(v), label: `${v}` }));
    }

    get zoneRect() {
        const x = this.xPos(this.chartMaxWs * ZONE_WS_RATIO);
        const y = this.yPos(PRIORITY_SCORE);
        return { x, y: CHART.top, w: CHART.right - x, h: y - CHART.top };
    }

    get quadrantX() { return this.xPos(this.chartMaxWs * ZONE_WS_RATIO); }
    get quadrantY() { return this.yPos(PRIORITY_SCORE); }
    get zoneLabelX() { return this.xPos(this.chartMaxWs * ZONE_WS_RATIO) + 12; }
    get zoneLabelY() { return CHART.top + 22; }
    get nurtureLabelX() { return CHART.left + 12; }
    get nurtureLabelY() { return CHART.bottom - 12; }
    get chartWidth() { return CHART.width; }
    get chartHeight() { return CHART.height; }
    get chartLeft() { return CHART.left; }
    get chartRight() { return CHART.right; }
    get chartTop() { return CHART.top; }
    get chartBottom() { return CHART.bottom; }
    get xTitleX() { return (CHART.left + CHART.right) / 2; }
    get xTickY() { return CHART.bottom + 26; }
    get xTitleY() { return CHART.bottom + 52; }
    get yTitleY() { return (CHART.top + CHART.bottom) / 2; }
    get yTitleTransform() { return `rotate(-90 22 ${(CHART.top + CHART.bottom) / 2})`; }
    get viewBox() { return `0 0 ${CHART.width} ${CHART.height}`; }

    // ---------- detail panel ----------
    get detail() {
        const a = this.selected;
        if (!a) return null;
        return {
            ...a,
            shareLabel: this.pct(a.share),
            walletLabel: this.eok(a.wallet),
            reportedWalletTitle: a.reportedWallet ? `재무제표상 ${this.eok(a.reportedWallet)} 중 접근가능분` : '',
            ourLabel: this.eok(a.ourBalance),
            whitespaceLabel: this.eok(a.whitespace),
            propensityLabel: a.propensity != null ? `${a.propensity}점` : '-',
            isPriority: (a.propensity || 0) >= PRIORITY_SCORE && a.whitespace > 0,
            statementLabel: a.statementPeriod ? `${a.statementPeriod} 재무제표 기준` : '재무제표 없음',
            lastContactLabel: a.lastContactDays == null ? '미팅 기록 없음' : (a.lastContactDays === 0 ? '오늘 미팅' : `마지막 미팅 ${a.lastContactDays}일 전`),
            lastContactClass: a.lastContactDays == null || a.lastContactDays > 90 ? 'contact stale' : 'contact',
            recs: (a.recommendations || []).map((r) => ({
                ...r,
                pillClass: `pill pill-${TYPE_CLASS[r.type] || 'none'}`,
                expectedLabel: this.eok(r.expectedAmount),
                scoreLabel: `${r.score}점`,
                isProposed: r.status === '제안됨',
                isInProgress: r.status === '기회생성',
                cardClass: r.status === '기회생성' ? 'recommendation recommendation_progress' : 'recommendation',
                statusLabel: '',
                hasOpp: Boolean(r.opportunityId),
                breakdown: this.breakdownOf(r.scoreDetail)
            })),
            skipped: a.skipped || [],
            outcomes: (a.outcomes || []).map((o) => ({
                ...o,
                isWon: o.status === '수주',
                icon: o.status === '수주' ? '✓' : '✗',
                rowClass: 'outcome ' + (o.status === '수주' ? 'outcome_won' : 'outcome_lost'),
                expectedLabel: this.eok(o.expectedAmount),
                closedLabel: o.closedOn ? new Date(o.closedOn).toLocaleDateString('ko-KR', { month: 'numeric', day: 'numeric' }) : '',
                hasOpp: Boolean(o.opportunityId)
            })),
            families: (a.families || []).filter((f) => f.wallet != null).map((f) => ({
                ...f,
                walletLabel: this.eok(f.wallet),
                ourLabel: this.eok(f.ourBalance),
                shareLabel: this.pct(f.share),
                basis: f.reportedWallet ? `${f.basis} ${this.eok(f.reportedWallet)} 중 접근가능분` : f.basis
            }))
        };
    }

    /**
     * @param share 0..1 of the addressable wallet we already hold
     * @returns band class so the bar reads as "barely in" / "getting there" / "well held" at a glance
     */
    shareBand(share) {
        const pct = (share || 0) * 100;
        if (pct < 15) return 'share-low';
        if (pct < 40) return 'share-mid';
        return 'share-high';
    }

    get pageCount() {
        return Math.max(1, Math.ceil(this.rankedAccounts.length / PAGE_SIZE));
    }

    get currentPage() {
        return Math.min(this.page, this.pageCount);
    }

    get pageLabel() {
        const total = this.rankedAccounts.length;
        const from = total === 0 ? 0 : (this.currentPage - 1) * PAGE_SIZE + 1;
        const to = Math.min(this.currentPage * PAGE_SIZE, total);
        return `${from}–${to} / ${total}개 기업`;
    }

    get isFirstPage() { return this.currentPage <= 1; }
    get isLastPage() { return this.currentPage >= this.pageCount; }
    get hasPager() { return this.rankedAccounts.length > PAGE_SIZE; }
    get summaryToggleLabel() { return this.isSummaryExpanded ? '접기' : '펼치기'; }
    get summaryContentClass() { return `detail-summary__content${this.isSummaryExpanded ? '' : ' is-collapsed'}`; }

    handlePrevPage() { if (!this.isFirstPage) this.page = this.currentPage - 1; }
    handleNextPage() { if (!this.isLastPage) this.page = this.currentPage + 1; }

    get tableRows() {
        const start = (this.currentPage - 1) * PAGE_SIZE;
        return this.rankedAccounts.slice(start, start + PAGE_SIZE).map((a) => ({
            ...a,
            rowClass: a.accountId === this.selected?.accountId ? 'selected' : '',
            isNewLogo: a.hasDealHistory === false,
            shareLabel: this.pct(a.share),
            shareStyle: 'width:' + Math.min(Math.round((a.share || 0) * 100), 100) + '%',
            shareFillClass: 'share-fill ' + this.shareBand(a.share),
            shareTitle: `접근가능 지갑 ${this.eok(a.wallet)} 중 우리 ${this.eok(a.ourBalance)}`,
            walletLabel: this.eok(a.wallet),
            whitespaceLabel: this.eok(a.whitespace),
            propensityLabel: a.propensity != null ? `${a.propensity}점` : '-',
            topLabel: a.topProduct ? `${a.topProduct}` : '-',
            topPillClass: `pill pill-${TYPE_CLASS[a.topType] || 'none'}`
        }));
    }

    // ---------- handlers ----------
    handleSegment(e) { this.segment = e.detail.value; this.page = 1; }
    handleScope(e) { this.scope = e.detail.value; this.load(false); }
    handleSearch(e) { this.searchTerm = e.target.value || ''; this.page = 1; }
    handleRefresh() { this.load(true); }
    handleToggleSummary() { this.isSummaryExpanded = !this.isSummaryExpanded; }
    handleSelect(e) {
        this.selectedId = e.currentTarget.dataset.id;
        const idx = this.rankedAccounts.findIndex((a) => a.accountId === this.selectedId);
        if (idx >= 0) this.page = Math.floor(idx / PAGE_SIZE) + 1;
    }
    handleSelectKey(e) {
        if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); this.selectedId = e.currentTarget.dataset.id; }
    }
    handleOpenAccount() {
        if (this.selected) this.navigateTo(this.selected.accountId, 'Account');
    }
    handleOpenOpportunity(e) {
        this.navigateTo(e.currentTarget.dataset.oppId, 'Opportunity');
    }

    handlePrepareEmail(e) {
        const recommendationId = e.currentTarget.dataset.recId;
        const accountId = this.selected?.accountId;
        if (!accountId || !recommendationId) {
            this.toastError({ body: { message: '메일을 보낼 고객사와 추천을 확인해 주세요.' } });
            return;
        }

        this.emailAccountId = accountId;
        this.emailRecommendationId = recommendationId;
        this.emailComposerOpen = true;
    }

    handleCloseEmailComposer() {
        this.emailComposerOpen = false;
        this.emailAccountId = undefined;
        this.emailRecommendationId = undefined;
    }

    async load(force) {
        this.isLoading = true;
        this.error = undefined;
        try {
            this.data = await getRadar({ accountId: this.recordId || null, forceRefresh: force, scope: this.scope });
            if (this.data?.scope && this.data.scope !== this.scope) this.scope = this.data.scope;
            if (!this.selectedId && this.data?.accounts?.length) {
                this.selectedId = this.rankedAccounts[0]?.accountId;
            }
        } catch (err) {
            this.error = this.messageOf(err);
        } finally {
            this.isLoading = false;
        }
    }

    breakdownOf(json) {
        if (!json) return [];
        let d;
        try { d = JSON.parse(json); } catch (e) { return []; }
        const items = [
            { key: 'similarWon', label: '성사율', note: d.similarWonNote },
            { key: 'signal', label: '자금 수요', note: d.signalNote || '신호 없음' },
            { key: 'financial', label: '재무 여력', note: d.financialNote },
            { key: 'priority', label: 'RM 우선순위', note: null }
        ];
        return items.map((i) => {
            const v = Math.min(Math.max(Number(d[i.key]) || 0, 0), 100);
            return { ...i, value: v, style: 'width:' + v + '%', title: i.note ? `${i.label} ${v}점 · ${i.note}` : `${i.label} ${v}점` };
        });
    }

    navigateTo(recordId, objectApiName) {
        this[NavigationMixin.Navigate]({ type: 'standard__recordPage', attributes: { recordId, objectApiName, actionName: 'view' } });
    }

    toastError(err) {
        this.dispatchEvent(new ShowToastEvent({ title: '오류', message: this.messageOf(err), variant: 'error' }));
    }

    messageOf(err) {
        return err?.body?.message || err?.message || '알 수 없는 오류';
    }

    eok(v) {
        if (v == null) return '-';
        const n = v / EOK;
        return n >= 10000 ? `${(n / 10000).toFixed(1)}조` : `${Math.round(n).toLocaleString('ko-KR')}억`;
    }

    pct(v) {
        return v == null ? '-' : `${(v * 100).toFixed(1)}%`;
    }

    toHtml(text) {
        return String(text || '')
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/\n/g, '<br/>');
    }
}