import SwiftUI
import UIKit

struct NativeChannelTaskIdentity: Hashable {
    let isActive: Bool
    let value: String?
}

private struct NativeHomeFeedListLayout: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        content
            .environment(\.defaultMinListRowHeight, 1)
            .scrollContentBackground(.hidden)
            .background(NativeZhihuVisualStyle.backgroundColor)
    }
}

private struct NativeHomeFeedScrollTracking: ViewModifier {
    @Binding var collapseProgress: CGFloat
    let isActive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                NativeHomeFeedScrollMetrics.collapseProgress(
                    contentOffsetY: geometry.contentOffset.y,
                    contentInsetTop: geometry.contentInsets.top
                )
            } action: { _, newProgress in
                guard isActive else { return }
                collapseProgress = newProgress
            }
        } else {
            content
        }
    }
}

enum NativeHomeFeedScrollMetrics {
    static let collapseDistance = NativeHomeHeaderLayoutPolicy.expandedHeaderHeight
    static let fallbackCollapseDistance: CGFloat = collapseDistance

    static func collapseProgress(
        contentOffsetY: CGFloat,
        contentInsetTop: CGFloat
    ) -> CGFloat {
        let effectiveOffset = contentOffsetY + contentInsetTop
        return min(max(effectiveOffset / collapseDistance, 0), 1)
    }
}

struct NativeScrollToTopRequestPolicy {
    static func shouldHandleChange(
        previousRequest: UInt,
        newRequest: UInt
    ) -> Bool {
        newRequest > 0 && newRequest != previousRequest
    }
}

struct NativeHomeHeaderLayoutPolicy {
    static let horizontalContentInset: CGFloat = 14
    static let channelSelectorHeight: CGFloat = 48
    static let expandedHeaderHeight = channelSelectorHeight

    static func normalized(_ collapseProgress: CGFloat) -> CGFloat {
        min(max(collapseProgress, 0), 1)
    }

    static func visibleHeaderHeight(collapseProgress _: CGFloat) -> CGFloat {
        expandedHeaderHeight
    }

    static func listViewportOrigin(collapseProgress _: CGFloat) -> CGFloat {
        0
    }

    static func scrollAnchor(for channel: HomeChannel) -> HomeChannel {
        channel
    }
}

struct NativeRootHeaderVisibility {
    static let compactThreshold: CGFloat = 0.5
    static let crossfadeLowerBound: CGFloat = 0.35
    static let crossfadeUpperBound: CGFloat = 0.65

    static func expandedOpacity(collapseProgress: CGFloat) -> Double {
        1 - compactOpacity(collapseProgress: collapseProgress)
    }

    static func compactOpacity(collapseProgress: CGFloat) -> Double {
        let progress = normalized(collapseProgress)
        guard progress > crossfadeLowerBound else { return 0 }
        guard progress < crossfadeUpperBound else { return 1 }

        let range = crossfadeUpperBound - crossfadeLowerBound
        let fraction = (progress - crossfadeLowerBound) / range
        return Double(fraction * fraction * (3 - 2 * fraction))
    }

    static func usesCompactSemantics(collapseProgress: CGFloat) -> Bool {
        normalized(collapseProgress) >= compactThreshold
    }

    private static func normalized(_ collapseProgress: CGFloat) -> CGFloat {
        min(max(collapseProgress, 0), 1)
    }
}

struct NativeHomeRefreshIndicatorPresentation {
    static let fullyRevealedPullDistance: CGFloat = 30
    static let minimumScale: CGFloat = 0.72

    static func progress(
        pullDistance: CGFloat,
        isRefreshing: Bool
    ) -> CGFloat {
        guard !isRefreshing else { return 1 }
        let normalized = min(max(pullDistance / fullyRevealedPullDistance, 0), 1)
        return 1 - (1 - normalized) * (1 - normalized)
    }

    static func isVisible(
        pullDistance: CGFloat,
        isRefreshing: Bool
    ) -> Bool {
        progress(pullDistance: pullDistance, isRefreshing: isRefreshing) > 0
    }

