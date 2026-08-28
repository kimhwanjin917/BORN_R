import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import PRIORITY_SCORE_FIELD from '@salesforce/schema/Lead.Priority_Score__c';
import getBriefing from '@salesforce/apex/MeetingPrepBriefingController.getBriefing';
import generateBriefing from '@salesforce/apex/MeetingPrepBriefingController.generateBriefing';

/**
 * 프롬프트 템플릿(Meeting_Prep_Briefing)이 만들어 준 평문 텍스트를
 * 화면에서 파싱해 항목별 "카드"로 보여 주는 컴포넌트.
 *
 * 템플릿 출력 형식(프롬프트는 건드리지 않음):
 *   ◆ 미팅 준비 브리핑
 *   ■ 한줄 요약: ...
 *   ■ 재무 하이라이트:
 *     - 현금및현금성자산: 900.9억 원 → 전년 대비 435.7억 원 감소
 *   ◆ 핵심 요약
 *   ■ 우선순위 사유: ...  (등)
 *
 * "◆ 미팅 준비 브리핑" 헤더는 카드 제목과 중복이라 숨긴다.
 * 각 "■ 항목"은 번호 뱃지·아이콘·테마색을 붙여 개별 카드로 렌더링하고,
 * 재무 지표는 끝의 "증가/감소" 단어를 파랑/빨강 태그로 분리해 강조한다.
 */
export default class LeadMeetingPrepBriefing extends LightningElement {
    @api recordId;

    briefing;
    updatedAt;
    isGenerating = false;
    // 우선순위 점수는 AI 줄글이 아니라 Lead 필드에서 직접 읽어 항상 표시한다.
    priorityScore;

    _wired;

    @wire(getBriefing, { recordId: '$recordId' })
    wiredBriefing(result) {
        this._wired = result;
        if (result.data) {
            this.briefing = result.data.briefing;
            this.updatedAt = result.data.updatedAt;
        }
    }

    @wire(getRecord, { recordId: '$recordId', fields: [PRIORITY_SCORE_FIELD] })
    wiredLead({ data }) {
        if (data) {
            this.priorityScore = getFieldValue(data, PRIORITY_SCORE_FIELD);
        }
    }

    get hasBriefing() {
        return !!this.briefing;
    }

    get hasCards() {
        return this.cards.length > 0;
    }

    /**
     * 텍스트 → 카드 배열. 섹션 구분(◆) 없이 모든 "■ 항목"을 하나의 그리드로 펼친다.
     * 요청에 따라 "한줄 요약"·"AI 한줄 리뷰" 카드는 제외하고, 번호는 남은 카드 기준 01부터 다시 매긴다.
     */
    get cards() {
        const raw = this.briefing;
        if (!raw) {
            return [];
        }
        const cards = [];
        let counter = 0;

        raw.split('◆').forEach((block, bi) => {
            const trimmed = block.trim();
            if (!trimmed) {
                return;
            }
            const nl = trimmed.indexOf('\n');
            const rest = nl === -1 ? '' : trimmed.slice(nl + 1);

            rest.split('■').forEach((chunk, ii) => {
                const t = chunk.trim();
                if (!t) {
                    return;
                }
                let label = '';
                let body = t;
                const ci = t.indexOf(':');
                if (ci > -1 && ci <= 20) {
                    label = t.slice(0, ci).trim();
                    body = t.slice(ci + 1).trim();
                }

                // 제외 대상: "한줄 요약", "AI 한줄 리뷰"
                if (/한줄\s*요약/.test(label) || /AI\s*한줄\s*리뷰/i.test(label)) {
                    return;
                }

                const meta = this.metaFor(label);
                const colorize = /재무/.test(label);
                counter += 1;

                // 우선순위 사유: 점수는 Lead의 Priority_Score__c 값을 헤더 우측 배지로 쓴다
                // (AI가 줄글에 점수를 안 써도 항상 표시). 본문에선 점수·라벨 문구를 제거해 사유만 남긴다.
                let score = '';
                if (/우선순위/.test(label)) {
                    if (
                        this.priorityScore !== null &&
                        this.priorityScore !== undefined
                    ) {
                        score = String(this.priorityScore);
                    } else {
                        const sm =
                            body.match(
                                /우선순위\s*점수\s*[:：]\s*([0-9]+(?:\.[0-9]+)?)/
                            ) || body.match(/([0-9]+(?:\.[0-9]+)?)\s*점/);
                        if (sm) {
                            score = sm[1];
                        }
                    }
                    body = body
                        .replace(
                            /우선순위\s*점수\s*[:：]\s*[0-9]+(?:\.[0-9]+)?\s*점?\.?/g,
                            ''
                        )
                        .replace(/우선순위\s*사유\s*요약\s*[:：]/g, '')
                        .trim();
                }

                // 템플릿이 준 줄단위 불릿. 줄글 한 덩어리(4·5·6번)면 문장 단위로 쪼개
                // 1·2·3번과 같은 개조식 불릿 리스트로 만든다.
                let bullets = body
                    .split('\n')
                    .map((l) => l.replace(/^[-•·]\s*/, '').trim())
                    .filter((l) => l);
                if (bullets.length <= 1) {
                    bullets = this.splitSentences(
                        bullets.length ? bullets[0] : body
                    );
                }
                // 재무 카드는 증감 태그 추출을 건드리지 않도록 개조식 변환에서 제외
                if (!colorize) {
                    bullets = bullets.map((l) => this.toNounStyle(l));
                }

                cards.push({
                    key: `${bi}-${ii}`,
                    number: String(counter).padStart(2, '0'),
                    label,
                    icon: meta.icon,
                    score,
                    // 재무 지표는 연간(4분기 누적) 기준이라 카드 하단에 기준 배지 표시
                    note: colorize ? '전년 대비 기준 · 전년도 4분기 누적' : '',
                    themeStyle: `--accent:${meta.accent};--accent-soft:${meta.accent}14;--accent-line:${meta.accent}40;`,
                    asList: bullets.length > 0,
                    text: bullets.length ? bullets[0] : body,
                    bullets: bullets.map((line, k) =>
                        this.buildBullet(line, colorize, `${bi}-${ii}-${k}`)
                    )
                });
            });
        });
        return cards;
    }

