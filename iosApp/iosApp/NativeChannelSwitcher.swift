import SwiftUI
import UIKit

/// A top channel selector whose stable channel views move as one horizontal page strip.
struct NativeChannelSwitcher<Channel: Identifiable & Hashable, ChannelContent: View>: View {
    let channels: [Channel]
    @Binding var selection: Channel.ID
    let isEnabled: Bool

    private let title: (Channel) -> String
    private let status: (Channel) -> String?
    private let onPrefetch: (Channel) -> Void
    private let content: (Channel) -> ChannelContent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nativeHapticFeedback) private var hapticFeedback
    @Namespace private var swipeCoordinateSpace
    @State private var dragTranslation: CGFloat = 0
    @State private var swipeExclusionFrames: [CGRect] = []
    @State private var didPrefetchDuringCurrentSwipe = false

    init(
        channels: [Channel],
        selection: Binding<Channel.ID>,
        isEnabled: Bool = true,
        title: @escaping (Channel) -> String,
        status: @escaping (Channel) -> String? = { _ in nil },
        onPrefetch: @escaping (Channel) -> Void = { _ in },
        @ViewBuilder content: @escaping (Channel) -> ChannelContent
    ) {
        self.channels = channels
        _selection = selection
        self.isEnabled = isEnabled
        self.title = title
        self.status = status
        self.onPrefetch = onPrefetch
        self.content = content
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                channelContent(containerWidth: geometry.size.width)
                    .contentShape(Rectangle())
                    .background {
                        NativeHorizontalChannelSwipeObserver(
                            containerWidth: geometry.size.width,
                            excludedFrames: swipeExclusionFrames,
                            onChanged: updateChannelSwipe,
                            onCancelled: cancelChannelSwipe,
                            onEnded: commitChannelSwipe
                        )
                    }

                fixedHeader
                    .zIndex(2)
            }
            .coordinateSpace(name: swipeCoordinateSpace)
            .environment(
                \.nativeChannelSwipeCoordinateSpace,
                AnyHashable(swipeCoordinateSpace)
            )
            .onPreferenceChange(NativeChannelSwipeExclusionPreferenceKey.self) {
                swipeExclusionFrames = $0
            }
        }
        .onChange(of: reduceMotion) { shouldReduceMotion in
            if shouldReduceMotion { dragTranslation = 0 }
        }
        .onChange(of: selection) { _ in
            didPrefetchDuringCurrentSwipe = false
        }
        .onChange(of: isEnabled) { enabled in
            if !enabled { resetChannelSwipe() }
        }
        .onDisappear { resetChannelSwipe() }
    }

    private var fixedHeader: some View {
        NativeChannelSelector(
            channels: channels,
            selection: $selection,
            title: title,
            status: status
        )
        .background(NativeZhihuVisualStyle.backgroundColor)
        .frame(
            height: NativeHomeHeaderLayoutPolicy.expandedHeaderHeight,
            alignment: .top
        )
        .clipped()
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(NativeZhihuVisualStyle.separatorColor)
                .frame(height: 0.5)
        }
        .allowsHitTesting(isEnabled)
        .environment(\.nativeChannelIsActive, isEnabled)
        .accessibilityHidden(!isEnabled)
    }

    private func channelContent(containerWidth: CGFloat) -> some View {
        ZStack {
            ForEach(Array(channels.enumerated()), id: \.element.id) { index, channel in
                let isActive = NativeChannelPresentationPolicy.isActive(
                    isEnabled: isEnabled,
                    channelID: channel.id,
                    selection: selection
                )
                content(channel)
                    .frame(width: containerWidth)
                    .offset(x: NativeChannelPageTransitionPolicy.pageOffset(
                        pageIndex: index,
                        selectedIndex: selectedChannelIndex,
                        containerWidth: containerWidth,
                        dragTranslation: dragTranslation
                    ))
                    .zIndex(isActive ? 1 : 0)
                    .scrollDisabled(!isActive)
                    .allowsHitTesting(isActive && dragTranslation == 0)
                    .accessibilityHidden(!isActive)
                    .environment(\.nativeChannelIsActive, isActive)
            }
        }
        .clipped()
    }

    private var selectedChannelIndex: Int {
        channels.firstIndex(where: { $0.id == selection }) ?? 0
    }

    private func updateChannelSwipe(_ translation: CGSize, _ containerWidth: CGFloat) {
        guard isEnabled else { return }
        dragTranslation = NativeChannelPageTransitionPolicy.interactiveTranslation(
            rawTranslation: translation.width,
            currentIndex: selectedChannelIndex,
            channelCount: channels.count,
            containerWidth: containerWidth
        )
        prefetchAdjacentChannelIfNeeded()
    }

    private func cancelChannelSwipe() {
        if reduceMotion {
            dragTranslation = 0
        } else {
            withAnimation(NativeChannelSwitcherTuning.pageAnimation) {
                dragTranslation = 0
            }
        }
        didPrefetchDuringCurrentSwipe = false
    }

    private func commitChannelSwipe(
        _ translation: CGSize,
        _ predictedEndTranslation: CGSize,
        _ containerWidth: CGFloat
    ) {
        guard let currentIndex = channels.firstIndex(where: { $0.id == selection }) else {
            return
        }

        let targetIndex = NativeChannelSwipePolicy.targetIndex(
            currentIndex: currentIndex,
            channelCount: channels.count,
            translation: translation,
            predictedEndTranslation: predictedEndTranslation,
            containerWidth: containerWidth
        )
        let targetSelection = channels[targetIndex].id
        if reduceMotion {
            dragTranslation = 0
            if targetIndex != currentIndex { selection = targetSelection }
        } else {
            withAnimation(NativeChannelSwitcherTuning.pageAnimation) {
                dragTranslation = 0
                if targetIndex != currentIndex { selection = targetSelection }
            }
        }
        if targetIndex != currentIndex { hapticFeedback(.commit) }
        didPrefetchDuringCurrentSwipe = false
    }

    private func prefetchAdjacentChannelIfNeeded() {
        guard !didPrefetchDuringCurrentSwipe,
              let targetIndex = NativeChannelPrefetchPolicy.targetIndex(
                currentIndex: selectedChannelIndex,
                channelCount: channels.count,
                translation: dragTranslation
              )
        else { return }
        didPrefetchDuringCurrentSwipe = true
        onPrefetch(channels[targetIndex])
    }

    private func resetChannelSwipe() {
        dragTranslation = 0
        didPrefetchDuringCurrentSwipe = false
    }
}

