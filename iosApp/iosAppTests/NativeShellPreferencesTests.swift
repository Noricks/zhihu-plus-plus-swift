import CoreGraphics
import XCTest
@testable import iosApp

@MainActor
final class NativeShellPreferencesTests: XCTestCase {
    func testBottomBarUsesThreePrimaryTabsAndTrailingSearchInProductOrder() {
        XCTAssertEqual(
            NativeAppTab.fixedBottomBarTabs,
            [.home, .collections, .account, .search]
        )
        XCTAssertEqual(
            NativeAppTab.fixedBottomBarTabs.map(\.title),
            ["首页", "收藏", "账号", "搜索"]
        )
        XCTAssertEqual(NativeAppTab.primaryBottomBarTabs, [.home, .collections, .account])
        XCTAssertTrue(NativeAppTab.search.usesSearchRole)
        XCTAssertFalse(NativeAppTab.home.usesSearchRole)
    }

    func testStartTabUsesFixedTabsInsteadOfLegacyBottomBarSelection() {
        let defaults = makeDefaults()
        defaults.set(["Account"], forKey: NativeShellPreferences.Key.selectedTabs)
        defaults.set(NativeAppTab.collections.rawValue, forKey: NativeShellPreferences.Key.startTab)

        let preferences = NativeShellPreferences(defaults: defaults)

        XCTAssertEqual(preferences.startTab, .collections)
        XCTAssertEqual(preferences.selectedTabs, [.account])
    }

