// RM_Assistant_Access 권한세트에 신규 Case 필드 2개의 FLS(read/edit)를 부여한다.
// 권한세트 메타 배포 대신 FieldPermissions 데이터 upsert 로 처리한다
// (메타 배포 시 org 에 데이터로 들어간 Contact FLS 등이 유실될 위험을 피함 — 팀 관례).
// 실행:  sf apex run -f scripts/add-fls-case-fields.apex -o <org>
PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'RM_Assistant_Access' LIMIT 1];

Set<String> wanted = new Set<String>{
    'Case.Agreed_Yield_Rate__c',
    'Case.Contract_Term_Months__c'
};

Map<String, FieldPermissions> existing = new Map<String, FieldPermissions>();
for (FieldPermissions fp : [
    SELECT Id, Field FROM FieldPermissions
    WHERE ParentId = :ps.Id AND Field IN :wanted
]) {
    existing.put(fp.Field, fp);
}

List<FieldPermissions> toUpsert = new List<FieldPermissions>();
for (String f : wanted) {
    FieldPermissions fp = existing.containsKey(f)
        ? existing.get(f)
        : new FieldPermissions(ParentId = ps.Id, SobjectType = 'Case', Field = f);
    fp.PermissionsRead = true;
    fp.PermissionsEdit = true;
    toUpsert.add(fp);
}

upsert toUpsert;
System.debug('RM_Assistant_Access FLS 부여 완료: ' + toUpsert.size() + '개 필드');
