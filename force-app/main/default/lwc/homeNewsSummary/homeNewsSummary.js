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
                return {
                    ...signal,
                    partyName,
                    categoryLabel,
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
            if (n.Industry__c) {
                counts[n.Industry__c] = (counts[n.Industry__c] || 0) + 1;
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

    // One-line insight parsed from the daily summary text.
    get insight() {
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

    get displayNews() {
        if (!this.news) {
            return [];
        }
        const filtered =
            this.newsFilter === 'industry'
                ? this.news.filter((n) => n.isIndustryOnly)
                : this.news;
        return filtered.map((n, index) => ({
            ...n,
            featured: index === 0,
            cardClass: index === 0 ? 'ncard ncard_featured' : 'ncard'
        }));
    }

    get hasDisplayNews() {
        return this.displayNews.length > 0;
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
