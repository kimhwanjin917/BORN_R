import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import {
    getRecord,
    getFieldValue,
    notifyRecordUpdateAvailable
} from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import OPP_PRODUCT_NAME_FIELD from '@salesforce/schema/Opportunity.Primary_Product__r.Name';
import OPP_FAMILY_FIELD from '@salesforce/schema/Opportunity.Product_Family__c';
import PRIORITY_SCORE_FIELD from '@salesforce/schema/Lead.Priority_Score__c';
import PRIORITY_RATIONALE_SUMMARY_FIELD from '@salesforce/schema/Lead.Priority_Rationale_Summary__c';
import PRIORITY_RATIONALE_DETAIL_FIELD from '@salesforce/schema/Lead.Priority_Rationale_Detail__c';
import REC_FAMILY_FIELD from '@salesforce/schema/Lead.Recommended_Product_Family__c';
import REC_TERM_DAYS_FIELD from '@salesforce/schema/Lead.Recommended_Term_Days__c';
import REC_FEE_RATE_FIELD from '@salesforce/schema/Lead.Recommended_Fee_Rate__c';
import REC_RATIONALE_FIELD from '@salesforce/schema/Lead.Recommended_Product_Rationale__c';
import BONI from '@salesforce/resourceUrl/BoniImages'; // 보니 로더(스피너 대체)
import getBriefing from '@salesforce/apex/MeetingPrepBriefingController.getBriefing';
import generateBriefing from '@salesforce/apex/MeetingPrepBriefingController.generateBriefing';
import ensureRecommendation from '@salesforce/apex/MeetingPrepBriefingController.ensureRecommendation';
import getSimilarWon from '@salesforce/apex/MeetingPrepBriefingController.getSimilarWon';

