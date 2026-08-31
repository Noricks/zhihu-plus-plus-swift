import SwiftUI

struct HomeChannelRefreshPresentation: Equatable {
    let metadata: FeedChannelRefreshMetadata
    let isRefreshing: Bool

    func statusText(now: Date) -> String {
        HomeChannelRefreshStatusText.text(
            lastSuccessfulRefreshAt: metadata.lastSuccessfulRefreshAt,
            isRefreshing: isRefreshing,
            now: now
        )
    }
}

struct HomeChannelRefreshPresentationMap: Equatable {
    let recommendation: HomeChannelRefreshPresentation
    let following: HomeChannelRefreshPresentation
    let hot: HomeChannelRefreshPresentation
    let daily: HomeChannelRefreshPresentation

    func presentation(for channel: HomeChannel) -> HomeChannelRefreshPresentation {
        switch channel {
        case .recommendation: return recommendation
        case .following: return following
        case .hot: return hot
        case .daily: return daily
        }
    }
}

@available(iOS 16.0, *)
@MainActor
struct HomeChannelsNativeView: View {
    @Binding var selectedChannelID: HomeChannel.ID

    @ObservedObject private var recommendationStore: HomeFeedNativeStore
    @ObservedObject private var followingStore: FollowNativeStore
    @ObservedObject private var hotStore: HotFeedStore
    @ObservedObject private var dailyStore: DailyNativeStore

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.nativeHapticFeedback) private var hapticFeedback
    @State private var lastSelectedChannelID: HomeChannel.ID
    @State private var scrollToTopRequests: [HomeChannel: UInt] = [:]
    @State private var collapseProgressByChannel: [HomeChannel: CGFloat] = [:]
    @State private var idleRefreshTask: Task<Void, Never>?
    @State private var doubleTapRefreshTask: Task<Void, Never>?
    @State private var doubleTapRefreshGeneration: UInt = 0
    @State private var wasOperationallyVisible = false
    @State private var refreshStatusNow = Date()

    let isOperationallyVisible: Bool
    let doubleTapRefreshRequest: UInt
    let onOpenFeed: (FeedItemRoute) -> Void
    let onOpenPerson: (PersonRoutePayload) -> Void
    let onOpenDaily: (DailyStoryDestination) -> Void

    init(
        selectedChannelID: Binding<HomeChannel.ID>,
        recommendationStore: HomeFeedNativeStore,
        followingStore: FollowNativeStore,
        hotStore: HotFeedStore,
        dailyStore: DailyNativeStore,
        doubleTapRefreshRequest: UInt,
        isOperationallyVisible: Bool,
        onOpenFeed: @escaping (FeedItemRoute) -> Void,
        onOpenPerson: @escaping (PersonRoutePayload) -> Void,
        onOpenDaily: @escaping (DailyStoryDestination) -> Void
    ) {
        _selectedChannelID = selectedChannelID
        _recommendationStore = ObservedObject(wrappedValue: recommendationStore)
        _followingStore = ObservedObject(wrappedValue: followingStore)
        _hotStore = ObservedObject(wrappedValue: hotStore)
        _dailyStore = ObservedObject(wrappedValue: dailyStore)
        _lastSelectedChannelID = State(initialValue: selectedChannelID.wrappedValue)
        self.doubleTapRefreshRequest = doubleTapRefreshRequest
        self.isOperationallyVisible = isOperationallyVisible
        self.onOpenFeed = onOpenFeed
        self.onOpenPerson = onOpenPerson
        self.onOpenDaily = onOpenDaily
    }

    var body: some View {
        let refreshPresentations = currentRefreshPresentations
        NativeChannelSwitcher(
            channels: HomeChannel.allCases,
            selection: $selectedChannelID,
            isEnabled: isOperationallyVisible,
            title: \.title,
            status: {
                refreshPresentations.presentation(for: $0).statusText(
                    now: refreshStatusNow
                )
            },
            onPrefetch: prefetchChannel
        ) { channel in
            channelContent(channel)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(isOperationallyVisible ? .hidden : .visible, for: .navigationBar)
        .onAppear {
            lastSelectedChannelID = selectedChannelID
            synchronizeOperationalVisibility()
        }
        .onDisappear {
            transitionOperationalVisibility(to: false)
            cancelDoubleTapRefresh()
        }
        .onChange(of: selectedChannelID) { newChannelID in
            guard newChannelID != lastSelectedChannelID else { return }
            cancelDoubleTapRefresh()
            if wasOperationallyVisible,
               let previous = HomeChannel(rawValue: lastSelectedChannelID) {
                recordLastViewed(for: previous)
            }
            lastSelectedChannelID = newChannelID
            if wasOperationallyVisible {
                scheduleIdleRefreshIfNeeded(for: selectedChannel)
            }
        }
        .onChange(of: isOperationallyVisible) { _ in
            synchronizeOperationalVisibility()
        }
        .onChange(of: doubleTapRefreshRequest) { request in
            guard request > 0 else { return }
            scheduleDoubleTapRefresh()
        }
        .onChange(of: scenePhase) { _ in
            synchronizeOperationalVisibility()
        }
        .task {
            await runRefreshStatusClock()
        }
        .accessibilityIdentifier("home_channels_native")
    }

    @ViewBuilder
    private func channelContent(_ channel: HomeChannel) -> some View {
        switch channel {
        case .recommendation:
            HomeNativeView(
                store: recommendationStore,
                collapseProgress: collapseProgressBinding(for: channel),
                scrollToTopRequest: scrollRequest(for: channel),
                onOpen: onOpenFeed
            )
        case .following:
            FollowNativeView(
                store: followingStore,
                collapseProgress: collapseProgressBinding(for: channel),
                scrollToTopRequest: scrollRequest(for: channel),
                onOpen: onOpenFeed,
                onOpenPerson: onOpenPerson
            )
        case .hot:
            HotListNativeView(
                store: hotStore,
                collapseProgress: collapseProgressBinding(for: channel),
                scrollToTopRequest: scrollRequest(for: channel),
                onOpen: onOpenFeed
            )
        case .daily:
            DailyNativeView(
                store: dailyStore,
                collapseProgress: collapseProgressBinding(for: channel),
                scrollToTopRequest: scrollRequest(for: channel),
                onOpen: onOpenDaily
            )
        }
    }

    private var selectedChannel: HomeChannel {
        HomeChannel(rawValue: selectedChannelID) ?? .recommendation
    }

    private func collapseProgressBinding(for channel: HomeChannel) -> Binding<CGFloat> {
        Binding(
            get: { collapseProgressByChannel[channel, default: 0] },
            set: { collapseProgressByChannel[channel] = min(max($0, 0), 1) }
        )
    }

    private var isEffectivelyVisible: Bool {
        isOperationallyVisible && scenePhase == .active
    }

    private func scrollRequest(for channel: HomeChannel) -> UInt {
        scrollToTopRequests[channel, default: 0]
    }

    private func scheduleIdleRefreshIfNeeded(for channel: HomeChannel) {
        idleRefreshTask?.cancel()
        idleRefreshTask = Task { @MainActor in
            guard isEffectivelyVisible,
                  selectedChannelID == channel.id,
                  needsRefreshAfterIdle(channel)
            else { return }
            if channel == .recommendation, recommendationStore.isLoading {
                return
            }

            scrollToTopRequests[channel, default: 0] &+= 1
            do {
                // Match the confirmed MNGA sequence: allow the scroll-to-top animation
                // to settle before replacing the first page.
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  isEffectivelyVisible,
                  selectedChannelID == channel.id,
                  needsRefreshAfterIdle(channel)
            else { return }
            if channel == .recommendation {
                _ = await recommendationStore.refresh(intent: .automatic)
                return
            }
            guard await waitUntilIdle(for: channel) else { return }
            let previousSuccessfulRefresh = successfulRefreshDate(for: channel)
            await refresh(channel)
            guard !Task.isCancelled,
                  selectedChannelID == channel.id,
                  NativeRefreshHapticPolicy.shouldEmit(
                    previousSuccessfulRefreshAt: previousSuccessfulRefresh,
                    currentSuccessfulRefreshAt: successfulRefreshDate(for: channel)
                  )
            else { return }
            hapticFeedback(.refreshSucceeded)
        }
    }

    private func scheduleDoubleTapRefresh() {
        guard doubleTapRefreshTask == nil, isEffectivelyVisible else { return }
        idleRefreshTask?.cancel()
        let channel = selectedChannel
        doubleTapRefreshGeneration &+= 1
        let generation = doubleTapRefreshGeneration
        scrollToTopRequests[channel, default: 0] &+= 1

        doubleTapRefreshTask = Task { @MainActor in
            defer {
                if generation == doubleTapRefreshGeneration {
                    doubleTapRefreshTask = nil
                }
            }
            if channel == .recommendation {
                guard !Task.isCancelled,
                      generation == doubleTapRefreshGeneration,
                      isEffectivelyVisible,
                      selectedChannelID == channel.id
                else { return }
                _ = await recommendationStore.refresh(intent: .returnToTop)
                return
            }
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  generation == doubleTapRefreshGeneration,
                  isEffectivelyVisible,
                  selectedChannelID == channel.id,
                  await waitUntilIdle(for: channel)
            else { return }
            let previousSuccessfulRefresh = successfulRefreshDate(for: channel)
            await refresh(channel)
            guard !Task.isCancelled,
                  generation == doubleTapRefreshGeneration,
                  selectedChannelID == channel.id,
                  NativeRefreshHapticPolicy.shouldEmit(
                    previousSuccessfulRefreshAt: previousSuccessfulRefresh,
                    currentSuccessfulRefreshAt: successfulRefreshDate(for: channel)
                  )
            else { return }
            hapticFeedback(.refreshSucceeded)
        }
    }

    private func cancelDoubleTapRefresh() {
        doubleTapRefreshGeneration &+= 1
        doubleTapRefreshTask?.cancel()
        doubleTapRefreshTask = nil
    }

    private func synchronizeOperationalVisibility() {
        transitionOperationalVisibility(to: isEffectivelyVisible)
    }

    private func transitionOperationalVisibility(to isVisible: Bool) {
        guard isVisible != wasOperationallyVisible else { return }
        let wasVisible = wasOperationallyVisible
        wasOperationallyVisible = isVisible
        idleRefreshTask?.cancel()
        if !isVisible { cancelDoubleTapRefresh() }
        if wasVisible {
            recordLastViewed(for: selectedChannel)
        }
        if isVisible {
            scheduleIdleRefreshIfNeeded(for: selectedChannel)
        }
    }

    private func waitUntilIdle(for channel: HomeChannel) async -> Bool {
        // A pagination request may still be unwinding after the channel becomes active.
        // Wait for at most five seconds so automatic refresh never spins or waits forever.
        for _ in 0..<50 {
            guard !Task.isCancelled,
                  isEffectivelyVisible,
                  selectedChannelID == channel.id
            else { return false }
            if !isLoading(channel) { return true }
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return false
            }
        }
        return false
    }

    private func isLoading(_ channel: HomeChannel) -> Bool {
        switch channel {
        case .recommendation: return recommendationStore.isLoading
        case .following: return followingStore.isMomentsLoading
        case .hot: return hotStore.isLoading
        case .daily: return dailyStore.isLoading || dailyStore.isLoadingMore
        }
    }

    private func recordLastViewed(for channel: HomeChannel) {
        switch channel {
        case .recommendation: recommendationStore.recordLastViewed()
        case .following: followingStore.recordLastViewed()
        case .hot: hotStore.recordLastViewed()
        case .daily: dailyStore.recordLastViewed()
        }
    }

    private func needsRefreshAfterIdle(_ channel: HomeChannel) -> Bool {
        switch channel {
        case .recommendation: return recommendationStore.needsRefreshAfterIdle()
        case .following: return followingStore.needsRefreshAfterIdle()
        case .hot: return hotStore.needsRefreshAfterIdle()
        case .daily: return dailyStore.needsRefreshAfterIdle()
        }
    }

    private func refresh(_ channel: HomeChannel) async {
        switch channel {
        case .recommendation: await recommendationStore.refresh()
        case .following: await followingStore.refresh(section: .moments)
        case .hot: await hotStore.refresh()
        case .daily: await dailyStore.refresh()
        }
    }

    private func prefetchChannel(_ channel: HomeChannel) {
        guard isOperationallyVisible else { return }
        Task { @MainActor in
            guard isOperationallyVisible else { return }
            switch channel {
            case .recommendation:
                await recommendationStore.loadInitialIfNeeded()
            case .following:
                await followingStore.loadMomentsIfNeeded()
            case .hot:
                await hotStore.loadInitialIfNeeded()
            case .daily:
                await dailyStore.loadInitialIfNeeded()
            }
        }
    }

    private func successfulRefreshDate(for channel: HomeChannel) -> Date? {
        switch channel {
        case .recommendation: return recommendationStore.refreshMetadata.lastSuccessfulRefreshAt
        case .following: return followingStore.refreshMetadata.lastSuccessfulRefreshAt
        case .hot: return hotStore.refreshMetadata.lastSuccessfulRefreshAt
        case .daily: return dailyStore.refreshMetadata.lastSuccessfulRefreshAt
        }
    }

    private var currentRefreshPresentations: HomeChannelRefreshPresentationMap {
        HomeChannelRefreshPresentationMap(
            recommendation: HomeChannelRefreshPresentation(
                metadata: recommendationStore.refreshMetadata,
                isRefreshing: recommendationStore.isRefreshing
            ),
            following: HomeChannelRefreshPresentation(
                metadata: followingStore.refreshMetadata,
                isRefreshing: followingStore.isMomentsRefreshing
            ),
            hot: HomeChannelRefreshPresentation(
                metadata: hotStore.refreshMetadata,
                isRefreshing: hotStore.isRefreshing
            ),
            daily: HomeChannelRefreshPresentation(
                metadata: dailyStore.refreshMetadata,
                isRefreshing: dailyStore.isRefreshing
            )
        )
    }

    private func runRefreshStatusClock() async {
        refreshStatusNow = Date()
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch {
                return
            }
            refreshStatusNow = Date()
        }
    }

}

enum HomeChannelRefreshStatusText {
    static func text(
        lastSuccessfulRefreshAt: Date?,
        isRefreshing: Bool,
        now: Date
    ) -> String {
        if isRefreshing { return "更新中…" }
        guard let lastSuccessfulRefreshAt else { return "尚未更新" }

        let elapsed = max(0, now.timeIntervalSince(lastSuccessfulRefreshAt))
        if elapsed < 60 { return "刚刚更新" }
        if elapsed < 60 * 60 {
            return "\(max(1, Int(elapsed / 60))) 分钟前更新"
        }
        return "\(max(1, Int(elapsed / (60 * 60)))) 小时前更新"
    }
}