    static func opacity(
        pullDistance: CGFloat,
        isRefreshing: Bool
    ) -> Double {
        Double(progress(pullDistance: pullDistance, isRefreshing: isRefreshing))
    }

    static func scale(
        pullDistance: CGFloat,
        isRefreshing: Bool
    ) -> CGFloat {
        minimumScale + (1 - minimumScale) * progress(
            pullDistance: pullDistance,
            isRefreshing: isRefreshing
        )
    }
}

struct NativeShortPullRefreshPolicy {
    /// Deliberately shorter than UIRefreshControl's system threshold. This is
    /// enough to make the gesture intentional without requiring a large pull.
    static let triggerDistance: CGFloat = 32
    static let settledDistance: CGFloat = 44

    static func shouldTrigger(
        maximumPullDistance: CGFloat,
        isEnabled: Bool,
        isRefreshing: Bool
    ) -> Bool {
        isEnabled && !isRefreshing && maximumPullDistance >= triggerDistance
    }
}

private struct NativeHomeRefreshIndicator: View {
    let pullDistance: CGFloat
    let isRefreshing: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let progress = NativeHomeRefreshIndicatorPresentation.progress(
            pullDistance: pullDistance,
            isRefreshing: isRefreshing
        )
        ZStack {
            if isRefreshing {
                NativeHomeLoadingSpinner(reduceMotion: reduceMotion)
                    .transition(.opacity.combined(with: .scale(scale: 0.78)))
            } else {
                Image(systemName: "arrow.down")
                    .font(.system(size: 15, weight: .semibold))
                    .rotationEffect(.degrees(Double(progress) * 180))
                    .transition(.opacity.combined(with: .scale(scale: 0.78)))
            }
        }
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .opacity(NativeHomeRefreshIndicatorPresentation.opacity(
                pullDistance: pullDistance,
                isRefreshing: isRefreshing
            ))
            .scaleEffect(NativeHomeRefreshIndicatorPresentation.scale(
                pullDistance: pullDistance,
                isRefreshing: isRefreshing
            ))
            .animation(.easeInOut(duration: 0.18), value: isRefreshing)
            .accessibilityHidden(!NativeHomeRefreshIndicatorPresentation.isVisible(
                pullDistance: pullDistance,
                isRefreshing: isRefreshing
            ))
            .accessibilityLabel("正在更新")
            .accessibilityIdentifier("home_refresh_indicator")
    }
}

private struct NativeHomeLoadingSpinner: View {
    let reduceMotion: Bool

    var body: some View {
        if reduceMotion {
            spinnerShape
        } else {
            TimelineView(.animation(minimumInterval: 1 / 60)) { context in
                let elapsed = context.date.timeIntervalSinceReferenceDate
                spinnerShape
                    .rotationEffect(.degrees(elapsed.truncatingRemainder(dividingBy: 0.72) / 0.72 * 360))
            }
        }
    }

    private var spinnerShape: some View {
        Circle()
            .trim(from: 0.12, to: 0.86)
            .stroke(style: StrokeStyle(lineWidth: 2.1, lineCap: .round))
            .frame(width: 17, height: 17)
    }
}

private struct NativeShortPullRefreshModifier: ViewModifier {
    let isEnabled: Bool
    let action: @MainActor () async -> Void

    func body(content: Content) -> some View {
        content.background {
            NativeShortPullRefreshInstaller(
                isEnabled: isEnabled,
                action: action
            )
                .frame(width: 0, height: 0)
        }
    }
}

