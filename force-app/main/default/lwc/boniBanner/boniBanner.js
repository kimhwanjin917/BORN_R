import { LightningElement, api, wire } from 'lwc';
import { getRecord } from 'lightning/uiRecordApi';
import USER_ID from '@salesforce/user/Id';
import NAME_FIELD from '@salesforce/schema/User.Name';
import BONI from '@salesforce/resourceUrl/BoniImages';
import getTodayEvents from '@salesforce/apex/HomeDashboardController.getTodayEvents';
import getMaturityAlertTasks from '@salesforce/apex/HomeDashboardController.getMaturityAlertTasks';
import getOpenOpportunityCount from '@salesforce/apex/BoniBannerController.getOpenOpportunityCount';

/**
 * docs/60 별건(보니) — 홈 헤더 밴드.
 * 보니(main) + 시간대 인사 + 한 줄 요약 + KPI 칩(오늘 미팅 · 만기 임박 · 진행 기회).
 * HomeDashboardController 는 호출만(수정 없음), 기회 수는 BoniBannerController(신규).
 * 되돌리기 = 홈 페이지 XML 원복(docs/60_assets/rollback_boni_home.ps1).
 */
export default class BoniBanner extends LightningElement {
    @api pose = 'main';
    @api size = 150;
    @api eyebrow = '보니';

    userName;
    eventCount;
    taskCount;
    oppCount;

    @wire(getRecord, { recordId: USER_ID, fields: [NAME_FIELD] })
    wiredUser({ data }) {
        if (data) {
            // User.Name 은 "성 이름"으로 합쳐지므로 한글 이름 표기에 맞게 공백 제거
            this.userName = (data.fields.Name.value || '').replace(/\s+/g, '');
        }
    }
    @wire(getTodayEvents)
    wiredEvents({ data }) {
        this.eventCount = Array.isArray(data) ? data.length : undefined;
    }
    @wire(getMaturityAlertTasks)
    wiredTasks({ data }) {
        this.taskCount = Array.isArray(data) ? data.length : undefined;
    }
    @wire(getOpenOpportunityCount)
    wiredOpps({ data }) {
        this.oppCount = typeof data === 'number' ? data : undefined;
    }

    get imageUrl() {
        return `${BONI}/${this.pose}.png`;
    }
    get imageStyle() {
        const px = Number(this.size) > 0 ? Number(this.size) : 150;
        return `width:${px}px;height:${px}px;`;
    }
    get greeting() {
        // 요청(2026-09-03): 시간대 분기 임시 해제 — 모든 시간대 "좋은 아침이에요"
        const name = this.userName ? `, ${this.userName}님` : '';
        return `좋은 아침이에요${name}!`;
    }
    get summary() {
        const e = this.eventCount;
        const t = this.taskCount;
        if (e === undefined && t === undefined) {
            return '오늘 일정을 확인하고 있어요.';
        }
        const parts = [];
        if (e !== undefined) {
            parts.push(e > 0 ? `오늘 미팅 ${e}건` : '오늘 잡힌 미팅은 없어요');
        }
        if (t !== undefined && t > 0) {
            parts.push(`만기 임박 자산 ${t}건`);
        }
        const head = parts.join(', ');
        const tail = e > 0 ? '미팅 전 브리핑은 제가 준비해 둘게요.' : '기회 레이더에서 새 신호를 살펴보세요.';
        return `${head}${head ? '. ' : ''}${tail}`;
    }
    get chips() {
        return [
            { key: 'events', label: '오늘 미팅', value: this.fmt(this.eventCount), cls: 'chip' },
            { key: 'tasks', label: '만기 임박', value: this.fmt(this.taskCount), cls: this.taskCount > 0 ? 'chip chip_warn' : 'chip' },
            { key: 'opps', label: '진행 기회', value: this.fmt(this.oppCount), cls: 'chip' }
        ];
    }
    fmt(n) {
        return n === undefined ? '–' : String(n);
    }
}