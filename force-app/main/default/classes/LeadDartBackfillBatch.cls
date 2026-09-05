public with sharing class LeadDartBackfillBatch implements Database.Batchable<SObject>, Database.AllowsCallouts, Database.Stateful {
    private static final String NAMED_CREDENTIAL = 'callout:DART_OpenAPI';
    private static final String API_PATH = '/api/company.json';
    private static final Integer TIMEOUT_MS = 120000;

    private Integer successCount = 0;
    private Integer failureCount = 0;

    public Database.QueryLocator start(Database.BatchableContext context) {
        return Database.getQueryLocator([
            SELECT Id, Company, Assigned_Company_Code__c, Phone, Industry,
                   NumberOfEmployees, Website, Business_Registration_Number__c
            FROM Lead
            WHERE IsConverted = false
              AND Assigned_Company_Code__c != null
              AND Phone = null
            WITH USER_MODE
        ]);
    }

    public void execute(Database.BatchableContext context, List<Lead> scope) {
        String crtfcKey = getCrtfcKey();

        Set<String> corpCodes = new Set<String>();
        for (Lead l : scope) {
            corpCodes.add(l.Assigned_Company_Code__c);
        }

        Map<String, Map<String, Object>> companyInfoByCode = new Map<String, Map<String, Object>>();
        for (String corpCode : corpCodes) {
            if (companyInfoByCode.containsKey(corpCode)) {
                continue;
            }
            try {
                Map<String, Object> info = fetchCompanyInfo(corpCode, crtfcKey);
                if (info != null) {
                    companyInfoByCode.put(corpCode, info);
                }
            } catch (Exception e) {
                System.debug('DART callout failed for ' + corpCode + ': ' + e.getMessage());
            }
        }

        List<Lead> toUpdate = new List<Lead>();
        for (Lead l : scope) {
            Map<String, Object> info = companyInfoByCode.get(l.Assigned_Company_Code__c);
            if (info == null) {
                failureCount++;
                continue;
            }
            Boolean changed = false;

            String phone = (String) info.get('phn_no');
            if (String.isNotBlank(phone) && String.isBlank(l.Phone)) {
                l.Phone = phone;
                changed = true;
            }

            String website = (String) info.get('hm_url');
            if (String.isNotBlank(website) && String.isBlank(l.Website)) {
                if (!website.startsWith('http')) {
                    website = 'https://' + website;
                }
                l.Website = website;
                changed = true;
            }

            String bizrNo = (String) info.get('bizr_no');
            if (String.isNotBlank(bizrNo) && String.isBlank(l.Business_Registration_Number__c)) {
                l.Business_Registration_Number__c = bizrNo.replaceAll('[^0-9]', '');
                changed = true;
            }

            String adres = (String) info.get('adres');
            if (String.isNotBlank(adres) && String.isBlank(l.Street)) {
                l.Street = adres;
                changed = true;
            }

            if (changed) {
                toUpdate.add(l);
            }
        }

        if (!toUpdate.isEmpty()) {
            List<Database.SaveResult> results = Database.update(toUpdate, false, AccessLevel.USER_MODE);
            for (Database.SaveResult r : results) {
                if (r.isSuccess()) {
                    successCount++;
                } else {
                    failureCount++;
                    for (Database.Error e : r.getErrors()) {
                        System.debug('DML FAIL: ' + e.getStatusCode() + ' - ' + e.getMessage() + ' fields: ' + e.getFields());
                    }
                }
            }
        }
    }

    public void finish(Database.BatchableContext context) {
        System.debug('Lead DART 백필 완료. 성공: ' + successCount + ', 실패: ' + failureCount);
    }

    private static Map<String, Object> fetchCompanyInfo(String corpCode, String crtfcKey) {
        String endpoint = NAMED_CREDENTIAL + API_PATH
            + '?crtfc_key=' + EncodingUtil.urlEncode(crtfcKey, 'UTF-8')
            + '&corp_code=' + EncodingUtil.urlEncode(corpCode, 'UTF-8');

        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('GET');
        req.setTimeout(TIMEOUT_MS);

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            return null;
        }

        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        String status = (String) body.get('status');
        if (status != '000') {
            return null;
        }
        return body;
    }

    private static String getCrtfcKey() {
        DART_Setting__mdt setting = DART_Setting__mdt.getInstance('Default');
        if (setting == null || String.isBlank(setting.Crtfc_Key__c)) {
            throw new DartFinancialService.DartServiceException(
                'DART 인증키가 설정되지 않았습니다.'
            );
        }
        return setting.Crtfc_Key__c;
    }
}