    /**
     * 줄글 본문을 문장 단위로 쪼갠다. 문장부호 뒤 공백에서만 끊으므로
     * 소수점 점수(예: 74.2)는 뒤에 공백이 없어 분리되지 않는다.
     */
    splitSentences(text) {
        if (!text) {
            return [];
        }
        return text
            .split(/(?<=[.!?。])\s+/)
            .map((s) => s.trim())
            .filter((s) => s);
    }

    /** 문장 끝 서술형 어미를 1·2·3번 카드처럼 개조식(명사형)으로 바꾼다. */
    toNounStyle(line) {
        if (!line) {
            return line;
        }
        let s = line.trim();
        const endings = [
            [/있습니다\.?$/, '있음'],
            [/없습니다\.?$/, '없음'],
            [/입니다\.?$/, '임'],
            [/됩니다\.?$/, '됨'],
            [/립니다\.?$/, '림'],
            [/합니다\.?$/, '함'],
            [/습니다\.?$/, '음'],
            [/있다\.?$/, '있음'],
            [/없다\.?$/, '없음'],
            [/이다\.?$/, '임'],
            [/된다\.?$/, '됨'],
            [/한다\.?$/, '함'],
            [/부족하다\.?$/, '부족'],
            [/필요하다\.?$/, '필요'],
            [/가능하다\.?$/, '가능'],
            [/하다\.?$/, '함']
        ];
        for (let i = 0; i < endings.length; i += 1) {
            if (endings[i][0].test(s)) {
                s = s.replace(endings[i][0], endings[i][1]);
                break;
            }
        }
        return s;
    }

    /** 불릿 한 줄 → { text, 증감 태그 }. 재무 항목만 끝의 증가/감소를 태그로 분리. */
    buildBullet(line, colorize, key) {
        const bullet = { key, text: line, hasChip: false, chip: '', chipClass: '' };
        if (!colorize) {
            return bullet;
        }
        const m = line.match(/(증가|감소|상승|하락|확대|축소|개선|흑자|적자)\s*$/);
        if (m) {
            const word = m[1];
            const down = /감소|하락|축소|적자/.test(word);
            bullet.hasChip = true;
            bullet.chip = word;
            bullet.chipClass = down ? 'delta delta-down' : 'delta delta-up';
            bullet.text = line
                .replace(/(증가|감소|상승|하락|확대|축소|개선|흑자|적자)\s*$/, '')
                .replace(/[\s→\-–—]*$/, '')
                .trim();
        }
        return bullet;
    }

    /** 항목 라벨에 맞는 아이콘/테마색. 못 찾으면 중립색. */
    metaFor(label) {
        const L = label || '';
        const map = [
            [/AI/i, 'utility:einstein', '#e5006e'],
            [/한줄\s*요약/, 'utility:summary', '#0176d3'],
            [/재무/, 'utility:money', '#2e844a'],
            [/동향/, 'utility:trending', '#0b827c'],
            [/미팅/, 'utility:groups', '#9050e9'],
            [/우선순위/, 'utility:priority', '#fe9339'],
            [/추천/, 'utility:cart', '#5867e8'],
            [/WON|확률/, 'utility:graph', '#ba0517']
        ];
        for (let i = 0; i < map.length; i += 1) {
            if (map[i][0].test(L)) {
                return { icon: map[i][1], accent: map[i][2] };
            }
        }
        return { icon: 'utility:info', accent: '#747474' };
    }

    get updatedLabel() {
        if (!this.updatedAt) {
            return '';
        }
        return `생성: ${new Date(this.updatedAt).toLocaleString('ko-KR')}`;
    }

    get refreshLabel() {
        return this.hasBriefing ? '새로고침' : '브리핑 생성';
    }

    async handleRefresh() {
        this.isGenerating = true;
        try {
            const result = await generateBriefing({ recordId: this.recordId });
            this.briefing = result.briefing;
            this.updatedAt = result.updatedAt;
            if (this._wired) {
                await refreshApex(this._wired);
            }
            this.dispatchEvent(
                new ShowToastEvent({
                    title: '미팅 준비 브리핑',
                    message: '브리핑을 새로 생성했습니다.',
                    variant: 'success'
                })
            );
        } catch (error) {
            const message =
                error && error.body && error.body.message
                    ? error.body.message
                    : '브리핑을 생성하지 못했습니다.';
            this.dispatchEvent(
                new ShowToastEvent({
                    title: '브리핑 생성 실패',
                    message,
                    variant: 'error',
                    mode: 'sticky'
                })
            );
        } finally {
            this.isGenerating = false;
        }
    }
}
