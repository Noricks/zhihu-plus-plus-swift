import SwiftUI

@available(iOS 16.0, *)
struct HotListNativeView: View {
    @ObservedObject private var store: HotFeedStore
    @EnvironmentObject private var questionAuthorBlocklist: QuestionAuthorBlocklistStore
    @Environment(\.nativeChannelIsActive) private var isActiveChannel
    @Environment(\.nativeHapticFeedback) private var hapticFeedback
    @Binding private var collapseProgress: CGFloat
    private let scrollToTopRequest: UInt
    private let onOpen: (FeedItemRoute) -> Void

    init(
        store: HotFeedStore,
        collapseProgress: Binding<CGFloat> = .constant(0),
        scrollToTopRequest: UInt = 0,
        onOpen: @escaping (FeedItemRoute) -> Void
    ) {
        _store = ObservedObject(wrappedValue: store)
        _collapseProgress = collapseProgress
        self.scrollToTopRequest = scrollToTopRequest
        self.onOpen = onOpen
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                NativeRootLargeTitle(
                    "首页",
                    coordinateSpaceName: "hot-root-scroll",
                    displaysTitle: false,
                    isActive: isActiveChannel,
                    isRefreshing: store.isRefreshing,
                    collapseProgress: $collapseProgress
                )
                .id(NativeHomeHeaderLayoutPolicy.scrollAnchor(for: .hot))

                if store.items.isEmpty, store.isLoading {
                    HStack {
                        Spacer()
                        ProgressView("正在加载热榜")
                        Spacer()
                    }
                    .listRowSeparator(.hidden)
                }

                ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(index < 3 ? Color.accentColor : Color.secondary)
                            .frame(minWidth: 26, alignment: .trailing)
                            .padding(.top, 5)
                            .accessibilityHidden(true)
                        FeedItemRow(
                            item: item,
                            showsThumbnail: false,
                            titleDisplayMode: .full,
                            onOpen: onOpen
                        )
                    }
                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 18))
                }

                if let errorMessage = store.errorMessage {
                    FeedRetryRow(message: errorMessage) {
                        Task { await store.retry() }
                    }
                } else if store.canLoadNextPage {
                    let taskID = NativeChannelTaskIdentity(
                        isActive: isActiveChannel,
                        value: store.nextPageLoadID
                    )
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowSeparator(.hidden)
                    .task(id: taskID) {
                        guard taskID.isActive,
                              taskID.value == store.nextPageLoadID
                        else { return }
                        await store.loadNextPage()
                    }
                }
            }
            .listStyle(.plain)
            .nativeHomeFeedListLayout()
            .coordinateSpace(name: "hot-root-scroll")
            .nativeHomeFeedScrollTracking(
                collapseProgress: $collapseProgress,
                isActive: isActiveChannel
            )
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                guard isActiveChannel else { return }
                let previousSuccessfulRefresh = store.refreshMetadata.lastSuccessfulRefreshAt
                await store.refresh()
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
            .task(id: isActiveChannel) {
                guard isActiveChannel else { return }
                await store.loadInitialIfNeeded()
            }
        }
        .accessibilityIdentifier("hot_list")
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
                        NativeHomeHeaderLayoutPolicy.scrollAnchor(for: .hot),
                        anchor: .top
                    )
                }
            } else {
                proxy.scrollTo(
                    NativeHomeHeaderLayoutPolicy.scrollAnchor(for: .hot),
                    anchor: .top
                )
            }
        }
    }
}
