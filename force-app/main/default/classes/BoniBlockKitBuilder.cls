/** BoniDashboardData → Slack Block Kit. 순수 함수(SOQL·콜아웃 없음). */
public with sharing class BoniBlockKitBuilder {

    public static final String ACTION_REFRESH = 'boni_refresh';
    public static final String ACTION_OPEN_HOME = 'boni_open_home';
    public static final String ACTION_PREP = 'boni_prep_card';
    public static final String ACTION_ROLLOVER = 'boni_rollover';
    private static final Integer PER_SECTION = 5;
    private static final String HOME_DEEPLINK = 'slack://app?team=T0BHXM8CFFS&id=A0BSJ6W4F96&tab=home';
    private static final List<String> WEEKDAYS_KO = new List<String>{ '월', '화', '수', '목', '금', '토', '일' };

    // ── public entry points ───────────────────────────────────────────
    public static Map<String, Object> homeView(BoniDashboardData d) {
        List<Object> blocks = new List<Object>();
        blocks.add(header('근본증권 보니 · ' + dateKo(d.today) + ' :boni_wave:'));
        blocks.add(actions(new List<Object>{ button('새로고침', ACTION_REFRESH, 'refresh', false) }));
        blocks.add(divider());
        blocks.addAll(eventsSection(d, true));
        blocks.add(divider());
        blocks.addAll(maturitySection(d, true));
        blocks.add(divider());
        blocks.addAll(signalSection(d));
        blocks.add(divider());
        blocks.addAll(pipelineSection(d));
        blocks.add(divider());
        blocks.addAll(taskSection(d));
        blocks.add(divider());
        blocks.add(context('마지막 갱신 ' + timeKo(d.generatedAt) + ' · 보니에게 물어보기는 준비 중이에요'));
        return new Map<String, Object>{ 'type' => 'home', 'blocks' => blocks };
    }

    public static List<Object> briefingBlocks(BoniDashboardData d) {
        List<Object> blocks = new List<Object>();
        blocks.add(header('좋은 아침이에요! ' + dateKo(d.today) + ' 브리핑 :boni_front:'));
        blocks.addAll(eventsSection(d, false));
        blocks.addAll(maturitySection(d, false));
        blocks.addAll(taskSection(d));
        if (d.events.isEmpty() && d.maturities.isEmpty() && d.tasks.isEmpty()) {
            blocks.add(section('오늘은 여유로운 날이에요 :boni_34:'));
        }
        blocks.add(actions(new List<Object>{ linkButton('홈에서 전체 보기', ACTION_OPEN_HOME, HOME_DEEPLINK) }));
        return blocks;
    }

    public static String briefingText(BoniDashboardData d) {
        return dateKo(d.today) + ' 브리핑 · 일정 ' + d.events.size() + ' · 만기 ' + d.maturities.size() + ' · 할 일 ' + d.tasks.size();
    }

    public static List<Object> wrapupBlocks(BoniDashboardData d) {
        BoniDashboardData.WrapupData w = d.wrapup == null ? new BoniDashboardData.WrapupData() : d.wrapup;
        List<Object> blocks = new List<Object>();
        blocks.add(header('오늘도 수고하셨어요 · ' + dateKo(d.today) + ' 마감 :boni_flag:'));
        String opps = w.updatedOpps.isEmpty() ? '오늘 갱신된 딜이 없습니다' : '• ' + String.join(limitList(w.updatedOpps), '\n• ');
        blocks.add(section('*오늘 갱신된 딜 ' + w.updatedOpps.size() + '건*\n' + opps));
        blocks.add(section('*할 일* 완료 ' + w.completedTasks + '건 · 이월 ' + w.carriedTasks + '건'));
        if (w.tomorrowFirst != null) {
            blocks.add(section('*내일 첫 일정* ' + timeKo(w.tomorrowFirst.startAt) + ' ' + safe(w.tomorrowFirst.subject)
                + (String.isBlank(w.tomorrowFirst.accountName) ? '' : ' · ' + w.tomorrowFirst.accountName)));
        }
        if (!w.teamLines.isEmpty()) blocks.add(section('*팀 집계*\n• ' + String.join(w.teamLines, '\n• ')));
        return blocks;
    }

    public static String wrapupText(BoniDashboardData d) {
        BoniDashboardData.WrapupData w = d.wrapup == null ? new BoniDashboardData.WrapupData() : d.wrapup;
        return dateKo(d.today) + ' 마감 · 갱신 ' + w.updatedOpps.size() + ' · 완료 ' + w.completedTasks + ' · 이월 ' + w.carriedTasks;
    }

    public static String formatKrw(Decimal amount) {
        if (amount == null || amount == 0) return '0원';
        Decimal a = amount.abs();
        if (a >= 1000000000000L) return trimZero((a / 1000000000000L).setScale(1)) + '조';
        if (a >= 100000000) return withComma((a / 100000000).setScale(0)) + '억';
        if (a >= 10000) return withComma((a / 10000).setScale(0)) + '만';
        return withComma(a.setScale(0)) + '원';
    }

    // ── sections ──────────────────────────────────────────────────────
    private static List<Object> eventsSection(BoniDashboardData d, Boolean withButtons) {
        List<Object> out = new List<Object>{ section('*:calendar: 오늘 일정*') };
        if (d.events.isEmpty()) {
            out.add(context(d.calendarConnected ? '오늘 일정이 없습니다' : '오늘 일정이 없습니다 · Google 캘린더 연결 확인'));
            return out;
        }
        Integer n = 0;
        for (BoniDashboardData.EventItem e : d.events) {
            if (n++ >= PER_SECTION) break;
            String line = '`' + timeKo(e.startAt) + '`  ' + safe(e.subject)
                + (String.isBlank(e.accountName) ? '' : ' · ' + e.accountName)
                + (String.isBlank(e.location) ? '' : ' · ' + e.location);
            if (withButtons) out.add(sectionWithButton(line, button('준비카드 보기', ACTION_PREP, String.valueOf(e.id), false)));
            else out.add(section(line));
        }
        addMore(out, d.events.size());
        return out;
    }

    private static List<Object> maturitySection(BoniDashboardData d, Boolean withButtons) {
        List<Object> out = new List<Object>{ section('*:alarm_clock: 만기 도래*') };
        if (d.maturities.isEmpty()) { out.add(context('7일 내 만기 없음')); return out; }
        Integer n = 0;
        for (BoniDashboardData.MaturityItem m : d.maturities) {
            if (n++ >= PER_SECTION) break;
            String line = '*D-' + m.daysLeft + '*  ' + safe(m.accountName) + ' ' + safe(m.productName) + ' ' + formatKrw(m.amount)
                + ' (' + m.maturityDate.month() + '/' + m.maturityDate.day() + ')';
            if (withButtons) out.add(sectionWithButton(line, button('롤오버 제안', ACTION_ROLLOVER, String.valueOf(m.oppId), true)));
            else out.add(section(line));
        }
        addMore(out, d.maturities.size());
        return out;
    }

    private static List<Object> signalSection(BoniDashboardData d) {
        List<Object> out = new List<Object>{ section('*:satellite_antenna: 고객 시그널*') };
        if (d.signals.isEmpty()) { out.add(context('최근 시그널 없음')); return out; }
        Integer n = 0;
        for (BoniDashboardData.SignalItem s : d.signals) {
            if (n++ >= PER_SECTION) break;
            out.add(section('• ' + safe(s.accountName) + ' — ' + safe(s.title) + ' (' + s.signalDate.month() + '/' + s.signalDate.day()
                + ') · 연관성 ' + (s.relevance == null ? '-' : String.valueOf(s.relevance.intValue()))));
        }
        addMore(out, d.signals.size());
        return out;
    }

    private static List<Object> pipelineSection(BoniDashboardData d) {
        BoniDashboardData.PipelineSummary p = d.pipeline;
        return new List<Object>{
            section('*:bar_chart: 파이프라인*'),
            section('이번 주 마감 ' + p.closingThisWeek + '건 / ' + formatKrw(p.closingAmount) + ' · 정체 ' + p.stale + '건 · 열린 딜 ' + p.openTotal + '건')
        };
    }

    private static List<Object> taskSection(BoniDashboardData d) {
        List<Object> out = new List<Object>{ section('*:white_check_mark: 할 일*') };
        if (d.tasks.isEmpty()) { out.add(context('밀린 할 일이 없습니다')); return out; }
        Integer n = 0;
        for (BoniDashboardData.TaskItem t : d.tasks) {
            if (n++ >= PER_SECTION) break;
            out.add(section('☐ ' + safe(t.subject) + (t.overdueDays != null && t.overdueDays > 0 ? ' (지연 ' + t.overdueDays + '일)' : '')));
        }
        addMore(out, d.tasks.size());
        return out;
    }

    // ── block primitives ──────────────────────────────────────────────
    private static Map<String, Object> header(String text) {
        return new Map<String, Object>{ 'type' => 'header', 'text' => new Map<String, Object>{ 'type' => 'plain_text', 'text' => text, 'emoji' => true } };
    }
    private static Map<String, Object> section(String mrkdwn) {
        return new Map<String, Object>{ 'type' => 'section', 'text' => new Map<String, Object>{ 'type' => 'mrkdwn', 'text' => mrkdwn } };
    }
    private static Map<String, Object> sectionWithButton(String mrkdwn, Map<String, Object> btn) {
        Map<String, Object> s = section(mrkdwn); s.put('accessory', btn); return s;
    }
    private static Map<String, Object> context(String mrkdwn) {
        return new Map<String, Object>{ 'type' => 'context', 'elements' => new List<Object>{ new Map<String, Object>{ 'type' => 'mrkdwn', 'text' => mrkdwn } } };
    }
    private static Map<String, Object> divider() { return new Map<String, Object>{ 'type' => 'divider' }; }
    private static Map<String, Object> actions(List<Object> elements) { return new Map<String, Object>{ 'type' => 'actions', 'elements' => elements }; }
    private static Map<String, Object> button(String label, String actionId, String value, Boolean primary) {
        Map<String, Object> b = new Map<String, Object>{ 'type' => 'button', 'action_id' => actionId, 'value' => value,
            'text' => new Map<String, Object>{ 'type' => 'plain_text', 'text' => label, 'emoji' => true } };
        if (primary) b.put('style', 'primary');
        return b;
    }
    private static Map<String, Object> linkButton(String label, String actionId, String url) {
        Map<String, Object> b = button(label, actionId, 'open', false); b.put('url', url); return b;
    }
    private static void addMore(List<Object> out, Integer total) {
        if (total > PER_SECTION) out.add(context((total - PER_SECTION) + '건 더'));
    }

    // ── formatting ────────────────────────────────────────────────────
    private static String dateKo(Date d) {
        if (d == null) return '';
        Integer dow = Math.mod(Date.newInstance(1900, 1, 1).daysBetween(d), 7); // 1900-01-01 = 월
        return d.month() + '월 ' + d.day() + '일 (' + WEEKDAYS_KO[dow] + ')';
    }
    private static String timeKo(Datetime dt) { return dt == null ? '' : dt.format('HH:mm', 'Asia/Seoul'); }
    private static String safe(String s) { return s == null ? '' : s; }
    private static List<String> limitList(List<String> src) {
        List<String> out = new List<String>();
        for (Integer i = 0; i < src.size() && i < PER_SECTION; i++) out.add(src[i]);
        if (src.size() > PER_SECTION) out.add('… ' + (src.size() - PER_SECTION) + '건 더');
        return out;
    }
    private static String trimZero(Decimal v) { String s = String.valueOf(v); return s.endsWith('.0') ? s.substring(0, s.length() - 2) : s; }
    private static String withComma(Decimal v) { return v.longValue().format(); }
}