private struct NativeShortPullRefreshInstaller: UIViewRepresentable {
    let isEnabled: Bool
    let action: @MainActor () async -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.update(isEnabled: isEnabled, action: action)
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.update(isEnabled: isEnabled, action: action)
        uiView.scheduleInstallation()
    }

    static func dismantleUIView(_ uiView: ProbeView, coordinator: Void) {
        uiView.detach()
    }

    @MainActor
    final class ProbeView: UIView {
        private weak var installedScrollView: UIScrollView?
        private let refreshControl = UIRefreshControl()
        private var maximumPullDistance: CGFloat = 0
        private var refreshTask: Task<Void, Never>?
        private var isRefreshEnabled = true
        private var action: (@MainActor () async -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            refreshControl.tintColor = .clear
            refreshControl.addTarget(
                self,
                action: #selector(handleSystemRefresh),
                for: .valueChanged
            )
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            scheduleInstallation()
        }

        func update(
            isEnabled: Bool,
            action: @escaping @MainActor () async -> Void
        ) {
            isRefreshEnabled = isEnabled
            refreshControl.isEnabled = isEnabled
            self.action = action
            if !isEnabled { maximumPullDistance = 0 }
        }

        func scheduleInstallation() {
            DispatchQueue.main.async { [weak self] in
                self?.installIfNeeded()
            }
        }

        func detach() {
            refreshTask?.cancel()
            refreshTask = nil
            if let installedScrollView {
                installedScrollView.panGestureRecognizer.removeTarget(
                    self,
                    action: #selector(handlePan(_:))
                )
                if installedScrollView.refreshControl === refreshControl {
                    installedScrollView.refreshControl = nil
                }
            }
            installedScrollView = nil
        }

        private func installIfNeeded() {
            guard let scrollView = ancestorScrollView() else { return }
            guard installedScrollView !== scrollView else { return }
            detach()
            installedScrollView = scrollView
            scrollView.refreshControl = refreshControl
            scrollView.panGestureRecognizer.addTarget(self, action: #selector(handlePan(_:)))
        }

        private func ancestorScrollView() -> UIScrollView? {
            var candidate = superview
            while let view = candidate {
                if let scrollView = view as? UIScrollView { return scrollView }
                candidate = view.superview
            }
            return nil
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let scrollView = installedScrollView,
                  refreshTask == nil,
                  !refreshControl.isRefreshing
            else { return }

            switch gesture.state {
            case .began:
                maximumPullDistance = pullDistance(in: scrollView)
            case .changed:
                maximumPullDistance = max(
                    maximumPullDistance,
                    pullDistance(in: scrollView)
                )
            case .ended:
                let shouldTrigger = NativeShortPullRefreshPolicy.shouldTrigger(
                    maximumPullDistance: maximumPullDistance,
                    isEnabled: isRefreshEnabled,
                    isRefreshing: refreshTask != nil || refreshControl.isRefreshing
                )
                maximumPullDistance = 0
                if shouldTrigger { beginRefresh(in: scrollView) }
            case .cancelled, .failed:
                maximumPullDistance = 0
            default:
                break
            }
        }

        @objc private func handleSystemRefresh() {
            guard let scrollView = installedScrollView else { return }
            beginRefresh(in: scrollView)
        }

        private func beginRefresh(in scrollView: UIScrollView) {
            guard refreshTask == nil, isRefreshEnabled, let action else {
                refreshControl.endRefreshing()
                return
            }

            let topInset = scrollView.adjustedContentInset.top
            if !refreshControl.isRefreshing { refreshControl.beginRefreshing() }
            let targetOffset = CGPoint(
                x: scrollView.contentOffset.x,
                y: -(topInset + NativeShortPullRefreshPolicy.settledDistance)
            )
            UIView.animate(
                withDuration: 0.2,
                delay: 0,
                options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]
            ) {
                scrollView.setContentOffset(targetOffset, animated: false)
            }

            refreshTask = Task { @MainActor [weak self] in
                await action()
                guard let self, !Task.isCancelled else { return }
                self.finishRefresh()
            }
        }

        private func finishRefresh() {
            refreshTask = nil
            UIView.animate(
                withDuration: 0.24,
                delay: 0,
                options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseInOut]
            ) {
                self.refreshControl.endRefreshing()
                self.installedScrollView?.layoutIfNeeded()
            }
        }

        private func pullDistance(in scrollView: UIScrollView) -> CGFloat {
            max(-(scrollView.contentOffset.y + scrollView.adjustedContentInset.top), 0)
        }
    }
}

