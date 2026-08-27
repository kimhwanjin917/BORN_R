/**
 * Lead ?④퀎 ?곹뭹異붿쿇 ?≪뀡 ?뚯뒪??怨듭슜 ?좏떥.
 * ?≪뀡?ㅼ씠 WITH USER_MODE / AccessLevel.USER_MODE 濡??숈옉?섎?濡? ?ㅽ뻾 ?ъ슜?먯뿉寃? * ??Lead ?꾨뱶 FLS ? ?몃? 媛앹껜 ?묎렐??二쇰뒗 ?먯껜 沅뚰븳 ?명듃瑜?留뚮뱾???뚯뒪???ъ슜?먯뿉 ?좊떦?쒕떎.
 * (LeadConvertServiceTest ? 媛숈? ?⑦꽩 ??org ?꾨줈??FLS ?곹깭???뚯뒪?멸? 醫뚯슦?섏? ?딄쾶 ?쒕떎.)
 */
@IsTest
public class LeadRecommendationTestUtil {

    public static final String TEST_USER_NAME = 'lead.rec.tester@leadrec.test.example.com';

    /** 愿由ъ옄 ?꾨줈??+ FLS 沅뚰븳 ?명듃瑜?媛吏??뚯뒪???ъ슜?먮? 留뚮뱺??(setup-object DML). */
    public static User createTestUserWithFls() {
        Profile admin = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        User u = new User(
            FirstName = 'LeadRec',
            LastName = 'Tester',
            Email = 'lead.rec.tester@leadrec.test.example.com',
            Username = TEST_USER_NAME,
            Alias = 'lrtest',
            ProfileId = admin.Id,
            TimeZoneSidKey = 'Asia/Seoul',
            LocaleSidKey = 'ko_KR',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'ko'
        );
        insert u;

        PermissionSet ps = new PermissionSet(Name = 'LeadRec_Test_Fls', Label = 'LeadRec Test FLS');
        insert ps;

        insert new List<ObjectPermissions>{
            objectPerm(ps.Id, 'CorporateFinancialStatement__c'),
            objectPerm(ps.Id, 'ExternalSignal__c')
        };

        insert new List<FieldPermissions>{
            fieldPerm(ps.Id, 'Lead', 'Lead.Recommended_Product_Family__c', true),
            fieldPerm(ps.Id, 'Lead', 'Lead.Recommended_Product_Rationale__c', true),
            fieldPerm(ps.Id, 'Lead', 'Lead.Recommended_Product__c', true),
            fieldPerm(ps.Id, 'Lead', 'Lead.Recommended_Term_Days__c', true),
            fieldPerm(ps.Id, 'Lead', 'Lead.Recommended_Fee_Rate__c', true),
            fieldPerm(ps.Id, 'Lead', 'Lead.Priority_Score__c', true),
            fieldPerm(ps.Id, 'Lead', 'Lead.Priority_Rationale_Summary__c', true),
            fieldPerm(ps.Id, 'Lead', 'Lead.Email_Masked__c', false),
            fieldPerm(ps.Id, 'Lead', 'Lead.Phone_Masked__c', false),
            fieldPerm(ps.Id, 'CorporateFinancialStatement__c', 'CorporateFinancialStatement__c.Lead__c', true),
            fieldPerm(ps.Id, 'CorporateFinancialStatement__c', 'CorporateFinancialStatement__c.Fiscal_Year__c', true),
            fieldPerm(ps.Id, 'CorporateFinancialStatement__c', 'CorporateFinancialStatement__c.Period_Type__c', true),
            fieldPerm(ps.Id, 'CorporateFinancialStatement__c', 'CorporateFinancialStatement__c.Revenue__c', true),
            fieldPerm(ps.Id, 'CorporateFinancialStatement__c', 'CorporateFinancialStatement__c.Operating_Income__c', true),
            fieldPerm(ps.Id, 'CorporateFinancialStatement__c', 'CorporateFinancialStatement__c.Total_Assets__c', true),
            fieldPerm(ps.Id, 'CorporateFinancialStatement__c', 'CorporateFinancialStatement__c.Total_Debt__c', true),
            fieldPerm(ps.Id, 'CorporateFinancialStatement__c', 'CorporateFinancialStatement__c.Total_Equity__c', true),
            fieldPerm(ps.Id, 'CorporateFinancialStatement__c', 'CorporateFinancialStatement__c.Cash_And_Equivalents__c', true),
            fieldPerm(ps.Id, 'CorporateFinancialStatement__c', 'CorporateFinancialStatement__c.Short_Term_Financial_Instruments__c', true),
            fieldPerm(ps.Id, 'CorporateFinancialStatement__c', 'CorporateFinancialStatement__c.Bonds_Payable__c', true),
            fieldPerm(ps.Id, 'CorporateFinancialStatement__c', 'CorporateFinancialStatement__c.Cash_Asset_Ratio__c', true),
            fieldPerm(ps.Id, 'ExternalSignal__c', 'ExternalSignal__c.Lead__c', true),
            fieldPerm(ps.Id, 'ExternalSignal__c', 'ExternalSignal__c.Signal_Type__c', true),
            fieldPerm(ps.Id, 'ExternalSignal__c', 'ExternalSignal__c.Title__c', true),
            fieldPerm(ps.Id, 'ExternalSignal__c', 'ExternalSignal__c.Summary__c', true),
            fieldPerm(ps.Id, 'ExternalSignal__c', 'ExternalSignal__c.Signal_Date__c', true),
            fieldPerm(ps.Id, 'ExternalSignal__c', 'ExternalSignal__c.Amount__c', true),
            fieldPerm(ps.Id, 'ExternalSignal__c', 'ExternalSignal__c.Maturity_Date__c', true),
            fieldPerm(ps.Id, 'ExternalSignal__c', 'ExternalSignal__c.Relevance_Score__c', true),
            fieldPerm(ps.Id, 'Product2', 'Product2.Eligibility_Rule__c', false),
            fieldPerm(ps.Id, 'Product2', 'Product2.Default_Fee_Rate__c', false),
            fieldPerm(ps.Id, 'Product2', 'Product2.Min_Term_Days__c', false),
            fieldPerm(ps.Id, 'Product2', 'Product2.Max_Term_Days__c', false)
        };

        insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
        return u;
    }

    public static User getTestUser() {
        return [SELECT Id FROM User WHERE Username = :TEST_USER_NAME LIMIT 1];
    }

    public static Lead newLead(String company, String contactName, String family, Integer score) {
        return new Lead(
            LastName = contactName,
            name_new__c = contactName,
            Company = company,
            Email = 'contact@' + String.valueOf(Math.abs(company.hashCode())) + '.demo',
            Industry = 'Technology',
            Status = 'New',
            Priority_Score__c = score,
            Recommended_Product_Family__c = family,
            // Convert ??Account.Business_Registration_Number__c 留ㅽ븨???꾩닔 (org ?ㅼ젙)
            Business_Registration_Number__c = String.valueOf(Math.abs(company.hashCode())).leftPad(10, '0').right(10)
        );
    }

    private static ObjectPermissions objectPerm(Id parentId, String sobjectType) {
        return new ObjectPermissions(
            ParentId = parentId, SobjectType = sobjectType,
            PermissionsRead = true, PermissionsViewAllRecords = true,
            PermissionsCreate = true, PermissionsEdit = true
        );
    }

    private static FieldPermissions fieldPerm(Id parentId, String sobjectType, String field, Boolean allowEdit) {
        return new FieldPermissions(
            ParentId = parentId, SobjectType = sobjectType, Field = field,
            PermissionsRead = true, PermissionsEdit = allowEdit
        );
    }
}