/** 추천 카드 테마색. metaFor 의 /추천/ 항목과 같은 값을 쓴다. */
const REC_ACCENT = '#5867e8';

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
    @api objectApiName;

    briefing;
    updatedAt;
    isGenerating = false;
    get isNotGenerating() { return !this.isGenerating; }
    get emptyStateClass() { return this.isGenerating ? 'briefing-empty-state briefing-empty-state--boni' : 'briefing-empty-state'; }
    get boniLoadingUrl() { return BONI + '/chart.png'; }
    // 카드 접기/펴기. 기본은 펼침 — RM 이 리드 화면을 열면 브리핑이 바로 보여야 한다.
    // 접힌 상태는 저장하지 않는다(화면을 다시 열면 다시 펼침).
    isExpanded = true;
    // 우선순위 점수는 AI 줄글이 아니라 Lead 필드에서 직접 읽어 항상 표시한다.
    priorityScore;
    priorityRationaleSummary;
    priorityRationaleDetail;
    // 추천 상품도 같은 이유로 필드에서 직접 읽는다. AI 가 줄글로 다시 쓰면
    // 상품 제안서 PDF(같은 필드를 그대로 인쇄)와 문구가 어긋날 수 있고,
    // 브리핑 텍스트는 생성 시점 스냅샷이라 나중에 추천이 바뀌어도 옛 값이 남는다.
    // 추천 필드를 읽을 권한이 있는지. 권한 없음과 "추천 없음"은 다른 안내를 해야 한다.
    recReadable = true;
    recProductName;
    recFamily;
    recTermDays;
    recFeeRate;
    recRationale;
    similarWon;

    _wired;
    _briefingRecordId;
    autoGenerationAttempted = false;

    get isOpportunity() {
        return this.objectApiName === 'Opportunity';
    }

    get briefingTitle() {
        return this.isOpportunity ? '미팅 준비 브리핑' : '기업 브리핑';
    }

    get recordFields() {
        return this.isOpportunity
            ? [OPP_PRODUCT_NAME_FIELD, OPP_FAMILY_FIELD]
            : [PRIORITY_SCORE_FIELD];
    }

    get optionalRecordFields() {
        return this.isOpportunity
            ? []
            : [
                  REC_FAMILY_FIELD,
                  REC_TERM_DAYS_FIELD,
                  REC_FEE_RATE_FIELD,
                  REC_RATIONALE_FIELD,
                  PRIORITY_RATIONALE_SUMMARY_FIELD,
                  PRIORITY_RATIONALE_DETAIL_FIELD
              ];
    }

    @wire(getBriefing, { recordId: '$recordId' })
    wiredBriefing(result) {
        this._wired = result;
        if (this.recordId && this._briefingRecordId !== this.recordId) {
            this._briefingRecordId = this.recordId;
            this.autoGenerationAttempted = false;
            this.briefing = undefined;
            this.updatedAt = undefined;
        }
        if (result.data) {
            const storedBriefing = this.normalizeBriefingText(result.data.briefing);
            const staleFinancialFallback =
                this.isOpportunity && this.isFinancialFallback(storedBriefing);
            this.briefing = staleFinancialFallback ? undefined : storedBriefing;
            this.updatedAt = staleFinancialFallback ? undefined : result.data.updatedAt;

            // Opportunity는 처음 열었을 때 저장된 브리핑이 없으면 자동 생성한다.
            // 한 번만 시도해 같은 레코드의 wire 갱신이나 화면 재렌더링으로
            // AI 생성이 반복 호출되지 않도록 한다.
            if (
                this.isOpportunity &&
                !this.briefing &&
                this.recordId &&
                !this.autoGenerationAttempted
            ) {
                this.autoGenerationAttempted = true;
                this.handleRefresh(false);
            }
        }
    }

    normalizeBriefingText(briefingText) {
        if (!briefingText) {
            return briefingText;
        }
        return briefingText
            .replace(/<br\s*\/?\s*>/gi, '\n')
            .replace(/<\/(p|div)>/gi, '\n')
            .replace(/<[^>]+>/g, '')
            .replace(/&amp;/g, '&')
            .replace(/&lt;/g, '<')
            .replace(/&gt;/g, '>')
            .replace(/■/g, '\n■')
            .trim();
    }

    isFinancialFallback(briefingText) {
        if (!briefingText) {
            return false;
        }
        return (
            briefingText.includes('재무 수치가 제공되지') ||
            briefingText.includes('재무 수치가 포함되어 있지') ||
            briefingText.includes('재무·추이 수치가 제공되지') ||
            briefingText.includes('근거 데이터 조회 권한') ||
            briefingText.includes('재무 추이의 상세가 없') ||
            briefingText.includes('재무 추이 수치가 없어') ||
            briefingText.includes('재무 추이의 구체적 항목이 제공될 때까지') ||
            briefingText.includes('구체적 수치 확인은 불가능') ||
            briefingText.includes('구체 재무 추이를 확인할 수 없') ||
            briefingText.includes('재무 세부 자료') ||
            briefingText.includes('재무 추이 상세 데이터 접근이 불가') ||
            briefingText.includes('구체적 매출·자산·현금흐름 수치를 제시할 수 없') ||
            briefingText.includes('제공된 근거 데이터 내에서 확인 가능한 항목이 없어') ||
            briefingText.includes('구체적 흐름은 미확인') ||
            briefingText.includes('재무·시그널 상세를 제공할 수 없') ||
            briefingText.includes('외부 시그널 상세가 제공되지') ||
            briefingText.includes('외부 시그널 세부 정보에 접근하지 못') ||
            briefingText.includes('외부 시그널 상세 정보에 접근하지 못') ||
            briefingText.includes('외부 시그널에 접근할 수 없') ||
            briefingText.includes('외부 시그널 상세를 확인할 수 없') ||
            briefingText.includes('외부 시그널이 제공되지') ||
            briefingText.includes('외부 시그널과 관련된 상세 정보가 제공되지') ||
            briefingText.includes('외부 시그널과 관련된 상세 정보는 제공되지') ||
            briefingText.includes('재무·시그널 상세가 제공되지') ||
            briefingText.includes('외부 신호의 상세 내용은 제공되지') ||
            briefingText.includes('외부 신호 상세가 제공되지') ||
            briefingText.includes('시그널 상세 내용은 제공되지') ||
            (briefingText.includes('재무 추이') &&
                (briefingText.includes('조회 불가') ||
                    briefingText.includes('접근할 수 없') ||
                    briefingText.includes('접근이 불가') ||
                    briefingText.includes('수치를 제시할 수 없') ||
                    briefingText.includes('수치 확인이 불가') ||
                    briefingText.includes('자료가 없') ||
                    briefingText.includes('자료의 부재') ||
                    briefingText.includes('미확인')))
        );
    }

    @wire(getSimilarWon, { recordId: '$similarWonRecordId' })
    wiredSimilarWon({ data }) {
        if (data) {
            this.similarWon = data;
        }
    }

    get similarWonRecordId() {
        return this.isOpportunity ? this.recordId : undefined;
    }

    // 추천 필드는 optionalFields 로 받는다. fields 에 넣으면 그 중 하나라도 읽기 권한이
    // 없는 사용자에게 요청 전체가 실패해, 같은 wire 의 Priority_Score__c 까지 못 읽는다.
    // 실제로 추천 필드는 RM_Assistant_Access 에만 있고 Priority_Dashboard_Access 에는 없어서,
    // 후자만 가진 사용자(임원 등)의 우선순위 점수 배지가 통째로 사라진다.
    @wire(getRecord, {
        recordId: '$recordId',
        fields: '$recordFields',
        optionalFields: '$optionalRecordFields'
    })
    wiredLead({ data }) {
        if (data) {
            this.priorityScore = this.isOpportunity
                ? null
                : getFieldValue(data, PRIORITY_SCORE_FIELD);
            // optionalFields 는 권한이 없으면 응답에서 키 자체가 빠진다. 값이 null 인 것
            // (= 추천이 아직 없음)과 구분해야 "미정"이라고 잘못 알리지 않는다.
            if (this.isOpportunity) {
                this.recReadable = true;
                this.recProductName = getFieldValue(data, OPP_PRODUCT_NAME_FIELD);
                this.recFamily = getFieldValue(data, OPP_FAMILY_FIELD);
                this.recTermDays = null;
                this.recFeeRate = null;
                this.recRationale = this.recProductName
                    ? `기회의 기준 상품 ${this.recProductName}을(를) 기준으로 준비`
                    : null;
            } else {
                this.recReadable = Object.prototype.hasOwnProperty.call(
                    data.fields || {},
                    'Recommended_Product_Family__c'
                );
                // Lead에는 추천 상품 lookup 필드가 없고 상품군만 저장된다.
                // 존재하지 않는 Recommended_Product__r.Name을 schema import하면
                // 브라우저에서 컴포넌트 모듈 로딩 자체가 실패한다.
                this.recProductName = null;
                this.recFamily = getFieldValue(data, REC_FAMILY_FIELD);
                this.recTermDays = getFieldValue(data, REC_TERM_DAYS_FIELD);
                this.recFeeRate = getFieldValue(data, REC_FEE_RATE_FIELD);
                this.recRationale = getFieldValue(data, REC_RATIONALE_FIELD);
                this.priorityRationaleSummary = getFieldValue(
                    data,
                    PRIORITY_RATIONALE_SUMMARY_FIELD
                );
                this.priorityRationaleDetail = getFieldValue(
                    data,
                    PRIORITY_RATIONALE_DETAIL_FIELD
                );
            }
        }
    }

    get hasRecommendation() {
        return !!this.recProductName || !!this.recFamily;
    }

    /**
     * 추천 상품 카드 — LLM 문장이 아니라 Lead 필드 원본으로 만든다.
     * 상품 제안서 PDF 가 읽는 값과 같은 필드라 두 화면이 어긋날 수 없다.
     */
    get recommendationCard() {
        const lines = [];
        if (!this.recReadable) {
            return {
                key: 'rec-field',
                number: '01',
                label: '추천 상품 (권한 없음)',
                icon: 'utility:lock',
                score: '',
                note: '추천 필드 읽기 권한이 없습니다 (RM Assistant Access)',
                noteIcon: 'utility:database',
                themeStyle: `--accent:#747474;--accent-soft:#74747414;--accent-line:#74747440;`,
                asList: true,
                text: '',
                bullets: [
                    {
                        key: 'rec-noaccess',
                        text: '추천 상품 정보를 볼 권한이 없어 표시하지 않습니다. 아래 AI 문장에도 추천 내용은 포함되지 않습니다.',
                        hasChip: false,
                        chip: '',
                        chipClass: ''
                    }
                ]
            };
        }
        if (this.hasRecommendation) {
            if (this.recProductName) {
                lines.push(`종목: ${this.recProductName}`);
            }
            if (this.recFamily) {
                lines.push(`상품군: ${this.recFamily}`);
            }
            if (this.recTermDays !== null && this.recTermDays !== undefined) {
                lines.push(`운용기간: ${Math.round(this.recTermDays)}일`);
            }
            if (this.recFeeRate !== null && this.recFeeRate !== undefined) {
                lines.push(`수수료율: ${this.recFeeRate}% (RM 참고용 · 고객용 PDF 미표시)`);
            }
            if (this.recRationale) {
                lines.push(`근거: ${this.recRationale}`);
            }
        } else {
            lines.push(
                '저장된 추천이 없습니다. 상품 제안서 화면에도 동일하게 표시되며, 제안할 상품은 직접 선택합니다.'
            );
        }
        return {
            key: 'rec-field',
            number: '01',
            label: this.hasRecommendation ? '추천상품' : '추천상품 (미정)',
            icon: 'utility:cart',
            score: '',
            note: '',
            noteIcon: 'utility:database',
            themeStyle: `--accent:${REC_ACCENT};--accent-soft:${REC_ACCENT}14;--accent-line:${REC_ACCENT}40;`,
            asList: true,
            text: '',
            bullets: lines.map((line, k) => ({
                key: `rec-${k}`,
                text: line,
                hasChip: false,
                chip: '',
                chipClass: ''
            }))
        };
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
        // 생성 응답과 ContentNote wire 응답의 형식이 다를 수 있으므로
        // 카드 파싱 직전에도 HTML/섹션 구분자를 정규화한다.
        const raw = this.normalizeBriefingText(this.briefing);
        if (!raw) {
            return [];
        }
        // Opportunity는 기존처럼 추천 카드를 맨 앞에 둔다.
        // Lead는 아래에서 우선순위 사유·재무·동향·추천상품 순으로 정렬한다.
        const cards = this.isOpportunity ? [this.recommendationCard] : [];
        let hasPriorityReasonCard = false;

        raw.split('◆').forEach((block, bi) => {
            const trimmed = block.trim();
            if (!trimmed) {
                return;
            }
            const nl = trimmed.indexOf('\n');
            const firstLine = nl === -1 ? trimmed : trimmed.slice(0, nl).trim();
            // ◆ 없이 ■ 항목만 이어지는 응답도 있으므로 첫 줄이 실제 항목이면
            // 헤더로 버리지 않는다. (기존에는 첫 줄을 무조건 버려 최근 동향이
            // 첫 섹션으로 반환될 때 누락될 수 있었다.)
            const rest = firstLine.startsWith('■')
                ? trimmed
                : nl === -1
                  ? ''
                  : trimmed.slice(nl + 1);
            const headerChunk =
                !firstLine.startsWith('■') && this.isBriefingSectionLabel(firstLine)
                    ? `${firstLine}\n${rest}`
                    : null;
            const chunks = rest.split('■');
            if (headerChunk && !rest.includes('■')) {
                chunks.unshift(headerChunk);
            }

            chunks.forEach((chunk, ii) => {
                const t = chunk.trim();
                if (!t) {
                    return;
                }
                const parsed = this.parseBriefingLabel(t);
                const label = parsed.label;
                let body = parsed.body;

                // 제외 대상: "한줄 요약", "AI 한줄 리뷰",
                // 그리고 추천 관련 항목 — 위 recommendationCard 가 필드 원본으로 대신한다.
                // AI 가 쓴 추천 문장을 같이 보여주면 제안서와 다른 값이 섞여 보인다.
                if (
                    /한줄\s*요약/.test(label) ||
                    /AI\s*한줄\s*리뷰/i.test(label) ||
                    /추천/.test(label) ||
                    /유사\s*WON|WON\s*확률/i.test(label)
                ) {
                    return;
                }

                // Lead는 재무·동향·우선순위 사유, Opportunity는 재무·동향·미팅 포인트만
                // 노출한다. 프롬프트 버전이 바뀌거나 모델이 임의의 섹션을 덧붙여도
                // 오브젝트별 카드 구성이 흔들리지 않게 한다.
                const allowedLabel = this.isOpportunity
                    ? /^(재무\s*하이라이트|최근\s*동향|미팅\s*포인트)$/
                    : /^(재무\s*하이라이트|최근\s*동향|우선순위\s*사유)$/;
                if (!allowedLabel.test(label)) {
                    return;
                }
                if (/^우선순위\s*사유$/.test(label)) {
                    hasPriorityReasonCard = true;
                }

                const meta = this.metaFor(label);
                const colorize = /재무/.test(label);

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
                    .map((l) =>
                        l
                            .replace(/\s+불릿\.?$/, '')
                            .replace(/\s*감사합니다\..*$/, '')
                            .trim()
                    )
                    // 구버전 프롬프트가 지침 문구를 그대로 생성해도 화면에는 숨긴다.
                    .filter((l) => l && !/^\([^)]*(불릿|1문장)\)$/.test(l))
                    // 모델이 덧붙이는 형식적인 맺음말은 카드 높이만 늘리므로 제외한다.
                    .filter((l) => !/^감사합니다\b/.test(l));
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
                    number: '',
                    label,
                    icon: meta.icon,
                    score,
                    // 재무 지표는 연간(4분기 누적) 기준이라 카드 하단에 기준 배지 표시
                    note: colorize ? '전년 대비 기준 · 전년도 4분기 누적' : '',
                    noteIcon: 'utility:event',
                    themeStyle: `--accent:${meta.accent};--accent-soft:${meta.accent}14;--accent-line:${meta.accent}40;`,
                    asList: bullets.length > 0,
                    text: bullets.length ? bullets[0] : body,
                    bullets: bullets.map((line, k) =>
                        this.buildBullet(line, colorize, `${bi}-${ii}-${k}`)
                    )
                });
            });
        });
        // 기존 저장 브리핑이 우선순위 사유 없이 생성된 경우에도 Lead 필드 원본으로
        // 카드를 보완한다. 새로고침 전의 오래된 브리핑도 요청한 구성을 유지한다.
        if (!this.isOpportunity && !hasPriorityReasonCard) {
            cards.push(this.priorityReasonCard);
        }
        if (this.isOpportunity && this.similarWon) {
            cards.push(this.similarWonCard);
        }

        if (!this.isOpportunity) {
            const priorityCard = cards.find((card) => /^우선순위\s*사유$/.test(card.label));
            const financialCard = cards.find((card) => /^재무\s*하이라이트$/.test(card.label));
            const trendCard = cards.find((card) => /^최근\s*동향$/.test(card.label));

            const orderedCards = [
                priorityCard,
                financialCard,
                trendCard,
                this.recommendationCard
            ].filter(Boolean);

            return orderedCards.map((card, i) => ({
                ...card,
                number: String(i + 1).padStart(2, '0')
            }));
        }

        // 번호는 추천 카드를 01 로 두고 마지막에 한 번에 매긴다.
        return cards.map((card, i) => ({
            ...card,
            number: String(i + 1).padStart(2, '0')
        }));
    }

    isBriefingSectionLabel(value) {
        return /^(?:[*_]{1,2})?(?:재무\s*하이라이트|최근\s*동향|미팅\s*포인트|우선순위\s*사유)(?:[*_]{1,2})?(?=\s*(?:[:：]|\(|$))/.test(
            (value || '').replace(/^#{1,6}\s*/, '').trim()
        );
    }

    parseBriefingLabel(value) {
        const text = (value || '').replace(/^#{1,6}\s*/, '').trim();
        const match = text.match(
            /^(?:[*_]{1,2})?(재무\s*하이라이트|최근\s*동향|미팅\s*포인트|우선순위\s*사유)(?:[*_]{1,2})?(?=\s*(?:[:：]|\(|\n|[-•·]|$))/
        );
        if (!match) {
            return { label: '', body: value || '' };
        }
        return {
            label: match[1].trim(),
            body: text.slice(match[0].length).replace(/^\s*[:：]\s*/, '').trim()
        };
    }

    get priorityReasonCard() {
        const lines = [];
        if (this.priorityRationaleSummary) {
            lines.push(this.priorityRationaleSummary);
        }
        if (
            this.priorityRationaleDetail &&
            this.priorityRationaleDetail !== this.priorityRationaleSummary
        ) {
            lines.push(this.priorityRationaleDetail);
        }
        if (!lines.length) {
            lines.push('정보 없음');
        }
        const meta = this.metaFor('우선순위 사유');
        return {
            key: 'priority-field',
            number: '',
            label: '우선순위 사유',
            icon: meta.icon,
            score:
                this.priorityScore === null || this.priorityScore === undefined
                    ? ''
                    : String(this.priorityScore),
            note: '',
            noteIcon: 'utility:priority',
            themeStyle: `--accent:${meta.accent};--accent-soft:${meta.accent}14;--accent-line:${meta.accent}40;`,
            asList: true,
            text: '',
            bullets: lines.map((line, index) => ({
                key: `priority-field-${index}`,
                text: line,
                hasChip: false,
                chip: '',
                chipClass: ''
            }))
        };
    }

    get similarWonCard() {
        const result = this.similarWon;
        const bullets = [];
        if (result.insufficientData) {
            bullets.push('조건에 맞는 종결 유사 기회가 없어 확률을 제시하지 않음');
        } else {
            bullets.push(`Won 비율: ${result.wonRate}%`);
            bullets.push(`종결 ${result.totalCount}건 중 Won ${result.wonCount}건`);
        }
        if (result.industry) {
            bullets.push(
                `기준: ${result.industry}${result.productType ? ` · 상품군 ${result.productType}` : ''}`
            );
        }
        const meta = this.metaFor('유사 WON 확률');
        return {
            key: 'similar-won',
            number: '',
            label: '유사 WON 확률',
            icon: meta.icon,
            score: '',
            note: '',
            noteIcon: 'utility:chart',
            themeStyle: `--accent:${meta.accent};--accent-soft:${meta.accent}14;--accent-line:${meta.accent}40;`,
            asList: true,
            text: '',
            bullets: bullets.map((line, index) => ({
                key: `similar-won-${index}`,
                text: line,
                hasChip: false,
                chip: '',
                chipClass: ''
            }))
        };
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

    // 아래 문장들은 생성 시점의 스냅샷이다. 추천 카드만 실시간 필드값이라는 점을
    // 분명히 적는다 — 둘이 달라 보일 때 어느 쪽이 최신인지 RM 이 알아야 한다.
    get updatedLabel() {
        if (!this.updatedAt) {
            return '';
        }
        const when = new Date(this.updatedAt).toLocaleString('ko-KR');
        return `AI 문장 생성: ${when} 기준 (추천 상품 카드는 실시간 값)`;
    }

    get toggleIcon() {
        return this.isExpanded ? 'utility:chevrondown' : 'utility:chevronright';
    }

    get toggleLabel() {
        return this.isExpanded ? '접기' : '펼치기';
    }

    /** aria-expanded 는 문자열이어야 한다. boolean 을 넘기면 속성이 통째로 빠진다. */
    get isExpandedStr() {
        return String(this.isExpanded);
    }

    handleToggle() {
        this.isExpanded = !this.isExpanded;
    }

    get refreshLabel() {
        return this.hasBriefing ? '새로고침' : '브리핑 생성';
    }

    async handleRefresh(showToast = true) {
        // 접힌 채로 새로고침하면 스피너도 결과도 안 보인다. 눌렀으면 결과를 보고 싶은 것.
        this.isExpanded = true;
        this.isGenerating = true;
        try {
            // Opportunity 브리핑은 ContentNote에 저장한다.
            // LDS 갱신은 브리핑 필드가 아니라 ContentNote를 다시 읽어야 하므로 건너뛴다.
            if (!this.isOpportunity) {
                // 추천 필드를 먼저 채운다. generateBriefing 은 프롬프트 템플릿 콜아웃이라
                // 같은 트랜잭션에서 DML 을 먼저 하면 uncommitted work pending 이 난다.
                try {
                    await ensureRecommendation({ recordId: this.recordId });
                    await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
                } catch (ignored) {
                    // 추천 채우기 실패가 브리핑 생성을 막지는 않는다.
                }
            }
            const result = await generateBriefing({ recordId: this.recordId });
            if (this._wired && !this.isOpportunity) {
                await refreshApex(this._wired);
            }
            // Opportunity는 ContentNote 저장 후 생성 응답을 즉시 화면에 표시한다.
            const generatedBriefing = this.normalizeBriefingText(result.briefing);
            const generatedFallback =
                this.isOpportunity && this.isFinancialFallback(generatedBriefing);
            this.briefing = generatedFallback ? undefined : generatedBriefing;
            this.updatedAt = generatedFallback ? undefined : result.updatedAt;
            if (showToast) {
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: '미팅 준비 브리핑',
                        message: '브리핑을 새로 생성했습니다.',
                        variant: 'success'
                    })
                );
            }
        } catch (error) {
            if (showToast) {
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
            }
        } finally {
            this.isGenerating = false;
        }
    }
}