extension View {
    func nativeHomeFeedListLayout() -> some View {
        modifier(NativeHomeFeedListLayout())
    }

    func nativeHomeFeedScrollTracking(
        collapseProgress: Binding<CGFloat>,
        isActive: Bool
    ) -> some View {
        modifier(NativeHomeFeedScrollTracking(
            collapseProgress: collapseProgress,
            isActive: isActive
        ))
    }

    func nativeShortPullRefresh(
        isEnabled: Bool,
        action: @escaping @MainActor () async -> Void
    ) -> some View {
        modifier(NativeShortPullRefreshModifier(
            isEnabled: isEnabled,
            action: action
        ))
    }
}

private struct NativeRootTitleOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = .nan
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct NativeRootLargeTitle: View {
    let title: String
    let coordinateSpaceName: String
    let displaysTitle: Bool
    let isActive: Bool
    let isRefreshing: Bool
    @Binding var collapseProgress: CGFloat
    @State private var latestMinY: CGFloat = .nan
    @State private var fallbackIsCollapsed = false

    init(
        _ title: String,
        coordinateSpaceName: String = "home-root-scroll",
        displaysTitle: Bool = true,
        isActive: Bool = true,
        isRefreshing: Bool = false,
        collapseProgress: Binding<CGFloat>
    ) {
        self.title = title
        self.coordinateSpaceName = coordinateSpaceName
        self.displaysTitle = displaysTitle
        self.isActive = isActive
        self.isRefreshing = isRefreshing
        _collapseProgress = collapseProgress
    }

    var body: some View {
        Group {
            if displaysTitle {
                Text(title)
                    .font(.largeTitle.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(1 - collapseProgress)
                    .offset(y: -6 * collapseProgress)
            } else {
                Color.clear
                    .frame(height: NativeHomeHeaderLayoutPolicy.expandedHeaderHeight)
                    .overlay(alignment: .top) {
                        // The native refresh control lives above this transparent spacer
                        // and is covered by the fixed opaque header. This duplicate visual
                        // follows the pull continuously so it does not pop in abruptly.
                        NativeHomeRefreshIndicator(
                            pullDistance: pullDistance,
                            isRefreshing: isRefreshing
                        )
                            .padding(.top, 14)
                    }
            }
        }
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: NativeRootTitleOffsetKey.self,
                        value: geometry.frame(in: .named(coordinateSpaceName)).minY
                    )
                }
            }
            .onPreferenceChange(NativeRootTitleOffsetKey.self) { minY in
                guard minY.isFinite else { return }
                latestMinY = minY
                reportCollapseProgress(minY: minY)
            }
            .onChange(of: isActive) { active in
                guard active, latestMinY.isFinite else { return }
                reportCollapseProgress(minY: latestMinY)
            }
            .listRowInsets(displaysTitle
                ? EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
                : EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .accessibilityHidden(!displaysTitle)
            .accessibilityAddTraits(.isHeader)
    }

    private func reportCollapseProgress(minY: CGFloat) {
        guard isActive else { return }
        if #available(iOS 18.0, *) { return }
        let progress = min(
            max(-minY / NativeHomeFeedScrollMetrics.fallbackCollapseDistance, 0),
            1
        )
        if progress >= 1 {
            fallbackIsCollapsed = true
            collapseProgress = 1
            return
        }
        if fallbackIsCollapsed {
            // A virtualized probe can emit its default value after leaving the List.
            // Keep the collapsed state until the real probe re-enters from above.
            if minY > 0 {
                fallbackIsCollapsed = false
                collapseProgress = 0
                return
            }
            guard minY < 0 else { return }
            fallbackIsCollapsed = false
        }
        collapseProgress = progress
    }

    private var pullDistance: CGFloat {
        guard latestMinY.isFinite else { return 0 }
        return max(latestMinY, 0)
    }

}

struct NativeRootCompactTitle: View {
    let title: String
    let subtitle: String?
    let collapseProgress: CGFloat

