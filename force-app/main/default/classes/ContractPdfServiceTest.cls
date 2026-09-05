/**
 * ContractPdfService 테스트.
 * 팀 공용 TestDataFactory 는 쓰지 않고 이 클래스의 @TestSetup 으로만 데이터를 만든다.
 * 실제 PDF 렌더링(getContentAsPDF)은 테스트 컨텍스트에서 쓸 수 없어 서비스가 대체 Blob 을 쓴다.
 */
@IsTest
private class ContractPdfServiceTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(Name = 'PDF서비스 법인', Business_Registration_Number__c = '5555555555');
        insert acc;

        insert new Contract(
            AccountId = acc.Id,
            Status = 'Draft',
            StartDate = Date.newInstance(2026, 9, 1),
            ContractTerm = 3,
            Maturity_Date__c = Date.newInstance(2026, 11, 30),
            Contract_Amount__c = 500000000,
            RP_Yield__c = 3.2,
            Fee_Rate__c = 0.15
        );
    }

    private static Contract theContract() {
        return [SELECT Id, ContractNumber FROM Contract LIMIT 1];
    }

    @IsTest
    static void attachesPdfToContract() {
        Contract c = theContract();

        Test.startTest();
        ContractPdfService.Result r = ContractPdfService.generate(c.Id);
        Test.stopTest();

        Assert.isTrue(r.success, 'PDF 생성이 성공해야 한다');
        Assert.areEqual(c.ContractNumber, r.contractNumber, '계약번호를 돌려줘야 한다');
        Assert.isNotNull(r.contentDocumentId, '첨부 문서 Id 를 돌려줘야 한다');

        List<ContentDocumentLink> links = [
            SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = :c.Id
        ];
        Assert.areEqual(1, links.size(), '계약에 파일이 1건 붙어야 한다');
    }

    @IsTest
    static void fileNameUsesContractNumberAndAccount() {
        Contract c = [SELECT Id, ContractNumber, Account.Name FROM Contract LIMIT 1];

        Test.startTest();
        String name = ContractPdfService.fileNameFor(c);
        Test.stopTest();

        Assert.isTrue(name.startsWith('계약서_' + c.ContractNumber), '계약번호가 파일명에 들어가야 한다');
        Assert.isTrue(name.contains('PDF서비스 법인'), '고객사명이 파일명에 들어가야 한다');
        Assert.isTrue(name.endsWith('.pdf'), '확장자는 pdf');
    }

    @IsTest
    static void warnsWhenContractIdIsNull() {
        Test.startTest();
        ContractPdfService.Result r = ContractPdfService.generate(null);
        Test.stopTest();

        Assert.isFalse(r.success, 'null 이면 실패여야 한다');
        Assert.isTrue(r.message.contains('찾을 수 없습니다'), '안내 문구가 있어야 한다');
    }

    @IsTest
    static void warnsWhenContractMissing() {
        Test.startTest();
        ContractPdfService.Result r = ContractPdfService.generate('800000000000000AAA');
        Test.stopTest();

        Assert.isFalse(r.success, '없는 계약이면 실패여야 한다');
        Assert.isTrue(r.message.contains('찾을 수 없습니다'), '안내 문구가 있어야 한다');
    }

    @IsTest
    static void generatesTwiceKeepsBothFiles() {
        Contract c = theContract();

        Test.startTest();
        ContractPdfService.generate(c.Id);
        ContractPdfService.Result second = ContractPdfService.generate(c.Id);
        Test.stopTest();

        Assert.isTrue(second.success, '두 번째 생성도 성공해야 한다');
        List<ContentDocumentLink> links = [
            SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = :c.Id
        ];
        Assert.areEqual(2, links.size(), '재생성하면 이력으로 2건이 남는다');
    }
}