    func testLegacyAccountInHomeSettingMigratesWithoutDuplicateAccountTab() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: NativeShellPreferences.Key.accountInHome)
        defaults.set(["Home", "Follow", "Account"], forKey: NativeShellPreferences.Key.selectedTabs)

        let preferences = NativeShellPreferences(defaults: defaults)

        XCTAssertEqual(preferences.selectedTabs, [.home])
        XCTAssertEqual(defaults.integer(forKey: NativeShellPreferences.Key.bottomTabStructureVersion), 3)
    }

    func testAccountTabCanBeEnabledAfterLegacyMigration() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: NativeShellPreferences.Key.accountInHome)
        defaults.set(["Home", "Follow", "Account"], forKey: NativeShellPreferences.Key.selectedTabs)
        let preferences = NativeShellPreferences(defaults: defaults)

        preferences.setTabEnabled(.account, enabled: true)
        let restored = NativeShellPreferences(defaults: defaults)

        XCTAssertEqual(restored.selectedTabs, [.home, .account])
    }

    func testLegacyAccountInHomeWithoutHomeMigratesToAccountTab() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: NativeShellPreferences.Key.accountInHome)
        defaults.set(["Follow", "Daily"], forKey: NativeShellPreferences.Key.selectedTabs)
        defaults.set("Follow,Daily", forKey: NativeShellPreferences.Key.tabOrder)

        let preferences = NativeShellPreferences(defaults: defaults)

        XCTAssertEqual(preferences.selectedTabs, [.account])
        XCTAssertEqual(
            defaults.stringArray(forKey: NativeShellPreferences.Key.selectedTabs),
            ["Account"]
        )
        XCTAssertEqual(defaults.integer(forKey: NativeShellPreferences.Key.bottomTabStructureVersion), 3)
    }

    func testLegacyTopLevelFeedTabsAreRemovedFromBottomBar() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: NativeShellPreferences.Key.accountInHome)
        defaults.set(NativeAppTab.allCases.map(\.rawValue), forKey: NativeShellPreferences.Key.selectedTabs)

        let preferences = NativeShellPreferences(defaults: defaults)

        XCTAssertEqual(preferences.selectedTabs, [.home, .collections, .account, .search])
        XCTAssertFalse(preferences.selectedTabs.contains(.follow))
        XCTAssertFalse(preferences.selectedTabs.contains(.hot))
        XCTAssertFalse(preferences.selectedTabs.contains(.daily))
        XCTAssertFalse(preferences.selectedTabs.contains(.history))
    }

    func testDisablingTabsNeverLeavesBottomBarEmpty() {
        let defaults = makeDefaults()
        let preferences = NativeShellPreferences(defaults: defaults)

        for tab in NativeAppTab.allCases {
            preferences.setTabEnabled(tab, enabled: false)
        }

        XCTAssertEqual(preferences.selectedTabs, [.home])
    }

    func testLegacyOrderIsPreservedForSupportedBottomTabs() {
        let defaults = makeDefaults()
        defaults.set(["Account", "Follow", "OnlineHistory", "Home"], forKey: NativeShellPreferences.Key.selectedTabs)
        defaults.set("Account,Follow,OnlineHistory,Home", forKey: NativeShellPreferences.Key.tabOrder)

        let preferences = NativeShellPreferences(defaults: defaults)

        XCTAssertEqual(preferences.selectedTabs, [.account, .home])
        XCTAssertEqual(
            defaults.stringArray(forKey: NativeShellPreferences.Key.selectedTabs),
            ["Account", "Home"]
        )
        XCTAssertEqual(
            defaults.string(forKey: NativeShellPreferences.Key.tabOrder),
            "Account,Home"
        )
    }

    func testUnsupportedOnlyLegacySelectionFallsBackToHome() {
        let defaults = makeDefaults()
        defaults.set(["Follow", "HotList", "Daily"], forKey: NativeShellPreferences.Key.selectedTabs)

        let preferences = NativeShellPreferences(defaults: defaults)

        XCTAssertEqual(preferences.selectedTabs, [.home])
        XCTAssertEqual(preferences.startTab, .home)
    }

    func testHiddenHistoryStartTabMigratesAndPersistsHome() {
        let defaults = makeDefaults()
        defaults.set(NativeAppTab.history.rawValue, forKey: NativeShellPreferences.Key.startTab)

        let preferences = NativeShellPreferences(defaults: defaults)

        XCTAssertEqual(preferences.startTab, .home)
        XCTAssertEqual(
            defaults.string(forKey: NativeShellPreferences.Key.startTab),
            NativeAppTab.home.rawValue
        )
    }

    func testSearchIsAValidStartTabSelection() {
        let defaults = makeDefaults()
        defaults.set(NativeAppTab.search.rawValue, forKey: NativeShellPreferences.Key.startTab)

        let preferences = NativeShellPreferences(defaults: defaults)

        XCTAssertEqual(preferences.startTab, .search)
        preferences.setStartTab(.collections)
        XCTAssertEqual(preferences.startTab, .collections)
    }

    func testHapticPreferencesDefaultEnabledAtStandardStrength() {
        let preferences = NativeShellPreferences(defaults: makeDefaults())

        XCTAssertTrue(preferences.hapticsEnabled)
        XCTAssertEqual(preferences.hapticStrength, .standard)
        XCTAssertEqual(
            preferences.hapticFeedbackConfiguration,
            .init(isEnabled: true, strength: .standard)
        )
    }

    func testExternalPageOpeningDefaultsToBrowserAndPersistsInAppChoice() {
        let defaults = makeDefaults()
        let preferences = NativeShellPreferences(defaults: defaults)

        XCTAssertEqual(preferences.externalPageOpeningMode, .defaultBrowser)

        preferences.setExternalPageOpeningMode(.inApp)

        XCTAssertEqual(
            NativeShellPreferences(defaults: defaults).externalPageOpeningMode,
            .inApp
        )
        XCTAssertEqual(
            defaults.string(forKey: NativeShellPreferences.Key.externalPageOpeningMode),
            NativeExternalPageOpeningMode.inApp.rawValue
        )
    }

    func testExternalPageOpeningRejectsUnknownStoredValueWithoutRewritingIt() {
        let defaults = makeDefaults()
        defaults.set("future-mode", forKey: NativeShellPreferences.Key.externalPageOpeningMode)

        XCTAssertEqual(
            NativeShellPreferences(defaults: defaults).externalPageOpeningMode,
            .defaultBrowser
        )
        XCTAssertEqual(
            defaults.string(forKey: NativeShellPreferences.Key.externalPageOpeningMode),
            "future-mode"
        )
    }

    func testRecommendationPreferencesDefaultPersistAndClampTargetCount() {
        let defaults = makeDefaults()
        let preferences = NativeShellPreferences(defaults: defaults)

        XCTAssertEqual(preferences.homeRecommendationSource, .app)
        XCTAssertEqual(preferences.homeRefreshTargetItemCount, 20)
        XCTAssertEqual(
            preferences.homeRecommendationRefreshConfiguration,
            .defaultValue
        )

        preferences.setHomeRecommendationSource(.web)
        preferences.setHomeRefreshTargetItemCount(3)
        XCTAssertEqual(preferences.homeRefreshTargetItemCount, 6)

        let restored = NativeShellPreferences(defaults: defaults)
        XCTAssertEqual(restored.homeRecommendationSource, .web)
        XCTAssertEqual(restored.homeRefreshTargetItemCount, 6)

        restored.setHomeRefreshTargetItemCount(50)
        XCTAssertEqual(restored.homeRefreshTargetItemCount, 20)
    }

    func testHapticPreferencesPersistUserOverridesAndRejectUnknownStrength() {
        let defaults = makeDefaults()
        let preferences = NativeShellPreferences(defaults: defaults)

        preferences.setHapticsEnabled(false)
        preferences.setHapticStrength(.strong)

        let restored = NativeShellPreferences(defaults: defaults)
        XCTAssertFalse(restored.hapticsEnabled)
        XCTAssertEqual(restored.hapticStrength, .strong)

        defaults.set("unknown", forKey: NativeShellPreferences.Key.hapticStrength)
        XCTAssertEqual(NativeShellPreferences(defaults: defaults).hapticStrength, .standard)
    }

    func testQuestionAuthorBlocklistPersistsDeduplicatesAndUnblocks() {
        let defaults = makeDefaults()
        let first = FeedAuthorDTO(
            memberID: "asker",
            urlToken: "old-token",
            displayName: "旧名称",
            avatarURL: nil,
            headline: ""
        )
        let updated = FeedAuthorDTO(
            memberID: "asker",
            urlToken: "new-token",
            displayName: "新名称",
            avatarURL: URL(string: "https://pic.zhimg.com/asker.jpg"),
            headline: ""
        )
        let store = QuestionAuthorBlocklistStore(defaults: defaults)

        store.block(first, now: Date(timeIntervalSince1970: 10))
        store.block(updated, now: Date(timeIntervalSince1970: 20))

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.displayName, "新名称")
        XCTAssertTrue(store.isBlocked(memberID: "asker"))

        let restored = QuestionAuthorBlocklistStore(defaults: defaults)
        XCTAssertEqual(restored.entries, store.entries)

        restored.unblock(memberID: "asker")
        XCTAssertFalse(restored.isBlocked(memberID: "asker"))
        XCTAssertTrue(QuestionAuthorBlocklistStore(defaults: defaults).entries.isEmpty)
    }

    func testQuestionAuthorBlocklistIgnoresMalformedPersistence() {
        let defaults = makeDefaults()
        defaults.set(
            Data("not-json".utf8),
            forKey: "blockedQuestionAuthors.v1"
        )

        XCTAssertTrue(QuestionAuthorBlocklistStore(defaults: defaults).entries.isEmpty)
    }

    func testHapticFeedbackActionGatesDeliveryAndForwardsConfiguredStrength() {
        var deliveredEvent: NativeHapticFeedbackEvent?
        var deliveredStrength: NativeHapticStrength?
        let enabled = NativeHapticFeedbackAction(
            configuration: .init(isEnabled: true, strength: .light)
        ) { event, strength in
            deliveredEvent = event
            deliveredStrength = strength
        }

        enabled(.longPress)

        XCTAssertEqual(deliveredEvent, .longPress)
        XCTAssertEqual(deliveredStrength, .light)

        enabled(.refreshSucceeded)

        XCTAssertEqual(deliveredEvent, .refreshSucceeded)
        XCTAssertEqual(deliveredStrength, .light)

        let disabled = NativeHapticFeedbackAction(
            configuration: .init(isEnabled: false, strength: .strong)
        ) { event, strength in
            deliveredEvent = event
            deliveredStrength = strength
        }
        deliveredEvent = nil
        deliveredStrength = nil

        disabled(.commit)

        XCTAssertNil(deliveredEvent)
        XCTAssertNil(deliveredStrength)
    }

    func testHapticStrengthPreviewUsesExplicitNewStrengthExactlyOnce() {
        var deliveredEvents: [NativeHapticFeedbackEvent] = []
        var deliveredStrengths: [NativeHapticStrength] = []
        let action = NativeHapticFeedbackAction(
            configuration: .init(isEnabled: true, strength: .light)
        ) { event, strength in
            deliveredEvents.append(event)
            deliveredStrengths.append(strength)
        }

        action.previewStrength(.strong)

        XCTAssertEqual(deliveredEvents, [.strengthPreview])
        XCTAssertEqual(deliveredStrengths, [.strong])
    }

    func testHapticStrengthSelectionOnlyPreviewsEnabledUserChanges() {
        XCTAssertTrue(NativeHapticStrengthSelectionPolicy.shouldPreview(
            current: .standard,
            selected: .strong,
            isHapticsEnabled: true
        ))
        XCTAssertFalse(NativeHapticStrengthSelectionPolicy.shouldPreview(
            current: .strong,
            selected: .strong,
            isHapticsEnabled: true
        ))
        XCTAssertFalse(NativeHapticStrengthSelectionPolicy.shouldPreview(
            current: .standard,
            selected: .strong,
            isHapticsEnabled: false
        ))
    }

    func testHomeChannelsHaveFixedProductOrder() {
        XCTAssertEqual(HomeChannel.allCases, [.following, .recommendation, .hot, .daily])
        XCTAssertEqual(HomeChannel.allCases.map(\.id), [
            "following",
            "recommendation",
            "hot",
            "daily",
        ])
        XCTAssertEqual(HomeChannel.allCases.map(\.id), HomeChannel.allCases.map(\.rawValue))
        XCTAssertEqual(HomeChannel.allCases.map(\.title), ["关注", "推荐", "热榜", "日报"])
    }

    func testChannelSwipeRequiresHorizontalIntentAndEnoughDistance() {
        XCTAssertEqual(channelTarget(
            currentIndex: 1,
            translation: CGSize(width: 100, height: 100),
            predicted: CGSize(width: 180, height: 100)
        ), 1)
        XCTAssertEqual(channelTarget(
            currentIndex: 1,
            translation: CGSize(width: 17, height: 0),
            predicted: CGSize(width: 24, height: 0)
        ), 1)
    }

    func testChannelSwipeMovesOnePositionForDistanceOrPrediction() {
        XCTAssertEqual(channelTarget(
            currentIndex: 1,
            translation: CGSize(width: -18, height: 0),
            predicted: CGSize(width: -18, height: 0)
        ), 2)
        XCTAssertEqual(channelTarget(
            currentIndex: 2,
            translation: CGSize(width: 18, height: 0),
            predicted: CGSize(width: 18, height: 0)
        ), 1)
        XCTAssertEqual(channelTarget(
            currentIndex: 1,
            translation: CGSize(width: -5, height: 0),
            predicted: CGSize(width: -25, height: 0)
        ), 2)
    }

    func testChannelSwipeNeverCrossesEdgesAndRejectsZeroWidth() {
        XCTAssertEqual(channelTarget(
            currentIndex: 0,
            translation: CGSize(width: 100, height: 0),
            predicted: CGSize(width: 140, height: 0)
        ), 0)
        XCTAssertEqual(channelTarget(
            currentIndex: 3,
            translation: CGSize(width: -100, height: 0),
            predicted: CGSize(width: -140, height: 0)
        ), 3)
        XCTAssertEqual(channelTarget(
            currentIndex: 2,
            translation: CGSize(width: -100, height: 0),
            predicted: CGSize(width: -140, height: 0),
            containerWidth: 0
        ), 2)
    }

    func testHomeChannelRefreshStatusCoversLoadingAndRelativeTimeBoundaries() {
        let now = Date(timeIntervalSince1970: 10_000)

        XCTAssertEqual(HomeChannelRefreshStatusText.text(
            lastSuccessfulRefreshAt: nil,
            isRefreshing: false,
            now: now
        ), "尚未更新")
        XCTAssertEqual(HomeChannelRefreshStatusText.text(
            lastSuccessfulRefreshAt: nil,
            isRefreshing: true,
            now: now
        ), "更新中…")
        XCTAssertEqual(HomeChannelRefreshStatusText.text(
            lastSuccessfulRefreshAt: now.addingTimeInterval(-30),
            isRefreshing: false,
            now: now
        ), "刚刚更新")
        XCTAssertEqual(HomeChannelRefreshStatusText.text(
            lastSuccessfulRefreshAt: now.addingTimeInterval(-4 * 60),
            isRefreshing: false,
            now: now
        ), "4 分钟前更新")
        XCTAssertEqual(HomeChannelRefreshStatusText.text(
            lastSuccessfulRefreshAt: now.addingTimeInterval(-60 * 60),
            isRefreshing: false,
            now: now
        ), "1 小时前更新")
        XCTAssertEqual(HomeChannelRefreshStatusText.text(
            lastSuccessfulRefreshAt: now.addingTimeInterval(-2 * 60 * 60),
            isRefreshing: false,
            now: now
        ), "2 小时前更新")
    }

    func testHomeRefreshPresentationMapKeepsEveryChannelMetadataAndLoadingState() {
        let recommendationDate = Date(timeIntervalSince1970: 101)
        let followingDate = Date(timeIntervalSince1970: 202)
        let hotDate = Date(timeIntervalSince1970: 303)
        let dailyDate = Date(timeIntervalSince1970: 404)
        let presentations = HomeChannelRefreshPresentationMap(
            recommendation: .init(
                metadata: .init(lastSuccessfulRefreshAt: recommendationDate, lastViewedAt: nil),
                isRefreshing: false
            ),
            following: .init(
                metadata: .init(lastSuccessfulRefreshAt: followingDate, lastViewedAt: nil),
                isRefreshing: true
            ),
            hot: .init(
                metadata: .init(lastSuccessfulRefreshAt: hotDate, lastViewedAt: nil),
                isRefreshing: false
            ),
            daily: .init(
                metadata: .init(lastSuccessfulRefreshAt: dailyDate, lastViewedAt: nil),
                isRefreshing: true
            )
        )

        XCTAssertEqual(
            presentations.presentation(for: .recommendation).metadata.lastSuccessfulRefreshAt,
            recommendationDate
        )
        XCTAssertEqual(
            presentations.presentation(for: .following).metadata.lastSuccessfulRefreshAt,
            followingDate
        )
        XCTAssertTrue(presentations.presentation(for: .following).isRefreshing)
        XCTAssertEqual(
            presentations.presentation(for: .hot).metadata.lastSuccessfulRefreshAt,
            hotDate
        )
        XCTAssertEqual(
            presentations.presentation(for: .daily).metadata.lastSuccessfulRefreshAt,
            dailyDate
        )
        XCTAssertTrue(presentations.presentation(for: .daily).isRefreshing)
    }

    func testHomeRefreshIndicatorAppearsForPullOrRefreshAndOtherwiseDisappears() {
        XCTAssertFalse(NativeHomeRefreshIndicatorPresentation.isVisible(
            pullDistance: 0,
            isRefreshing: false
        ))
        XCTAssertFalse(NativeHomeRefreshIndicatorPresentation.isVisible(
            pullDistance: 7.9,
            isRefreshing: false
        ))
        XCTAssertTrue(NativeHomeRefreshIndicatorPresentation.isVisible(
            pullDistance: 8,
            isRefreshing: false
        ))
        XCTAssertTrue(NativeHomeRefreshIndicatorPresentation.isVisible(
            pullDistance: 0,
            isRefreshing: true
        ))
    }

    func testHomeTabDoubleTapRequiresTwoReselectEventsAndTriggersOncePerPair() {
        var gate = NativeHomeTabDoubleTapGate(maximumInterval: 0.5)

        XCTAssertFalse(registerHomeTap(at: 10, gate: &gate))
        XCTAssertTrue(registerHomeTap(at: 10.2, gate: &gate))
        XCTAssertFalse(registerHomeTap(at: 10.3, gate: &gate))
    }

    func testHomeTabDoubleTapDebouncesEventsOutsideInterval() {
        var gate = NativeHomeTabDoubleTapGate(maximumInterval: 0.5)

        XCTAssertFalse(registerHomeTap(at: 10, gate: &gate))
        XCTAssertFalse(registerHomeTap(at: 10.6, gate: &gate))
        XCTAssertTrue(registerHomeTap(at: 10.8, gate: &gate))
    }

    func testHomeTabDoubleTapRejectsNonHomeNonRootAndLockedContexts() {
        var gate = NativeHomeTabDoubleTapGate(maximumInterval: 0.5)
        XCTAssertFalse(gate.register(
            .init(tab: .history, timestamp: 1),
            isHomeSelected: false,
            isHomeRoot: true,
            isAppUnlocked: true
        ))
        XCTAssertFalse(gate.register(
            .init(tab: .home, timestamp: 2),
            isHomeSelected: true,
            isHomeRoot: false,
            isAppUnlocked: true
        ))
        XCTAssertFalse(gate.register(
            .init(tab: .home, timestamp: 2.1),
            isHomeSelected: true,
            isHomeRoot: true,
            isAppUnlocked: false
        ))

        XCTAssertFalse(registerHomeTap(at: 3, gate: &gate))
        XCTAssertTrue(registerHomeTap(at: 3.2, gate: &gate))
    }

    func testInvalidThemeFallsBackWithoutOverwritingStoredRawValue() {
        let defaults = makeDefaults()
        defaults.set("FUTURE", forKey: NativeShellPreferences.Key.themeMode)

        let preferences = NativeShellPreferences(defaults: defaults)

        XCTAssertEqual(preferences.themeMode, .system)
        XCTAssertEqual(defaults.string(forKey: NativeShellPreferences.Key.themeMode), "FUTURE")
    }

    func testRestoredReadingFeedSearchAndSharePreferencesConsumeLegacyKeys() {
        let defaults = makeDefaults()
        defaults.set(125, forKey: NativeShellPreferences.Key.contentFontSize)
        defaults.set(180, forKey: NativeShellPreferences.Key.contentLineHeight)
        defaults.set(130, forKey: NativeShellPreferences.Key.contentBlockSpacing)
        defaults.set(false, forKey: NativeShellPreferences.Key.showFeedThumbnail)
        defaults.set(false, forKey: NativeShellPreferences.Key.showSearchHotSearch)
        defaults.set(false, forKey: NativeShellPreferences.Key.showSearchHistory)
        defaults.set("copy", forKey: NativeShellPreferences.Key.shareActionMode)

        let preferences = NativeShellPreferences(defaults: defaults)

        XCTAssertEqual(preferences.contentFontSizePercent, 125)
        XCTAssertEqual(preferences.contentLineHeightPercent, 180)
        XCTAssertEqual(preferences.contentBlockSpacingPercent, 130)
        XCTAssertFalse(preferences.showsFeedThumbnails)
        XCTAssertFalse(preferences.showsSearchHotSearch)
        XCTAssertFalse(preferences.showsSearchHistory)
        XCTAssertEqual(preferences.defaultShareAction, .copyLink)
    }

    func testRestoredPreferenceSettersPersistSemanticValues() {
        let defaults = makeDefaults()
        let preferences = NativeShellPreferences(defaults: defaults)

        preferences.setFeedDensity(.compact)
        preferences.setFeedExcerptLines(4)
        preferences.setDefaultShareAction(.systemShare)

        XCTAssertEqual(defaults.string(forKey: NativeShellPreferences.Key.feedDensity), "compact")
        XCTAssertEqual(defaults.integer(forKey: NativeShellPreferences.Key.feedExcerptLines), 4)
        XCTAssertEqual(defaults.string(forKey: NativeShellPreferences.Key.shareActionMode), "share")
    }

    func testExpandedRootDoesNotRenderCompactToolbarTitle() {
        XCTAssertFalse(NativeRootCompactTitle.shouldRender(collapseProgress: 0))
        XCTAssertFalse(NativeRootCompactTitle.shouldRender(collapseProgress: 0.49))
        XCTAssertTrue(NativeRootCompactTitle.shouldRender(collapseProgress: 0.5))
    }

    func testRootHeaderCrossfadeHasExactEndpointsAndBalancedMidpoint() {
        XCTAssertEqual(NativeRootHeaderVisibility.expandedOpacity(collapseProgress: 0), 1)
        XCTAssertEqual(NativeRootHeaderVisibility.compactOpacity(collapseProgress: 0), 0)
        XCTAssertEqual(NativeRootHeaderVisibility.expandedOpacity(collapseProgress: 0.5), 0.5)
        XCTAssertEqual(NativeRootHeaderVisibility.compactOpacity(collapseProgress: 0.5), 0.5)
        XCTAssertEqual(NativeRootHeaderVisibility.expandedOpacity(collapseProgress: 1), 0)
        XCTAssertEqual(NativeRootHeaderVisibility.compactOpacity(collapseProgress: 1), 1)
    }

    func testRootHeaderCrossfadeIsMonotonicAndAlwaysSumsToOne() {
        var previousExpanded = Double.infinity
        var previousCompact = -Double.infinity

        for progress in stride(from: CGFloat(0), through: 1, by: 0.01) {
            let expanded = NativeRootHeaderVisibility.expandedOpacity(
                collapseProgress: progress
            )
            let compact = NativeRootHeaderVisibility.compactOpacity(
                collapseProgress: progress
            )

            XCTAssertEqual(expanded + compact, 1, accuracy: 0.001)
            XCTAssertLessThanOrEqual(expanded, previousExpanded)
            XCTAssertGreaterThanOrEqual(compact, previousCompact)
            previousExpanded = expanded
            previousCompact = compact
        }
    }

    func testRefreshHapticRequiresAChangedExistingSuccessTimestamp() {
        let firstSuccess = Date(timeIntervalSince1970: 100)
        let nextSuccess = Date(timeIntervalSince1970: 200)

        XCTAssertFalse(NativeRefreshHapticPolicy.shouldEmit(
            previousSuccessfulRefreshAt: nil,
            currentSuccessfulRefreshAt: firstSuccess
        ))
        XCTAssertFalse(NativeRefreshHapticPolicy.shouldEmit(
            previousSuccessfulRefreshAt: firstSuccess,
            currentSuccessfulRefreshAt: firstSuccess
        ))
        XCTAssertFalse(NativeRefreshHapticPolicy.shouldEmit(
            previousSuccessfulRefreshAt: firstSuccess,
            currentSuccessfulRefreshAt: nil
        ))
        XCTAssertTrue(NativeRefreshHapticPolicy.shouldEmit(
            previousSuccessfulRefreshAt: firstSuccess,
            currentSuccessfulRefreshAt: nextSuccess
        ))
    }

    func testHomeHeaderStaysPinnedAtCompactHeightWithoutMovingListViewport() {
        XCTAssertEqual(NativeHomeHeaderLayoutPolicy.horizontalContentInset, 14)
        XCTAssertEqual(NativeHomeHeaderLayoutPolicy.channelSelectorHeight, 48)
        XCTAssertEqual(NativeHomeHeaderLayoutPolicy.expandedHeaderHeight, 48)

        for progress in stride(from: CGFloat(0), through: 1, by: 0.05) {
            XCTAssertEqual(
                NativeHomeHeaderLayoutPolicy.listViewportOrigin(
                    collapseProgress: progress
                ),
                0
            )
            XCTAssertEqual(
                NativeHomeHeaderLayoutPolicy.visibleHeaderHeight(
                    collapseProgress: progress
                ),
                48,
                accuracy: 0.001
            )
        }
    }

    func testHomeFeedTitlesUseUnlimitedLinesWhileStandardRowsRemainCompact() {
        XCTAssertEqual(FeedItemTitleDisplayMode.compact.lineLimit, 2)
        XCTAssertNil(FeedItemTitleDisplayMode.full.lineLimit)
        XCTAssertEqual(NativeZhihuVisualStyle.titlePointSize, 18)
        XCTAssertEqual(NativeZhihuVisualStyle.summaryPointSize, 16)
        XCTAssertEqual(NativeZhihuVisualStyle.contentSpacing, 8)
    }

    func testRecommendationReturnDoesNotReplayAnAlreadyHandledScrollRequest() {
        XCTAssertFalse(NativeScrollToTopRequestPolicy.shouldHandleChange(
            previousRequest: 4,
            newRequest: 4
        ))
        XCTAssertFalse(NativeScrollToTopRequestPolicy.shouldHandleChange(
            previousRequest: 0,
            newRequest: 0
        ))
        XCTAssertTrue(NativeScrollToTopRequestPolicy.shouldHandleChange(
            previousRequest: 4,
            newRequest: 5
        ))
    }

    func testHomeHeaderCollapseProgressComesFromActualListGeometry() {
        XCTAssertEqual(NativeHomeFeedScrollMetrics.collapseProgress(
            contentOffsetY: -20,
            contentInsetTop: 20
        ), 0)
        XCTAssertEqual(NativeHomeFeedScrollMetrics.collapseProgress(
            contentOffsetY: 4,
            contentInsetTop: 20
        ), 0.5, accuracy: 0.001)
        XCTAssertEqual(NativeHomeFeedScrollMetrics.collapseProgress(
            contentOffsetY: 200,
            contentInsetTop: 20
        ), 1)
        XCTAssertEqual(NativeHomeFeedScrollMetrics.collapseProgress(
            contentOffsetY: -50,
            contentInsetTop: 20
        ), 0)
    }

    func testEveryHomeChannelHasAUniqueMatchingFullHeaderScrollAnchor() {
        let anchors = HomeChannel.allCases.map {
            NativeHomeHeaderLayoutPolicy.scrollAnchor(for: $0)
        }

        XCTAssertEqual(anchors, HomeChannel.allCases)
        XCTAssertEqual(Set(anchors).count, 4)
    }

    func testChannelSelectorPinsEdgeChannelsBeforeCenteringMiddleChannels() {
        let channelIDs = HomeChannel.allCases.map(\.id)

        XCTAssertEqual(
            NativeChannelSelectorScrollAlignment.alignment(
                for: HomeChannel.recommendation.id,
                in: channelIDs
            ),
            .leading
        )
        XCTAssertEqual(
            NativeChannelSelectorScrollAlignment.alignment(
                for: HomeChannel.following.id,
                in: channelIDs
            ),
            .center
        )
        XCTAssertEqual(
            NativeChannelSelectorScrollAlignment.alignment(
                for: HomeChannel.daily.id,
                in: channelIDs
            ),
            .trailing
        )
    }

    func testOnlySelectedChannelOwnsScrolling() {
        let selection = HomeChannel.following.id
        let activeChannels = HomeChannel.allCases.filter { channel in
            NativeChannelPresentationPolicy.isActive(
                isEnabled: true,
                channelID: channel.id,
                selection: selection
            )
        }

        XCTAssertEqual(activeChannels, [.following])
        XCTAssertFalse(NativeChannelPresentationPolicy.isActive(
            isEnabled: true,
            channelID: HomeChannel.recommendation.id,
            selection: HomeChannel.following.id
        ))
        XCTAssertFalse(NativeChannelPresentationPolicy.isActive(
            isEnabled: false,
            channelID: selection,
            selection: selection
        ))
    }

    func testChannelPagesShareOneContinuousHorizontalCoordinateSystem() {
        let width: CGFloat = 390
        let drag: CGFloat = -117

        XCTAssertEqual(NativeChannelPageTransitionPolicy.pageOffset(
            pageIndex: 0,
            selectedIndex: 1,
            containerWidth: width,
            dragTranslation: drag
        ), -507)
        XCTAssertEqual(NativeChannelPageTransitionPolicy.pageOffset(
            pageIndex: 1,
            selectedIndex: 1,
            containerWidth: width,
            dragTranslation: drag
        ), -117)
        XCTAssertEqual(NativeChannelPageTransitionPolicy.pageOffset(
            pageIndex: 2,
            selectedIndex: 1,
            containerWidth: width,
            dragTranslation: drag
        ), 273)
    }

    func testChannelInteractiveTranslationClampsPagesAndEdges() {
        XCTAssertEqual(NativeChannelPageTransitionPolicy.interactiveTranslation(
            rawTranslation: -500,
            currentIndex: 1,
            channelCount: 4,
            containerWidth: 390
        ), -390)
        XCTAssertEqual(NativeChannelPageTransitionPolicy.interactiveTranslation(
            rawTranslation: 80,
            currentIndex: 0,
            channelCount: 4,
            containerWidth: 390
        ), 0)
        XCTAssertEqual(NativeChannelPageTransitionPolicy.interactiveTranslation(
            rawTranslation: -80,
            currentIndex: 3,
            channelCount: 4,
            containerWidth: 390
        ), 0)
    }

    func testNonScrollableNestedStripDoesNotExcludeChannelSwipe() {
        XCTAssertFalse(NativeChannelSwipeExclusionPolicy.shouldExcludeParentSwipe(
            isMarkedForExclusion: true,
            nestedContentWidth: 120,
            nestedViewportWidth: 390
        ))
        XCTAssertTrue(NativeChannelSwipeExclusionPolicy.shouldExcludeParentSwipe(
            isMarkedForExclusion: true,
            nestedContentWidth: 520,
            nestedViewportWidth: 390
        ))
        XCTAssertFalse(NativeChannelSwipeExclusionPolicy.shouldExcludeParentSwipe(
            isMarkedForExclusion: false,
            nestedContentWidth: nil,
            nestedViewportWidth: nil
        ))
    }

    func testChannelSwipeDirectionLockRejectsVerticalPan() {
        XCTAssertFalse(NativeChannelSwipePolicy.shouldBegin(velocity: CGPoint(x: 20, y: 300)))
        XCTAssertFalse(NativeChannelSwipePolicy.shouldBegin(velocity: CGPoint(x: 100, y: 100)))
        XCTAssertTrue(NativeChannelSwipePolicy.shouldBegin(velocity: CGPoint(x: 300, y: 20)))
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "NativeShellPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func channelTarget(
        currentIndex: Int,
        translation: CGSize,
        predicted: CGSize,
        containerWidth: CGFloat = 100
    ) -> Int {
        NativeChannelSwipePolicy.targetIndex(
            currentIndex: currentIndex,
            channelCount: HomeChannel.allCases.count,
            translation: translation,
            predictedEndTranslation: predicted,
            containerWidth: containerWidth
        )
    }

    private func registerHomeTap(
        at timestamp: TimeInterval,
        gate: inout NativeHomeTabDoubleTapGate
    ) -> Bool {
        gate.register(
            .init(tab: .home, timestamp: timestamp),
            isHomeSelected: true,
            isHomeRoot: true,
            isAppUnlocked: true
        )
    }
}