    init(_ title: String, subtitle: String? = nil, collapseProgress: CGFloat) {
        self.title = title
        self.subtitle = subtitle
        self.collapseProgress = collapseProgress
    }

    static func shouldRender(collapseProgress: CGFloat) -> Bool {
        NativeRootHeaderVisibility.usesCompactSemantics(
            collapseProgress: collapseProgress
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)

            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .opacity(
                NativeRootHeaderVisibility.compactOpacity(
                    collapseProgress: collapseProgress
                )
            )
            .accessibilityHidden(
                !NativeRootHeaderVisibility.usesCompactSemantics(
                    collapseProgress: collapseProgress
                )
            )
    }
}

@available(iOS 16.0, *)
struct HomeNativeView: View {
    @ObservedObject private var store: HomeFeedNativeStore
    @EnvironmentObject private var questionAuthorBlocklist: QuestionAuthorBlocklistStore
    @Environment(\.nativeChannelIsActive) private var isActiveChannel
    @Environment(\.nativeHapticFeedback) private var hapticFeedback
    @Binding private var collapseProgress: CGFloat
    @State private var observedScrollToTopRequest: UInt
    let scrollToTopRequest: UInt
    let onOpen: (FeedItemRoute) -> Void

    init(
        store: HomeFeedNativeStore,
        collapseProgress: Binding<CGFloat> = .constant(0),
        scrollToTopRequest: UInt,
        onOpen: @escaping (FeedItemRoute) -> Void
    ) {
        _store = ObservedObject(wrappedValue: store)
        _collapseProgress = collapseProgress
        _observedScrollToTopRequest = State(initialValue: scrollToTopRequest)
        self.scrollToTopRequest = scrollToTopRequest
        self.onOpen = onOpen
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                NativeRootLargeTitle(
                    "首页",
                    displaysTitle: false,
                    isActive: isActiveChannel,
                    isRefreshing: store.isRefreshing,
                    collapseProgress: $collapseProgress
                )
                    .id(NativeHomeHeaderLayoutPolicy.scrollAnchor(for: .recommendation))

                if store.items.isEmpty, store.isLoading {
                    HStack { Spacer(); ProgressView("正在加载推荐"); Spacer() }
                        .listRowSeparator(.hidden)
                }

                ForEach(visibleItems) { item in
                    FeedItemRow(item: item, showsThumbnail: true, titleDisplayMode: .full) { route in
                        store.opened(item)
                        onOpen(route)
                    }
                    .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
                    .listRowBackground(NativeZhihuVisualStyle.backgroundColor)
                    .listRowSeparatorTint(NativeZhihuVisualStyle.separatorColor)
                    .onAppear {
                        guard isActiveChannel else { return }
                        Task { await store.prefetchNextPageIfNeeded(after: item.id) }
                    }
                }

                if let message = store.errorMessage {
                    FeedRetryRow(message: message) { Task { await store.retry() } }
                } else if store.hasNextPage {
                    let taskID = NativeChannelTaskIdentity(
                        isActive: isActiveChannel,
                        value: store.nextPageLoadID
                    )
                    NativeFeedPaginationLoadingRow(title: "正在加载更多推荐")
                        .listRowSeparator(.hidden)
                        .task(id: taskID) {
                            guard taskID.isActive,
                                  taskID.value == store.nextPageLoadID
                            else { return }
                            await store.loadMore()
                        }
                } else if visibleItems.isEmpty, !store.isLoading {
                    Label("暂无推荐", systemImage: "sparkles")
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
            .nativeHomeFeedListLayout()
            .coordinateSpace(name: "home-root-scroll")
            .nativeHomeFeedScrollTracking(
                collapseProgress: $collapseProgress,
                isActive: isActiveChannel
            )
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .nativeShortPullRefresh(isEnabled: isActiveChannel) {
                guard isActiveChannel else { return }
                let outcome = await store.refresh(intent: .pull)
                if outcome == .ignored {
                    hapticFeedback(.refreshIgnored)
                }
            }
            .onAppear {
                // A request token records an action that already happened. Returning
                // from a pushed answer must not replay it and destroy List's retained
                // scroll position. New requests are handled by onChange below.
                observedScrollToTopRequest = scrollToTopRequest
            }
            .onChange(of: scrollToTopRequest) { newRequest in
                let shouldScroll = NativeScrollToTopRequestPolicy.shouldHandleChange(
                    previousRequest: observedScrollToTopRequest,
                    newRequest: newRequest
                )
                observedScrollToTopRequest = newRequest
                if shouldScroll {
                    scrollToTop(proxy, animated: true)
                }
            }
            .onChange(of: store.refreshFeedbackSequence) { _ in
                guard isActiveChannel else { return }
                hapticFeedback(.refreshSucceeded)
            }
            .task(id: isActiveChannel) {
                guard isActiveChannel else { return }
                await store.loadInitialIfNeeded()
            }
        }
        .accessibilityIdentifier("home_native")
    }