struct NativeChannelPresentationPolicy {
    static func isActive<ID: Equatable>(
        isEnabled: Bool,
        channelID: ID,
        selection: ID
    ) -> Bool {
        isEnabled && channelID == selection
    }
}

struct NativeChannelPageTransitionPolicy {
    static func pageOffset(
        pageIndex: Int,
        selectedIndex: Int,
        containerWidth: CGFloat,
        dragTranslation: CGFloat
    ) -> CGFloat {
        CGFloat(pageIndex - selectedIndex) * containerWidth + dragTranslation
    }

    static func interactiveTranslation(
        rawTranslation: CGFloat,
        currentIndex: Int,
        channelCount: Int,
        containerWidth: CGFloat
    ) -> CGFloat {
        guard channelCount > 0,
              currentIndex >= 0,
              currentIndex < channelCount,
              containerWidth > 0
        else { return 0 }
        if currentIndex == 0, rawTranslation > 0 { return 0 }
        if currentIndex == channelCount - 1, rawTranslation < 0 { return 0 }
        return min(max(rawTranslation, -containerWidth), containerWidth)
    }
}

struct NativeChannelPrefetchPolicy {
    static let minimumTranslation: CGFloat = 12

    static func targetIndex(
        currentIndex: Int,
        channelCount: Int,
        translation: CGFloat
    ) -> Int? {
        guard channelCount > 0,
              currentIndex >= 0,
              currentIndex < channelCount,
              abs(translation) >= minimumTranslation,
              translation != 0
        else { return nil }

        let targetIndex = translation > 0 ? currentIndex - 1 : currentIndex + 1
        return (0..<channelCount).contains(targetIndex) ? targetIndex : nil
    }
}

/// Installs a direction-locking pan recognizer on the surrounding SwiftUI host view.
///
/// A SwiftUI `DragGesture` enters recognition before its `onEnded` direction check, which
/// prevents the nested `List` from owning a vertical pull-to-refresh. This recognizer fails
/// before beginning unless the initial velocity is predominantly horizontal, leaving vertical
/// pans entirely to the native scroll view.
private struct NativeHorizontalChannelSwipeObserver: UIViewRepresentable {
    let containerWidth: CGFloat
    let excludedFrames: [CGRect]
    let onChanged: (CGSize, CGFloat) -> Void
    let onCancelled: () -> Void
    let onEnded: (CGSize, CGSize, CGFloat) -> Void

