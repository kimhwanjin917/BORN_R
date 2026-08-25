// 뉴스 시그널 더미 데이터 사전 적재 (백로그 32 - 뉴스 AI 일일 요약).
// 실연동 없이 담당 기업(주인공/Top3)·산업군 뉴스를 ExternalSignal__c 로 사전 적재한다.
// External_Key__c(자연키) 기준 upsert 라 재실행해도 중복 없이 갱신된다.
//
// 기업 뉴스: corp_code 로 Account/Lead 를 찾아 룩업 연결.
// 산업군 뉴스: 회사 룩업 없이 Industry__c 값으로만 연결(반도체전자/자동차부품/화장품ODM).

final String NEWS = '뉴스';
final Date TODAY = Date.today();
final String VIEWER = 'https://dummy.news.local/';

// corp_code → Account/Lead Id 매핑(담당 기업 전체)
Map<String, Id> acctByCorp = new Map<String, Id>();
for (Account a : [
    SELECT Id, Assigned_Company_Code__c
    FROM Account
    WHERE Assigned_Company_Code__c != null
    WITH USER_MODE
]) {
    acctByCorp.put(a.Assigned_Company_Code__c, a.Id);
}
Map<String, Id> leadByCorp = new Map<String, Id>();
for (Lead l : [
    SELECT Id, Assigned_Company_Code__c
    FROM Lead
    WHERE Assigned_Company_Code__c != null AND IsConverted = false
    WITH USER_MODE
]) {
    leadByCorp.put(l.Assigned_Company_Code__c, l.Id);
}

List<ExternalSignal__c> signals = new List<ExternalSignal__c>();

// ── 기업 뉴스 (corp_code, 일수 전, 제목, 요약, 관련도) ──
// 성우하이텍(00132992) / 리노공업(00369657) / 하나마이크론(00445054)
// 하나기술(00601191) / 씨앤씨인터내셔널(01226410) / 코스메카코리아(00763473)
List<List<Object>> corpNews = new List<List<Object>>{
    new List<Object>{ '00132992', 1, '북미 전기차 OEM에 차체 경량화 부품 공급계약', '알루미늄 핫스탬핑 부품 다년 공급, 연 매출 기여 예상', 80 },
    new List<Object>{ '00132992', 6, '헝가리 공장 증설 완료…유럽 EV 대응', '현지 생산능력 확대로 관세·물류 리스크 완화', 70 },
    new List<Object>{ '00369657', 2, 'AI 반도체 테스트 소켓 수요 급증, 2Q 실적 서프라이즈', '고부가 소켓 비중 확대로 영업이익률 개선', 85 },
    new List<Object>{ '00369657', 9, 'HBM 검사용 신제품 양산 진입', '주요 메모리 고객사 승인, 하반기 매출 반영', 80 },
    new List<Object>{ '00445054', 3, '브라질 법인 반도체 패키징 신규 라인 가동', '후공정 캐파 확대, 글로벌 고객 다변화', 75 },
    new List<Object>{ '00445054', 8, '2차전지 부품 자회사 실적 부진에 수익성 압박', '반도체 본업은 견조하나 자회사 손실 지속', 60 },
    new List<Object>{ '00601191', 4, '유럽 배터리셀 업체와 조립장비 수주', '각형·원통형 라인 턴키 공급, 수주잔고 확대', 80 },
    new List<Object>{ '00601191', 11, '전고체 배터리 파일럿 장비 개발 착수', '차세대 라인업 선점 목적 R&D 투자', 65 },
    new List<Object>{ '01226410', 2, '글로벌 인디 브랜드향 립 제품 수주 확대', '색조 ODM 호조로 분기 최대 매출 경신', 80 },
    new List<Object>{ '01226410', 7, '제2공장 증설로 생산능력 2배', '늘어난 해외 수요 대응 위한 설비투자 집행', 70 },
    new List<Object>{ '00763473', 3, '미국 자회사 잉글우드랩 흑자 전환', '북미 ODM 수요 회복으로 수익성 개선', 70 },
    new List<Object>{ '00763473', 10, 'K-뷰티 수출 호조에 하반기 가이던스 상향', '중소 브랜드 물량 증가로 가동률 상승', 65 }
};

Integer seq = 0;
for (List<Object> row : corpNews) {
    String corp = (String) row[0];
    ExternalSignal__c s = new ExternalSignal__c();
    s.Account__c = acctByCorp.get(corp);
    s.Lead__c = leadByCorp.get(corp);
    s.External_Key__c = 'NEWS_' + corp + '_' + String.valueOf(seq++);
    s.Signal_Type__c = NEWS;
    s.Title__c = (String) row[2];
    s.Summary__c = (String) row[3];
    s.Signal_Date__c = TODAY.addDays(-((Integer) row[1]));
    s.Source_URL__c = VIEWER + s.External_Key__c;
    s.Relevance_Score__c = (Integer) row[4];
    s.Confidence__c = 60;
    signals.add(s);
}

// ── 산업군 뉴스 (Industry__c 는 org 제한 피클리스트라 KSIC 값으로 매핑) ──
// 반도체전자/자동차부품/화장품ODM 은 모두 제조사 → KSIC '제조업'.
// External_Key__c 는 원 산업 라벨로 구분해 3건이 하나로 합쳐지지 않게 한다.
List<List<Object>> industryNews = new List<List<Object>>{
    new List<Object>{ '반도체전자', '제조업', 1, 'AI·HBM 붐에 후공정·테스트 장비 투자 확대', '메모리 업황 반등으로 소부장 수혜 전망', 75 },
    new List<Object>{ '자동차부품', '제조업', 2, '전기차 전환에 차체 경량화 부품 수요 증가', '알루미늄·핫스탬핑 채택 확대', 70 },
    new List<Object>{ '화장품ODM', '제조업', 2, 'K-뷰티 수출 사상 최대…ODM 수주 러시', '인디 브랜드 성장으로 색조 물량 급증', 70 }
};
for (List<Object> row : industryNews) {
    String label = (String) row[0];
    String ksic = (String) row[1];
    ExternalSignal__c s = new ExternalSignal__c();
    s.Industry__c = ksic;
    s.External_Key__c = 'NEWS_IND_' + label;
    s.Signal_Type__c = NEWS;
    s.Title__c = '[산업군] ' + (String) row[3];
    s.Summary__c = (String) row[4];
    s.Signal_Date__c = TODAY.addDays(-((Integer) row[2]));
    s.Source_URL__c = VIEWER + s.External_Key__c;
    s.Relevance_Score__c = (Integer) row[5];
    s.Confidence__c = 60;
    signals.add(s);
}

Database.UpsertResult[] results = Database.upsert(signals, ExternalSignal__c.External_Key__c, AccessLevel.USER_MODE);
Integer ok = 0;
for (Database.UpsertResult r : results) {
    if (r.isSuccess()) ok++;
}
System.debug('뉴스 시그널 upsert 완료: ' + ok + '/' + signals.size());
