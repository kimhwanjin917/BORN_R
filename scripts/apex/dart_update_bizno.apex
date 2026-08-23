// 6개 법인 Account의 사업자등록번호를 DART 기업개황 API 실제값으로 최신화.
// 콜아웃 후 DML 순서를 지키기 위해 값을 먼저 모두 수집한 뒤 한 번에 update 한다.
String key = DART_Setting__mdt.getInstance('Default').Crtfc_Key__c;

List<Account> accounts = [
    SELECT Id, Name, Assigned_Company_Code__c, Business_Registration_Number__c
    FROM Account
    WHERE Assigned_Company_Code__c != null
    WITH USER_MODE
];

List<Account> toUpdate = new List<Account>();
for (Account acct : accounts) {
    String endpoint = 'callout:DART_OpenAPI/api/company.json'
        + '?crtfc_key=' + EncodingUtil.urlEncode(key, 'UTF-8')
        + '&corp_code=' + acct.Assigned_Company_Code__c;
    HttpRequest req = new HttpRequest();
    req.setEndpoint(endpoint);
    req.setMethod('GET');
    req.setTimeout(120000);
    HttpResponse res = new Http().send(req);
    Map<String, Object> m = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());

    String status = (String) m.get('status');
    String bizrNo = (String) m.get('bizr_no');
    if (status != '000' || String.isBlank(bizrNo)) {
        System.debug('SKIP ' + acct.Name + ' | status=' + status + ' | bizr_no=' + bizrNo);
        continue;
    }
    bizrNo = bizrNo.replaceAll('[^0-9]', ''); // 하이픈 등 제거, 숫자만
    System.debug('UPDATE ' + acct.Name + ' | ' + acct.Business_Registration_Number__c + ' -> ' + bizrNo);
    acct.Business_Registration_Number__c = bizrNo;
    toUpdate.add(acct);
}

List<Database.SaveResult> results = Database.update(toUpdate, false, AccessLevel.USER_MODE);
Integer ok = 0;
for (Database.SaveResult r : results) {
    if (r.isSuccess()) { ok++; }
    else { System.debug('DML FAIL: ' + r.getErrors()); }
}
System.debug('사업자번호 업데이트 완료: ' + ok + '/' + toUpdate.size());