    func makeUIView(context: Context) -> NativeHorizontalChannelSwipeInstallerView {
        let view = NativeHorizontalChannelSwipeInstallerView()
        view.isUserInteractionEnabled = false
        update(view)
        return view
    }

    func updateUIView(
        _ uiView: NativeHorizontalChannelSwipeInstallerView,
        context: Context
    ) {
        update(uiView)
    }

    static func dismantleUIView(
        _ uiView: NativeHorizontalChannelSwipeInstallerView,
        coordinator: ()
    ) {
        uiView.uninstall()
    }

    private func update(_ view: NativeHorizontalChannelSwipeInstallerView) {
        view.containerWidth = containerWidth
        view.excludedFrames = excludedFrames
        view.onChanged = onChanged
        view.onCancelled = onCancelled
        view.onEnded = onEnded
        view.scheduleInstallation()
    }
}

private final class NativeHorizontalChannelSwipeInstallerView: UIView,
    UIGestureRecognizerDelegate {
    var containerWidth: CGFloat = 0
    var excludedFrames: [CGRect] = []
    var onChanged: ((CGSize, CGFloat) -> Void)?
    var onCancelled: (() -> Void)?
    var onEnded: ((CGSize, CGSize, CGFloat) -> Void)?

    private weak var gestureHostView: UIView?
    private lazy var panGestureRecognizer: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        recognizer.delegate = self
        // A committed horizontal pan must cancel the underlying row button; otherwise the
        // release can both switch channel and open the feed item below the finger.
        recognizer.cancelsTouchesInView = true
        recognizer.minimumNumberOfTouches = 1
        recognizer.maximumNumberOfTouches = 1
        return recognizer
    }()

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        scheduleInstallation()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        scheduleInstallation()
    }

    func scheduleInstallation() {
        DispatchQueue.main.async { [weak self] in
            self?.installIfNeeded()
        }
    }

    func uninstall() {
        gestureHostView?.removeGestureRecognizer(panGestureRecognizer)
        gestureHostView = nil
    }

    private func installIfNeeded() {
        guard window != nil, let hostView = gestureHostCandidate() else {
            uninstall()
            return
        }
        guard gestureHostView !== hostView else { return }
        uninstall()
        hostView.addGestureRecognizer(panGestureRecognizer)
        gestureHostView = hostView
    }

    private func gestureHostCandidate() -> UIView? {
        var candidate = superview
        while let parent = candidate?.superview, !(parent is UIWindow) {
            candidate = parent
        }
        return candidate
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
              let hostView = gestureHostView
        else { return false }

        let velocity = pan.velocity(in: hostView)
        guard NativeChannelSwipePolicy.shouldBegin(velocity: velocity) else { return false }

        let startLocation = convert(pan.location(in: hostView), from: hostView)
        let isInside = bounds.contains(startLocation)
        guard isInside else { return false }
        let isMarkedForExclusion = excludedFrames.contains(where: { $0.contains(startLocation) })
        let nestedMetrics = horizontalScrollMetrics(
            at: pan.location(in: hostView),
            in: hostView
        )
        return !NativeChannelSwipeExclusionPolicy.shouldExcludeParentSwipe(
            isMarkedForExclusion: isMarkedForExclusion,
            nestedContentWidth: nestedMetrics?.contentWidth,
            nestedViewportWidth: nestedMetrics?.viewportWidth
        )
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let hostView = gestureHostView else { return }
        let translation = recognizer.translation(in: hostView)
        if recognizer.state == .changed {
            onChanged?(CGSize(width: translation.x, height: translation.y), containerWidth)
            return
        }
        guard recognizer.state == .ended else {
            if recognizer.state == .cancelled || recognizer.state == .failed {
                onCancelled?()
            }
            return
        }
        let velocity = recognizer.velocity(in: hostView)
        let predictionInterval = NativeChannelSwitcherTuning.velocityPredictionInterval
        let predictedEndTranslation = CGSize(
            width: translation.x + velocity.x * predictionInterval,
            height: translation.y + velocity.y * predictionInterval
        )
        onEnded?(
            CGSize(width: translation.x, height: translation.y),
            predictedEndTranslation,
            containerWidth
        )
    }

    private func horizontalScrollMetrics(
        at location: CGPoint,
        in hostView: UIView
    ) -> (contentWidth: CGFloat, viewportWidth: CGFloat)? {
        var candidate = hostView.hitTest(location, with: nil)
        while let view = candidate, view !== hostView {
            if let scrollView = view as? UIScrollView,
               scrollView.isScrollEnabled,
               scrollView.contentSize.width > 0,
               scrollView.bounds.width > 0 {
                return (
                    scrollView.contentSize.width
                        + scrollView.adjustedContentInset.left
                        + scrollView.adjustedContentInset.right,
                    scrollView.bounds.width
                )
            }
            candidate = view.superview
        }
        return nil
    }
}

