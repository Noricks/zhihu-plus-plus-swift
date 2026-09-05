import XCTest
@testable import iosApp

final class ArticleRoutingTests: XCTestCase {
    func testAnswerAndArticleRoutesKeepTheirNativeKinds() {
        XCTAssertEqual(AnswerRouteDTO(contentID: 1, kind: .answer).kind, .answer)
        XCTAssertEqual(AnswerRouteDTO(contentID: 2, kind: .article).kind, .article)
    }

    func testMetadataSettingMovesOnlyDate() {
        XCTAssertEqual(QAMetadataPlacement(pinAnswerDate: true).dateEdge, .leading)
        XCTAssertEqual(QAMetadataPlacement(pinAnswerDate: true).ipEdge, .trailing)
        XCTAssertEqual(QAMetadataPlacement(pinAnswerDate: false).dateEdge, .trailing)
    }

    func testTypedShellRouteRetainsAnswerSource() {
        let route = AnswerRouteDTO(contentID: 7, kind: .answer, questionID: 3, provisionalTitle: "问题")
        XCTAssertEqual(NativeShellRoute.answer(route), .answer(route))
    }

    func testTypedShellRouteRetainsCommentSubject() {
        let route = CommentThreadRouteDTO(subject: .pin(42))
        XCTAssertEqual(NativeShellRoute.comments(route), .comments(route))
    }

    func testCommentSheetPresentationRetainsRouteAndSourceTab() {
        let route = CommentThreadRouteDTO(
            subject: .answer(42),
            initialLevel: .replies(rootCommentID: "root")
        )
        let presentation = NativeCommentSheetPresentation(route: route, sourceTab: .home)

        XCTAssertEqual(presentation.route, route)
        XCTAssertEqual(presentation.sourceTab, .home)
    }

    func testSystemSearchTargetsSearchTabAndPreservesQuery() {
        let target = NativeSearchTabNavigationTarget(query: " SwiftUI ")

        XCTAssertEqual(target.tab, .search)
        XCTAssertEqual(target.route, SearchRouteDTO(query: "SwiftUI"))
    }

    func testSearchFocusRequestTokensAdvanceAndSkipReservedZero() {
        XCTAssertEqual(NativeSearchFocusRequestPolicy.nextToken(after: 0), 1)
        XCTAssertEqual(NativeSearchFocusRequestPolicy.nextToken(after: 41), 42)
        XCTAssertEqual(NativeSearchFocusRequestPolicy.nextToken(after: .max), 1)
    }

    func testSearchFocusRequestConsumesOnlyNewActiveNonzeroToken() {
        XCTAssertTrue(NativeSearchFocusRequestPolicy.shouldConsume(
            .init(token: 2, isActive: true),
            lastConsumedToken: 1
        ))
        XCTAssertFalse(NativeSearchFocusRequestPolicy.shouldConsume(
            .init(token: 2, isActive: true),
            lastConsumedToken: 2
        ))
        XCTAssertFalse(NativeSearchFocusRequestPolicy.shouldConsume(
            .init(token: 2, isActive: false),
            lastConsumedToken: 1
        ))
        XCTAssertFalse(NativeSearchFocusRequestPolicy.shouldConsume(
            .init(token: 0, isActive: true),
            lastConsumedToken: 0
        ))
        XCTAssertFalse(NativeSearchFocusRequestPolicy.shouldConsume(
            .init(token: 2, isActive: true),
            lastConsumedToken: 3
        ))
    }

    func testPushedMemberSearchRequestsFocusWithoutChangingOtherSearchRoutes() {
        let memberSearch = SearchRouteDTO(
            restrictedMemberHashID: "member-hash",
            restrictedMemberName: "作者"
        )

        XCTAssertEqual(
            NativeSearchFocusRequestPolicy.pushedRouteRequest(memberSearch),
            NativeSearchFocusRequest(token: 1, isActive: true)
        )
        XCTAssertEqual(
            NativeSearchFocusRequestPolicy.pushedRouteRequest(SearchRouteDTO(query: "热搜词")),
            .inactive
        )
        XCTAssertEqual(
            NativeSearchFocusRequestPolicy.pushedRouteRequest(SearchRouteDTO()),
            .inactive
        )
    }

