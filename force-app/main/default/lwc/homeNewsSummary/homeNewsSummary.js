import { LightningElement, wire } from 'lwc';
import getDailySummary from '@salesforce/apex/HomeDashboardController.getDailySummary';
import getPriorityNews from '@salesforce/apex/HomeDashboardController.getPriorityNews';

export default class HomeNewsSummary extends LightningElement {
    summary;
    news;
    newsError;

    // News card filter: 'all' | 'industry'
    newsFilter = 'all';
    today = new Date().toISOString();

    @wire(getDailySummary)
    wiredSummary({ data, error }) {
        if (data !== undefined) {
            this.summary = data;
        } else if (error) {
            this.summary = undefined;
        }
    }

    @wire(getPriorityNews)
    wiredNews({ data, error }) {
        if (data) {
            this.news = data.map((signal) => {
                const partyName = signal.Account__r
                    ? signal.Account__r.Name
                    : signal.Lead__r
                    ? signal.Lead__r.Company
                    : signal.Industry__c;
                const categoryLabel = partyName || signal.Industry__c || '뉴스';
                // Raw industry: explicit signal industry first, then the linked
                // account's/lead's industry. Used for KSIC grouping.
                const industrySource =
                    signal.Industry__c ||
                    (signal.Account__r && signal.Account__r.Industry) ||
                    (signal.Lead__r && signal.Lead__r.Industry) ||
                    null;
                return {
                    ...signal,
                    partyName,
                    categoryLabel,
                    industrySource,
                    // Signal matched only by industry (no linked account/lead)
                    isIndustryOnly: !signal.Account__c && !signal.Lead__c,
                    badgeClass: 'ncard__badge ' + this.colorClassFor(categoryLabel),
                    // Resolve a working destination: real article URL when present,
                    // otherwise a live news search for the headline.
                    linkUrl: this.resolveNewsUrl(signal.Source_URL__c, signal.Title__c)
                };
            });
            this.newsError = undefined;
        } else if (error) {
            this.newsError = this.reduceError(error);
            this.news = undefined;
        }
    }

    // ─── Derived getters ─────────────────────────────────────────────
    get hasNews() {
        return this.news && this.news.length > 0;
    }

    get hasSummary() {
        return !!this.summary;
    }

    // ─── News card getters ───────────────────────────────────────────
    get newsCount() {
        return this.news ? this.news.length : 0;
    }

    // Most frequent industry across today's news.
    get topIndustry() {
        if (!this.hasNews) {
            return '—';
        }
        const counts = {};
        this.news.forEach((n) => {
            // Industry can come from the signal itself or the linked
            // account/lead, so reuse the same resolved source the 산업군 tab
            // groups by — otherwise signals without Industry__c are ignored
            // and 핵심 산업 falls back to '—'.
            const industry = n.industrySource;
            if (industry) {
                counts[industry] = (counts[industry] || 0) + 1;
            }
        });
        let best = '—';
        let max = 0;
        Object.keys(counts).forEach((key) => {
            if (counts[key] > max) {
                max = counts[key];
                best = key;
            }
        });
        return best;
    }

    // Highest-priority linked company (news is already priority-ordered).
    get topParty() {
        if (!this.hasNews) {
            return '—';
        }
        const withCompany = this.news.find((n) => n.Account__c || n.Lead__c);
        return (withCompany && withCompany.partyName) || this.news[0].partyName || '—';
    }