struct NativeChannelSwipeExclusionPolicy {
    static func shouldExcludeParentSwipe(
        isMarkedForExclusion: Bool,
        nestedContentWidth: CGFloat?,
        nestedViewportWidth: CGFloat?
    ) -> Bool {
        guard isMarkedForExclusion else { return false }
        guard let nestedContentWidth, let nestedViewportWidth else { return true }
        return nestedContentWidth > nestedViewportWidth
    }
}

enum NativeChannelSelectorScrollAlignment: Equatable {
    case leading
    case center
    case trailing

    var anchor: UnitPoint {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    static func alignment<ID: Equatable>(
        for selection: ID,
        in channelIDs: [ID]
    ) -> Self {
        guard let selectedIndex = channelIDs.firstIndex(of: selection) else {
            return .center
        }
        if selectedIndex == channelIDs.startIndex {
            return .leading
        }
        if selectedIndex == channelIDs.index(before: channelIDs.endIndex) {
            return .trailing
        }
        return .center
    }
}

private struct NativeChannelSelector<Channel: Identifiable & Hashable>: View {
    let channels: [Channel]
    @Binding var selection: Channel.ID
    let title: (Channel) -> String
    let status: (Channel) -> String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nativeHapticFeedback) private var hapticFeedback

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                channelButtons
            }
            .nativeChannelSwipeExclusion()
            .onAppear {
                scrollToSelection(using: proxy, animated: false)
            }
            .onChange(of: selection) { _ in
                scrollToSelection(using: proxy, animated: !reduceMotion)
            }
        }
        .frame(height: NativeHomeHeaderLayoutPolicy.channelSelectorHeight)
        .clipped()
        .accessibilityIdentifier("home_channel_selector")
    }

    private var channelIDs: [Channel.ID] {
        channels.map(\.id)
    }

    private var channelButtons: some View {
        HStack(spacing: 4) {
            ForEach(Array(channels.enumerated()), id: \.element.id) { index, channel in
                let isSelected = channel.id == selection
                Button {
                    guard !isSelected else { return }
                    if reduceMotion {
                        selection = channel.id
                    } else {
                        withAnimation(NativeChannelSwitcherTuning.selectorAnimation) {
                            selection = channel.id
                        }
                    }
                    hapticFeedback(.selection)
                } label: {
                    VStack(spacing: 4) {
                        Text(title(channel))
                            .font(.system(
                                size: 17,
                                weight: isSelected ? .semibold : .regular
                            ))
                            .foregroundStyle(
                                isSelected ? Color.primary : Color.primary.opacity(0.88)
                            )
                            .fixedSize()

                        Capsule()
                            .fill(isSelected ? Color.primary : Color.clear)
                            .frame(width: 26, height: 4)
                    }
                    .frame(minWidth: 54, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(
                    .leading,
                    index == channels.startIndex
                        ? NativeHomeHeaderLayoutPolicy.horizontalContentInset
                        : 0
                )
                .padding(
                    .trailing,
                    index == channels.index(before: channels.endIndex)
                        ? NativeHomeHeaderLayoutPolicy.horizontalContentInset
                        : 0
                )
                .id(channel.id)
                .accessibilityLabel(title(channel))
                .accessibilityValue(accessibilityValue(for: channel, isSelected: isSelected))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("home_channel_\(String(describing: channel.id))")
            }
        }
    }

    private func accessibilityValue(for channel: Channel, isSelected: Bool) -> String {
        guard isSelected else { return "" }
        var values = ["已选择"]
        if let currentStatus = status(channel) {
            values.append(currentStatus)
        }
        return values.joined(separator: "，")
    }

    private func scrollToSelection(using proxy: ScrollViewProxy, animated: Bool) {
        let anchor = NativeChannelSelectorScrollAlignment.alignment(
            for: selection,
            in: channelIDs
        ).anchor
        DispatchQueue.main.async {
            if animated {
                withAnimation(NativeChannelSwitcherTuning.selectorAnimation) {
                    proxy.scrollTo(selection, anchor: anchor)
                }
            } else {
                proxy.scrollTo(selection, anchor: anchor)
            }
        }
    }
}

/// Marks a nested horizontal interaction where a drag must not switch the parent channel.
/// Apply this to horizontal carousels, media pagers, and other same-axis controls.
extension View {
    func nativeChannelSwipeExclusion() -> some View {
        modifier(NativeChannelSwipeExclusionModifier())
    }
}

private struct NativeChannelSwipeExclusionModifier: ViewModifier {
    @Environment(\.nativeChannelSwipeCoordinateSpace) private var coordinateSpace
    @Environment(\.nativeChannelIsActive) private var isActiveChannel

    func body(content: Content) -> some View {
        content.background {
            if isActiveChannel, let coordinateSpace {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: NativeChannelSwipeExclusionPreferenceKey.self,
                        value: [geometry.frame(in: .named(coordinateSpace))]
                    )
                }
            }
        }
    }
}