    func testHomeToSearchSelectionIssuesExactlyOneFocusToken() {
        var token: UInt = 0
        if NativeSearchFocusRequestPolicy.shouldRequestForTabSelection(
            previous: .home,
            next: .search,
            isSearchRoot: true
        ) {
            token = NativeSearchFocusRequestPolicy.nextToken(after: token)
        }
        if NativeTabReselectPolicy.isReselect(
            tappedTab: .search,
            selectedTabAtTouchBegan: .home
        ) {
            token = NativeSearchFocusRequestPolicy.nextToken(after: token)
        }

        XCTAssertEqual(token, 1)
    }

    func testSearchTabReselectionIssuesExactlyOneFocusToken() {
        var token: UInt = 0
        if NativeSearchFocusRequestPolicy.shouldRequestForTabSelection(
            previous: .search,
            next: .search,
            isSearchRoot: true
        ) {
            token = NativeSearchFocusRequestPolicy.nextToken(after: token)
        }
        if NativeTabReselectPolicy.isReselect(
            tappedTab: .search,
            selectedTabAtTouchBegan: .search
        ), NativeSearchFocusRequestPolicy.shouldRequestForTabReselection(
            tab: .search,
            isSearchRoot: true
        ) {
            token = NativeSearchFocusRequestPolicy.nextToken(after: token)
        }

        XCTAssertEqual(token, 1)
    }

    func testSearchStartupDoesNotIssueFocusToken() {
        let token: UInt = 0

        XCTAssertFalse(NativeSearchFocusRequestPolicy.shouldRequestForTabSelection(
            previous: .search,
            next: .search,
            isSearchRoot: true
        ))
        XCTAssertEqual(token, 0)
    }

    func testSystemSearchExplicitlyIssuesExactlyOneFocusToken() {
        var token: UInt = 0

        token = NativeSearchFocusRequestPolicy.nextToken(after: token)

        XCTAssertEqual(token, 1)
    }

    func testHotSystemNavigationUsesHomeChannelWhenHomeTabIsVisible() {
        XCTAssertEqual(
            NativeHotSystemNavigationPolicy.target(
                selectedTabs: [.history, .home, .account],
                currentTab: .history,
                startTab: .history
            ),
            .homeChannel
        )
    }

    func testHotSystemNavigationPushesInCurrentTabWhenHomeIsHidden() {
        XCTAssertEqual(
            NativeHotSystemNavigationPolicy.target(
                selectedTabs: [.history, .account],
                currentTab: .account,
                startTab: .history
            ),
            .hotList(tab: .account)
        )
    }

    func testHotSystemNavigationNeverReturnsAnUnavailableTab() {
        XCTAssertEqual(
            NativeHotSystemNavigationPolicy.target(
                selectedTabs: [.collections],
                currentTab: .home,
                startTab: .account
            ),
            .hotList(tab: .collections)
        )
        XCTAssertNil(NativeHotSystemNavigationPolicy.target(
            selectedTabs: [],
            currentTab: .home,
            startTab: .home
        ))
    }

    func testRiskControlOnlyAllowsTrustedHttpsZhihuHosts() {
        XCTAssertTrue(RiskControlURLPolicy.allows(URL(string: "https://www.zhihu.com/account/unhuman")!))
        XCTAssertFalse(RiskControlURLPolicy.allows(URL(string: "http://www.zhihu.com/account/unhuman")!))
        XCTAssertFalse(RiskControlURLPolicy.allows(URL(string: "https://zhihu.com.example.com/account/unhuman")!))
    }
}