    // One-line insight, always aligned with the featured (주목) news card so
    // it can never reference a different company than the top news item.
    get insight() {
        if (this.hasNews) {
            const top = this.news[0];
            const who = top.partyName || top.Industry__c;
            const headline = (top.Summary__c || top.Title__c || '')
                .replace(/\[[^\]]*\]/g, '')
                .trim();
            if (who && headline) {
                return `${who}의 ${headline} — 오늘 포트폴리오에서 가장 주목할 뉴스입니다.`;
            }
            if (who) {
                return `${who} 관련 소식이 오늘 포트폴리오에서 가장 주목할 뉴스입니다.`;
            }
        }
        // Fallback: parse the stored AI daily summary when no priority news exists.
        if (!this.summary) {
            return null;
        }
        const lines = this.summary.split(/\r?\n/);
        for (const line of lines) {
            const match = line.match(/한\s*줄[^:：]*[:：]\s*(.+)/);
            if (match) {
                return match[1].trim();
            }
        }
        const firstLine = lines.find((l) => l.trim());
        return firstLine ? firstLine.trim() : null;
    }

    get isAllFilter() {
        return this.newsFilter !== 'industry';
    }

    // Renderable news as a list of sections. '전체' is one unnamed section
    // (unchanged flat grid); '산업군' is one section per KSIC 대분류 so the
    // same card markup renders both views.
    get sections() {
        if (!this.hasNews) {
            return [];
        }
        if (this.isAllFilter) {
            return [
                {
                    key: 'all',
                    label: null,
                    showHeader: false,
                    count: this.news.length,
                    items: this.news.map((n, index) => ({
                        ...n,
                        featured: index === 0,
                        cardClass: index === 0 ? 'ncard ncard_featured' : 'ncard'
                    }))
                }
            ];
        }
        // Group by KSIC 대분류.
        const groups = new Map();
        this.news.forEach((n) => {
            const label = this.ksicSection(n.industrySource);
            if (!groups.has(label)) {
                groups.set(label, []);
            }
            groups.get(label).push({ ...n, featured: false, cardClass: 'ncard' });
        });
        const result = Array.from(groups.entries()).map(([label, items]) => ({
            key: 'ksic-' + label,
            label,
            showHeader: true,
            count: items.length,
            items
        }));
        // Most-covered industry first; '기타'(미분류) always last.
        result.sort((a, b) => {
            if (a.label === '기타') return 1;
            if (b.label === '기타') return -1;
            if (b.count !== a.count) return b.count - a.count;
            return a.label.localeCompare(b.label, 'ko');
        });
        return result;
    }

    get hasSections() {
        return this.sections.length > 0;
    }

    // Normalize any raw industry value to a KSIC 대분류 (top-level section).
    ksicSection(raw) {
        if (!raw) {
            return '기타';
        }
        const value = String(raw).trim();
        if (!value) {
            return '기타';
        }
        // Numeric KSIC code → section by its leading 2-digit division.
        if (/^\d+$/.test(value)) {
            return this.ksicByCode(value);
        }
        // Common sub-industry shorthands used in the org that are not
        // 대분류-level labels themselves.
        const aliases = {
            반도체: '제조업',
            디스플레이: '제조업',
            '2차전지': '제조업',
            배터리: '제조업',
            바이오: '제조업',
            제약: '제조업',
            화장품: '제조업',
            자동차: '제조업',
            철강: '제조업',
            게임: '정보통신업',
            소프트웨어: '정보통신업',
            IT: '정보통신업'
        };
        // Otherwise the value is already a 대분류-level label; keep as-is.
        return aliases[value] || value;
    }

    // Map a raw KSIC numeric code to its 대분류 by leading 2-digit division.
    ksicByCode(code) {
        const n = parseInt(code.slice(0, 2), 10);
        if (n >= 1 && n <= 3) return '농업, 임업 및 어업';
        if (n >= 5 && n <= 8) return '광업';
        if (n >= 10 && n <= 34) return '제조업';
        if (n === 35) return '전기, 가스, 증기 및 공기 조절 공급업';
        if (n >= 36 && n <= 39) return '수도, 하수 및 폐기물 처리, 원료 재생업';
        if (n >= 41 && n <= 42) return '건설업';
        if (n >= 45 && n <= 47) return '도매 및 소매업';
        if (n >= 49 && n <= 52) return '운수 및 창고업';
        if (n >= 55 && n <= 56) return '숙박 및 음식점업';
        if (n >= 58 && n <= 63) return '정보통신업';
        if (n >= 64 && n <= 66) return '금융 및 보험업';
        if (n === 68) return '부동산업';
        if (n >= 70 && n <= 73) return '전문, 과학 및 기술 서비스업';
        if (n >= 74 && n <= 76) return '사업시설 관리, 사업 지원 및 임대 서비스업';
        if (n === 84) return '공공행정, 국방 및 사회보장 행정';
        if (n === 85) return '교육 서비스업';
        if (n >= 86 && n <= 87) return '보건업 및 사회복지 서비스업';
        if (n >= 90 && n <= 91) return '예술, 스포츠 및 여가관련 서비스업';
        if (n >= 94 && n <= 96) return '협회 및 단체, 수리 및 기타 개인 서비스업';
        return '기타';
    }

    get allBtnClass() {
        return 'seg__btn' + (this.newsFilter === 'all' ? ' seg__btn_active' : '');
    }

    get industryBtnClass() {
        return 'seg__btn' + (this.newsFilter === 'industry' ? ' seg__btn_active' : '');
    }

    // Stable badge color derived from the category label.
    colorClassFor(label) {
        const palette = [
            'badge_blue',
            'badge_green',
            'badge_purple',
            'badge_orange',
            'badge_teal'
        ];
        let hash = 0;
        const text = label || '';
        for (let i = 0; i < text.length; i++) {
            hash = (hash * 31 + text.charCodeAt(i)) >>> 0;
        }
        return palette[hash % palette.length];
    }

    // Returns a real article URL when the source is a genuine external link,
    // otherwise falls back to a Naver News search for the headline so the
    // card always lands on live news instead of a dummy placeholder.
    resolveNewsUrl(sourceUrl, title) {
        const isRealUrl =
            typeof sourceUrl === 'string' &&
            /^https?:\/\//i.test(sourceUrl) &&
            !/dummy\.news\.local/i.test(sourceUrl);
        if (isRealUrl) {
            return sourceUrl;
        }
        // Strip leading tags like "[산업군]" for a cleaner search query.
        const query = (title || '뉴스').replace(/\[[^\]]*\]/g, '').trim() || '뉴스';
        return (
            'https://search.naver.com/search.naver?where=news&query=' +
            encodeURIComponent(query)
        );
    }

    handleFilter(event) {
        this.newsFilter = event.currentTarget.dataset.filter;
    }

    reduceError(error) {
        return error?.body?.message || 'Unknown error';
    }
}