    private var visibleItems: [FeedItemDTO] {
        FeedQuestionAuthorVisibilityPolicy.visibleItems(
            from: store.items,
            blockedMemberIDs: questionAuthorBlocklist.blockedMemberIDs
        )
    }

    private func scrollToTop(_ proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            if animated {
                withAnimation {
                    proxy.scrollTo(
                        NativeHomeHeaderLayoutPolicy.scrollAnchor(for: .recommendation),
                        anchor: .top
                    )
                }
            } else {
                proxy.scrollTo(
                    NativeHomeHeaderLayoutPolicy.scrollAnchor(for: .recommendation),
                    anchor: .top
                )
            }
        }
    }
}

struct FollowNativeView: View {
    @ObservedObject private var store: FollowNativeStore
    @EnvironmentObject private var questionAuthorBlocklist: QuestionAuthorBlocklistStore
    @Environment(\.nativeChannelIsActive) private var isActiveChannel
    @Environment(\.nativeHapticFeedback) private var hapticFeedback
    @Binding private var collapseProgress: CGFloat
    let scrollToTopRequest: UInt
    let onOpen: (FeedItemRoute) -> Void
    let onOpenPerson: (PersonRoutePayload) -> Void

    init(
        store: FollowNativeStore,
        collapseProgress: Binding<CGFloat> = .constant(0),
        scrollToTopRequest: UInt,
        onOpen: @escaping (FeedItemRoute) -> Void,
        onOpenPerson: @escaping (PersonRoutePayload) -> Void
    ) {
        _store = ObservedObject(wrappedValue: store)
        _collapseProgress = collapseProgress
        self.scrollToTopRequest = scrollToTopRequest
        self.onOpen = onOpen
        self.onOpenPerson = onOpenPerson
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                NativeRootLargeTitle(
                    "首页",
                    coordinateSpaceName: followCoordinateSpaceName,
                    displaysTitle: false,
                    isActive: isActiveChannel,
                    isRefreshing: store.isMomentsRefreshing,
                    collapseProgress: $collapseProgress
                )
                    .id(NativeHomeHeaderLayoutPolicy.scrollAnchor(for: .following))

                recentUsers

                if store.moments.items.isEmpty, store.moments.isLoading {
                    HStack { Spacer(); ProgressView("正在加载关注内容"); Spacer() }
                        .listRowSeparator(.hidden)
                }

                ForEach(visibleItems) { item in
                    FeedItemRow(
                        item: item,
                        showsThumbnail: true,
                        titleDisplayMode: .full,
                        onOpen: onOpen
                    )
                        .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
                        .listRowBackground(NativeZhihuVisualStyle.backgroundColor)
                        .listRowSeparatorTint(NativeZhihuVisualStyle.separatorColor)
                }

                if let message = store.moments.errorMessage {
                    FeedRetryRow(message: message) {
                        Task { await store.retry(section: .moments) }
                    }
                } else if store.moments.hasNextPage {
                    let taskID = NativeChannelTaskIdentity(
                        isActive: isActiveChannel,
                        value: store.moments.nextPageLoadID
                    )
                    NativeFeedPaginationLoadingRow(title: "正在加载更多关注内容")
                        .listRowSeparator(.hidden)
                        .task(id: taskID) {
                            guard taskID.isActive,
                                  taskID.value == store.moments.nextPageLoadID
                            else { return }
                            await store.loadMore(section: .moments)
                        }
                } else if visibleItems.isEmpty, !store.moments.isLoading {
                    Label("暂无关注内容", systemImage: "person.2")
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
            .nativeHomeFeedListLayout()
            .coordinateSpace(name: followCoordinateSpaceName)
            .nativeHomeFeedScrollTracking(
                collapseProgress: $collapseProgress,
                isActive: isActiveChannel
            )
            .refreshable {
                guard isActiveChannel else { return }
                let previousSuccessfulRefresh = store.refreshMetadata.lastSuccessfulRefreshAt
                await store.refresh(section: .moments)
                if !Task.isCancelled,
                   NativeRefreshHapticPolicy.shouldEmit(
                    previousSuccessfulRefreshAt: previousSuccessfulRefresh,
                    currentSuccessfulRefreshAt: store.refreshMetadata.lastSuccessfulRefreshAt
                   ) {
                    hapticFeedback(.refreshSucceeded)
                }
            }
            .onAppear {
                if scrollToTopRequest > 0 { scrollToTop(proxy, animated: false) }
            }
            .onChange(of: scrollToTopRequest) { _ in scrollToTop(proxy, animated: true) }
        }
        .navigationTitle("")
        .task(id: NativeChannelTaskIdentity(
            isActive: isActiveChannel,
            value: FollowSection.moments.rawValue
        )) {
            guard isActiveChannel else { return }
            await store.loadMomentsIfNeeded()
        }
        .accessibilityIdentifier("follow_native")
    }