private struct NativeChannelSwipeCoordinateSpaceKey: EnvironmentKey {
    static let defaultValue: AnyHashable? = nil
}

private struct NativeChannelIsActiveKey: EnvironmentKey {
    static let defaultValue = true
}

private extension EnvironmentValues {
    var nativeChannelSwipeCoordinateSpace: AnyHashable? {
        get { self[NativeChannelSwipeCoordinateSpaceKey.self] }
        set { self[NativeChannelSwipeCoordinateSpaceKey.self] = newValue }
    }
}

extension EnvironmentValues {
    var nativeChannelIsActive: Bool {
        get { self[NativeChannelIsActiveKey.self] }
        set { self[NativeChannelIsActiveKey.self] = newValue }
    }
}

private struct NativeChannelSwipeExclusionPreferenceKey: PreferenceKey {
    static let defaultValue: [CGRect] = []

    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

struct NativeChannelSwipePolicy {
    static func shouldBegin(velocity: CGPoint) -> Bool {
        abs(velocity.x) > abs(velocity.y) * NativeChannelSwitcherTuning.horizontalIntentRatio
    }

    static func targetIndex(
        currentIndex: Int,
        channelCount: Int,
        translation: CGSize,
        predictedEndTranslation: CGSize,
        containerWidth: CGFloat
    ) -> Int {
        guard channelCount > 0,
              currentIndex >= 0,
              currentIndex < channelCount,
              containerWidth > 0,
              abs(translation.width) > abs(translation.height) * NativeChannelSwitcherTuning.horizontalIntentRatio
        else { return currentIndex }

        let distanceThreshold = containerWidth * NativeChannelSwitcherTuning.distanceThresholdRatio
        let projectedDistanceThreshold = distanceThreshold * NativeChannelSwitcherTuning.projectedDistanceMultiplier

        if (translation.width <= -distanceThreshold ||
            predictedEndTranslation.width <= -projectedDistanceThreshold),
           currentIndex < channelCount - 1 {
            return currentIndex + 1
        }
        if (translation.width >= distanceThreshold ||
            predictedEndTranslation.width >= projectedDistanceThreshold),
           currentIndex > 0 {
            return currentIndex - 1
        }
        return currentIndex
    }
}

private enum NativeChannelSwitcherTuning {
    // Gesture recognition and commit thresholds reuse the media gallery's existing policy.
    static let horizontalIntentRatio: CGFloat = 1.15
    static let distanceThresholdRatio: CGFloat = 0.18
    static let projectedDistanceMultiplier: CGFloat = 1.35
    static let velocityPredictionInterval: CGFloat = 0.2

    static let selectorAnimation = Animation.easeInOut(duration: 0.22)
    static let pageAnimation = Animation.interactiveSpring(
        response: 0.32,
        dampingFraction: 0.86,
        blendDuration: 0.08
    )
}
