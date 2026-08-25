/**
 * Tests for ProductRecommendationAction.
 *
 * Test data is built inline via @TestSetup (TestDataFactory is a frozen shared
 * file and is intentionally not used here). Opportunity OWD is Private, so a
 * low-privilege user is created to deterministically reproduce the
 * inaccessible-Opportunity scenario via System.runAs.
 */
@isTest
private class ProductRecommendationActionTest {

    @TestSetup
    static void makeData() {
        // Account + related Opportunity (Amount, required CloseDate/StageName).
        // Industry is required by the active "Required_PL" validation rule
        // (ISBLANK(TEXT(Industry))). Business_Registration_Number__c is a
        // required Text(10) field. Both must be populated for the insert.
        Account acct = new Account(
            Name = 'Borny Test Account',
            Industry = 'Banking',
            Business_Registration_Number__c = '1234567890'
        );
        insert acct;

        Opportunity opp = new Opportunity(
            Name = 'Borny Test Opportunity',
            AccountId = acct.Id,
            Amount = 250000,
            StageName = 'Prospecting',
            CloseDate = Date.newInstance(2026, 12, 31)
        );
        insert opp;

        // Two active products (with eligibility/fee/term fields) + one inactive.
        List<Product2> products = new List<Product2>{
            new Product2(
                Name = 'Active Product A',
                IsActive = true,
                Eligibility_Rule__c = 'Amount >= 100000 and Account industry in Financial Services',
                Default_Fee_Rate__c = 1.25,
                Min_Term_Days__c = 30,
                Max_Term_Days__c = 365
            ),
            new Product2(
                Name = 'Active Product B',
                IsActive = true,
                Eligibility_Rule__c = 'Amount >= 50000',
                Default_Fee_Rate__c = 2.50,
                Min_Term_Days__c = 90,
                Max_Term_Days__c = 720
            ),
            new Product2(
                Name = 'Inactive Product C',
                IsActive = false,
                Eligibility_Rule__c = 'Should never be recommended',
                Default_Fee_Rate__c = 9.99,
                Min_Term_Days__c = 10,
                Max_Term_Days__c = 20
            )
        };
        insert products;

        // Setup-object DML (User, PermissionSet, ObjectPermissions,
        // FieldPermissions, PermissionSetAssignment) must run in a separate
        // transaction context from the non-setup DML above (Account, Opportunity,
        // Product2); otherwise MIXED_DML_OPERATION is thrown. System.runAs
        // isolates the setup DML into its own context.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            // Low-privilege user (Standard User profile) for the System.runAs
            // inaccessible-Opportunity scenario. Kept out of the Account/Opp sharing.
            Profile standardProfile = [
                SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1
            ];
            User lowAccessUser = new User(
                FirstName = 'Low',
                LastName = 'Access',
                Email = 'borny.lowaccess@example.com.invalid',
                Username = 'borny.lowaccess@example.com.invalid',
                Alias = 'lowacc',
                ProfileId = standardProfile.Id,
                TimeZoneSidKey = 'America/Los_Angeles',
                LocaleSidKey = 'en_US',
                EmailEncodingKey = 'UTF-8',
                LanguageLocaleKey = 'en_US'
            );
            insert lowAccessUser;

            // The action queries Product2 custom fields WITH USER_MODE, which throws
            // for a user lacking FLS on those fields. Grant the low-access user read
            // on Product2 and its four custom fields via a permission set, so the
            // only variable left in scenario ③ is Opportunity accessibility (Private
            // OWD, unshared) — which is what this scenario is meant to isolate.
            PermissionSet ps = new PermissionSet(
                Name = 'Borny_ProdRecTest_ProductRead',
                Label = 'Borny ProdRec Test Product Read'
            );
            insert ps;

            insert new ObjectPermissions(
                ParentId = ps.Id,
                SobjectType = 'Product2',
                PermissionsRead = true
            );

            List<FieldPermissions> fps = new List<FieldPermissions>();
            for (String field : new List<String>{
                'Product2.Eligibility_Rule__c',
                'Product2.Default_Fee_Rate__c',
                'Product2.Min_Term_Days__c',
                'Product2.Max_Term_Days__c'
            }) {
                fps.add(new FieldPermissions(
                    ParentId = ps.Id,
                    SobjectType = 'Product2',
                    Field = field,
                    PermissionsRead = true
                ));
            }
            insert fps;

            insert new PermissionSetAssignment(
                AssigneeId = lowAccessUser.Id,
                PermissionSetId = ps.Id
            );
        }
    }

    @isTest
    static void testActiveProductReturnedAsCandidate() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];

        ProductRecommendationAction.Request req = new ProductRecommendationAction.Request();
        req.opportunityId = opp.Id;

        Test.startTest();
        List<ProductRecommendationAction.Response> responses =
            ProductRecommendationAction.recommend(
                new List<ProductRecommendationAction.Request>{ req });
        Test.stopTest();

        System.assertEquals(1, responses.size(), 'One response expected for one request');
        ProductRecommendationAction.Response res = responses[0];
        System.assertNotEquals(null, res.recommendations, 'Recommendations list should not be null');
        System.assertEquals(2, res.recommendations.size(),
            'Both active products should be returned as candidates');

        // Locate "Active Product A" and assert every returned field is populated.
        ProductRecommendationAction.Recommendation candidateA;
        for (ProductRecommendationAction.Recommendation r : res.recommendations) {
            if (r.productName == 'Active Product A') {
                candidateA = r;
            }
        }
        System.assertNotEquals(null, candidateA, 'Active Product A should be in the candidate list');
        System.assertEquals('Active Product A', candidateA.productName, 'Product name should be populated');
        System.assertEquals(
            'Amount >= 100000 and Account industry in Financial Services',
            candidateA.eligibilityBasis,
            'Eligibility basis (Eligibility_Rule__c) should be populated');
        System.assertEquals(1.25, candidateA.feeRate, 'Fee rate (Default_Fee_Rate__c) should be populated');
        System.assertEquals(30, candidateA.minTermDays, 'Min term days (Min_Term_Days__c) should be populated');
        System.assertEquals(365, candidateA.maxTermDays, 'Max term days (Max_Term_Days__c) should be populated');
    }

    @isTest
    static void testInactiveProductExcluded() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];

        ProductRecommendationAction.Request req = new ProductRecommendationAction.Request();
        req.opportunityId = opp.Id;

        Test.startTest();
        List<ProductRecommendationAction.Response> responses =
            ProductRecommendationAction.recommend(
                new List<ProductRecommendationAction.Request>{ req });
        Test.stopTest();

        ProductRecommendationAction.Response res = responses[0];
        for (ProductRecommendationAction.Recommendation r : res.recommendations) {
            System.assertNotEquals('Inactive Product C', r.productName,
                'Inactive product must never appear as a candidate');
        }
    }

    @isTest
    static void testNullAndBlankSanitizedNote() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];

        ProductRecommendationAction.Request nullNoteReq = new ProductRecommendationAction.Request();
        nullNoteReq.opportunityId = opp.Id;
        nullNoteReq.sanitizedNote = null;

        ProductRecommendationAction.Request blankNoteReq = new ProductRecommendationAction.Request();
        blankNoteReq.opportunityId = opp.Id;
        blankNoteReq.sanitizedNote = '';

        Test.startTest();
        List<ProductRecommendationAction.Response> responses =
            ProductRecommendationAction.recommend(
                new List<ProductRecommendationAction.Request>{ nullNoteReq, blankNoteReq });
        Test.stopTest();

        // No exception thrown for either note value; both requests yield a response.
        System.assertEquals(2, responses.size(),
            'Both null and blank sanitizedNote requests should return a response');
        System.assertNotEquals(null, responses[0].recommendations,
            'Null sanitizedNote should still produce a candidate list');
        System.assertNotEquals(null, responses[1].recommendations,
            'Blank sanitizedNote should still produce a candidate list');
    }

    @isTest
    static void testInaccessibleOpportunityReturnsEmpty() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        User lowAccessUser = [
            SELECT Id FROM User
            WHERE Username = 'borny.lowaccess@example.com.invalid'
            LIMIT 1
        ];

        ProductRecommendationAction.Request req = new ProductRecommendationAction.Request();
        req.opportunityId = opp.Id;

        List<ProductRecommendationAction.Response> responses;
        System.runAs(lowAccessUser) {
            Test.startTest();
            // Opportunity OWD is Private and this admin-owned Opp is not shared
            // to the low-access user, so the user-mode query returns nothing.
            responses = ProductRecommendationAction.recommend(
                new List<ProductRecommendationAction.Request>{ req });
            Test.stopTest();
        }

        System.assertEquals(1, responses.size(), 'One response expected for one request');
        System.assertNotEquals(null, responses[0].recommendations,
            'Recommendations list should be initialized, not null');
        System.assertEquals(0, responses[0].recommendations.size(),
            'Inaccessible Opportunity must yield an empty candidate list without an exception');
    }

    @isTest
    static void testNonexistentIdReturnsEmpty() {
        // Create and delete an Opportunity to obtain a well-formed but nonexistent Id.
        Account acct = [SELECT Id FROM Account LIMIT 1];
        Opportunity temp = new Opportunity(
            Name = 'Temp Opp',
            AccountId = acct.Id,
            StageName = 'Prospecting',
            CloseDate = Date.newInstance(2026, 12, 31)
        );
        insert temp;
        Id deletedId = temp.Id;
        delete temp;

        ProductRecommendationAction.Request req = new ProductRecommendationAction.Request();
        req.opportunityId = deletedId;

        Test.startTest();
        List<ProductRecommendationAction.Response> responses =
            ProductRecommendationAction.recommend(
                new List<ProductRecommendationAction.Request>{ req });
        Test.stopTest();

        System.assertEquals(1, responses.size(), 'One response expected for one request');
        System.assertNotEquals(null, responses[0].recommendations,
            'Recommendations list should be initialized, not null');
        System.assertEquals(0, responses[0].recommendations.size(),
            'Nonexistent/deleted Opportunity Id must yield an empty candidate list without an exception');
    }

    @isTest
    static void testBulkInvocation() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];

        // Mix an accessible Opp with a null-Id request so responses differ per item,
        // letting order correspondence be verified meaningfully.
        ProductRecommendationAction.Request accessibleReq = new ProductRecommendationAction.Request();
        accessibleReq.opportunityId = opp.Id;

        ProductRecommendationAction.Request nullIdReq = new ProductRecommendationAction.Request();
        nullIdReq.opportunityId = null;

        ProductRecommendationAction.Request accessibleReq2 = new ProductRecommendationAction.Request();
        accessibleReq2.opportunityId = opp.Id;

        List<ProductRecommendationAction.Request> requests =
            new List<ProductRecommendationAction.Request>{ accessibleReq, nullIdReq, accessibleReq2 };

        Test.startTest();
        List<ProductRecommendationAction.Response> responses =
            ProductRecommendationAction.recommend(requests);
        Test.stopTest();

        System.assertEquals(3, responses.size(),
            'Response list size must match the input request count');
        // Order correspondence: index 0 and 2 (accessible) carry candidates;
        // index 1 (null Id) carries an empty list.
        System.assertEquals(2, responses[0].recommendations.size(),
            'First request (accessible) should map to a populated candidate list');
        System.assertEquals(0, responses[1].recommendations.size(),
            'Second request (null Id) should map to an empty candidate list');
        System.assertEquals(2, responses[2].recommendations.size(),
            'Third request (accessible) should map to a populated candidate list');
    }
    // ---------------------------------------------------------------------
    // Backlog 21 (D-segment cross-sell): held products and maturity grounding
    // ---------------------------------------------------------------------

    /**
     * Inserts one held product (Asset) for the seeded Account.
     *
     * @param maturityOffsetDays Days from today to Usage End Date; negative means already matured
     */
    private static void insertHeldAsset(Integer maturityOffsetDays) {
        Account acct = [SELECT Id FROM Account LIMIT 1];
        Product2 product = [SELECT Id FROM Product2 WHERE Name = 'Active Product A' LIMIT 1];
        insert new Asset(
            Name = 'Held Bond',
            AccountId = acct.Id,
            Product2Id = product.Id,
            Status = 'Purchased',
            InstallDate = Date.today().addDays(-365),
            UsageEndDate = Date.today().addDays(maturityOffsetDays),
            Price = 500000000,
            Principal_Amount__c = 500000000,
            Interest_Rate__c = 3.8
        );
    }

    /**
     * Runs the action for the seeded Opportunity and returns the single response.
     */
    private static ProductRecommendationAction.Response runForSeededOpportunity() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        ProductRecommendationAction.Request req = new ProductRecommendationAction.Request();
        req.opportunityId = opp.Id;
        return ProductRecommendationAction.recommend(
            new List<ProductRecommendationAction.Request>{ req })[0];
    }

    @isTest
    static void testHeldAssetMaturingWithinWindowIsFlagged() {
        insertHeldAsset(16);

        Test.startTest();
        ProductRecommendationAction.Response res = runForSeededOpportunity();
        Test.stopTest();

        System.assertNotEquals(null, res.heldAssets, 'Held product list should be initialized');
        System.assertEquals(1, res.heldAssets.size(),
            'The held product of the related account should be returned');
        System.assertEquals(true, res.hasMaturingAsset,
            'A product maturing in 16 days falls inside the 90 day window');

        ProductRecommendationAction.HeldAsset item = res.heldAssets[0];
        System.assertEquals('Held Bond', item.assetName, 'Asset name should be populated');
        System.assertEquals('Active Product A', item.productName,
            'Catalog product name should be populated');
        System.assertEquals('Purchased', item.status, 'Status should be populated');
        System.assertEquals(500000000, item.principalAmount,
            'Principal should come from Principal_Amount__c');
        System.assertEquals(3.8, item.interestRate.setScale(1),
            'Interest rate should come from Interest_Rate__c');
        System.assertEquals(Date.today().addDays(-365), item.startDate,
            'Start date should come from InstallDate');
        System.assertEquals(Date.today().addDays(16), item.maturityDate,
            'Maturity date should come from UsageEndDate');
        System.assertEquals(16, item.daysToMaturity,
            'Days to maturity should be counted from today');
        System.assert(res.heldAssetText.contains('Held Bond'),
            'Held product text should name the held product');
        System.assert(res.heldAssetText.contains('만기'),
            'Held product text should carry the maturity label');
    }

    @isTest
    static void testHeldAssetBeyondWindowIsNotFlagged() {
        insertHeldAsset(200);

        Test.startTest();
        ProductRecommendationAction.Response res = runForSeededOpportunity();
        Test.stopTest();

        System.assertEquals(1, res.heldAssets.size(),
            'The held product should still be returned as context');
        System.assertEquals(200, res.heldAssets[0].daysToMaturity,
            'Days to maturity should be 200');
        System.assertEquals(false, res.hasMaturingAsset,
            'A product maturing beyond 90 days must not open cross-sell context');
    }

    @isTest
    static void testAlreadyMaturedAssetIsFlagged() {
        insertHeldAsset(-5);

        Test.startTest();
        ProductRecommendationAction.Response res = runForSeededOpportunity();
        Test.stopTest();

        System.assertEquals(-5, res.heldAssets[0].daysToMaturity,
            'A matured product should report a negative day count');
        System.assertEquals(true, res.hasMaturingAsset,
            'An already matured product also counts as cross-sell context');
    }

    @isTest
    static void testNoHeldAssetYieldsEmptyListAndText() {
        Test.startTest();
        ProductRecommendationAction.Response res = runForSeededOpportunity();
        Test.stopTest();

        System.assertNotEquals(null, res.heldAssets,
            'Held product list should be initialized, not null');
        System.assertEquals(0, res.heldAssets.size(),
            'No held product exists for the seeded account');
        System.assertEquals(false, res.hasMaturingAsset,
            'No held product means no cross-sell context');
        System.assertEquals('조회된 보유상품이 없습니다.', res.heldAssetText,
            'Held product text should state that nothing was found');
        System.assertEquals(2, res.recommendations.size(),
            'Product candidates must be unaffected by the absence of held products');
    }

    @isTest
    static void testNullOpportunityIdReturnsNoHeldAssets() {
        insertHeldAsset(16);

        ProductRecommendationAction.Request req = new ProductRecommendationAction.Request();
        req.opportunityId = null;

        Test.startTest();
        List<ProductRecommendationAction.Response> responses =
            ProductRecommendationAction.recommend(
                new List<ProductRecommendationAction.Request>{ req });
        Test.stopTest();

        System.assertEquals(0, responses[0].heldAssets.size(),
            'A request without an accessible Opportunity must not leak held products');
        System.assertEquals(false, responses[0].hasMaturingAsset,
            'No Opportunity means no cross-sell context');
        System.assertEquals('조회된 보유상품이 없습니다.', responses[0].heldAssetText,
            'Held product text should be populated even for an empty response');
    }
}