    private var visibleItems: [FeedItemDTO] {
        FeedQuestionAuthorVisibilityPolicy.visibleItems(
            from: store.moments.items,
            blockedMemberIDs: questionAuthorBlocklist.blockedMemberIDs
        )
    }

    private let followCoordinateSpaceName = "follow-moments-root-scroll"

    @ViewBuilder
    private var recentUsers: some View {
        if !store.recentUsers.isEmpty {
            Section("最近动态") {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 16) {
                        ForEach(store.recentUsers) { user in
                            Button {
                                if let route = user.personRoute { onOpenPerson(route) }
                            } label: {
                                VStack(spacing: 6) {
                                    AsyncImage(url: user.avatarURL) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: {
                                        Color.secondary.opacity(0.15)
                                    }
                                    .frame(width: 52, height: 52)
                                    .clipShape(Circle())
                                    .overlay(alignment: .topTrailing) {
                                        if user.unreadCount > 0 {
                                            Circle().fill(.red).frame(width: 10, height: 10)
                                                .overlay(Circle().stroke(.background, lineWidth: 2))
                                        }
                                    }
                                    Text(user.displayName)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .frame(width: 64)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(user.unreadCount > 0
                                ? "\(user.displayName)，有新动态"
                                : user.displayName)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .nativeChannelSwipeExclusion()
            }
        } else if let error = store.recentUsersErrorMessage {
            Section("最近动态") {
                FeedRetryRow(message: error) { Task { await store.reloadRecentUsers() } }
            }
        }
    }

    private func scrollToTop(_ proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            if animated {
                withAnimation {
                    proxy.scrollTo(
                        NativeHomeHeaderLayoutPolicy.scrollAnchor(for: .following),
                        anchor: .top
                    )
                }
            } else {
                proxy.scrollTo(
                    NativeHomeHeaderLayoutPolicy.scrollAnchor(for: .following),
                    anchor: .top
                )
            }
        }
    }
}

private struct NativeFeedPaginationLoadingRow: View {
    let title: String

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            ProgressView(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 56)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("feed_pagination_loading")
    }
}
