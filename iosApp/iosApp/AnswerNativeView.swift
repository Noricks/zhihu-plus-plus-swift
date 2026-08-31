import SwiftUI
import UIKit

struct AnswerNativeView: View {
    @ObservedObject var store: AnswerStore
    let pinAnswerDate: Bool
    let onNavigate: (QANavigationIntent) -> Void

    @State private var showsCollections = false

    var body: some View {
        Group {
            if let content = store.content {
                loaded(content)
            } else {
                switch store.loadState {
                case let .failed(message):
                    QAErrorState(message: message, actionTitle: "重试") {
                        Task { await store.retry() }
                    }
                case .idle, .loading, .loaded:
                    ProgressView("正在加载正文")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle(store.initialRoute.kind == .answer ? "回答" : "文章")
        .navigationBarTitleDisplayMode(.inline)
        // Page visibility is owned by AnswerPagerStore. Hosting an adjacent page may
        // start its view task before the user actually swipes to it, so preload the
        // body here without reporting a false read-history event.
        .task { await store.preloadIfNeeded() }
        .sheet(isPresented: $showsCollections) {
            QACollectionsSheet(store: store)
        }
        .alert(item: messageBinding) { message in
            Alert(
                title: Text("操作结果"),
                message: Text(message.text),
                dismissButton: .default(Text("知道了")) { store.dismissMessage() }
            )
        }
    }

    private func loaded(_ content: AnswerDTO) -> some View {
        let metadata = QAMetadataPlacement(pinAnswerDate: pinAnswerDate)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if content.route.kind == .answer {
                    Button {
                        if let questionID = content.questionID {
                            onNavigate(.question(QuestionRouteDTO(questionID: questionID, provisionalTitle: content.title)))
                        }
                    } label: {
                        Text(content.title)
                            .font(.title3.bold())
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(content.questionID == nil)
                } else {
                    Text(content.title)
                        .font(.title2.bold())
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                QAAuthorRow(author: content.author) {
                    if let intent = content.author.personIntent { onNavigate(intent) }
                }

                if !content.endorsements.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(content.endorsements) { endorsement in
                                if let url = endorsement.actionURL {
                                    Button {
                                        onNavigate(.endorsement(url))
                                    } label: {
                                        QAEndorsementLabel(endorsement: endorsement, isActionable: true)
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    QAEndorsementLabel(endorsement: endorsement, isActionable: false)
                                }
                            }
                        }
                    }
                }

                if metadata.dateEdge == .leading {
                    QADateMetadata(content: content)
                }

                if let invitation = content.invitationPreface, !invitation.isEmpty {
                    Label(invitation, systemImage: "person.crop.circle.badge.questionmark")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                QABodyView(
                    blocks: content.blocks,
                    segmentSubject: content.route.kind == .answer
                        ? .answer(content.route.contentID)
                        : .article(content.route.contentID),
                    onNavigate: onNavigate
                )

                if let attachment = content.attachment {
                    QABodyView(
                        blocks: [.video(UUID(), attachment)],
                        segmentSubject: content.route.kind == .answer
                            ? .answer(content.route.contentID)
                            : .article(content.route.contentID),
                        onNavigate: onNavigate
                    )
                }

                VStack(alignment: .trailing, spacing: 5) {
                    if metadata.dateEdge == .trailing { QADateMetadata(content: content) }
                    if let ip = content.ipLocation, !ip.isEmpty {
                        Text("IP属地：\(ip)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 8)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AnswerActionBar(
                content: content,
                voteInFlight: store.isVoteMutationInFlight,
                onAuthor: {
                    if let intent = content.author.personIntent { onNavigate(intent) }
                },
                onVoteUp: {
                    let target: QAVoteState = content.voteState == .up ? .neutral : .up
                    Task { await store.setVote(target) }
                },
                onVoteDown: {
                    let target: QAVoteState = content.voteState == .down ? .neutral : .down
                    Task { await store.setVote(target) }
                },
                onFavorite: {
                    showsCollections = true
                    Task { await store.loadCollections() }
                },
                onComments: {
                    let subject: CommentSubjectDTO = content.route.kind == .answer
                        ? .answer(content.route.contentID)
                        : .article(content.route.contentID)
                    onNavigate(.comments(CommentThreadRouteDTO(
                        subject: subject,
                        shareContext: CommentShareContextDTO(
                            title: content.title,
                            excerpt: commentShareExcerpt(from: content.blocks),
                            sourceURL: content.sourceURL
                        )
                    )))
                }
            )
        }
    }

    private func commentShareExcerpt(from blocks: [QABodyBlock]) -> String? {
        let text = blocks
            .compactMap(commentShareText)
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !text.isEmpty else { return nil }
        let limit = text.index(text.startIndex, offsetBy: min(160, text.count))
        return String(text[..<limit])
    }

    private func commentShareText(_ block: QABodyBlock) -> String? {
        switch block {
        case let .paragraph(_, runs),
             let .heading(_, _, runs),
             let .quote(_, runs),
             let .segment(_, _, runs):
            return runs.map(\.text).joined()
        case let .list(_, _, items):
            return items.flatMap { item in
                [item.runs.map(\.text).joined()] + item.nestedLists.flatMap(commentShareListText)
            }.joined(separator: " ")
        case let .code(_, _, text), let .formula(_, text):
            return text
        case .image, .video, .divider:
            return nil
        }
    }

    private func commentShareListText(_ list: QAListGroup) -> [String] {
        list.items.flatMap { item in
            [item.runs.map(\.text).joined()] + item.nestedLists.flatMap(commentShareListText)
        }
    }

    private var messageBinding: Binding<QAUserMessage?> {
        Binding(get: { store.message }, set: { _ in store.dismissMessage() })
    }
}

private struct QAAuthorRow: View {
    let author: QAAuthorDTO
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                AsyncImage(url: author.avatarURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.tertiary)
                }
                .frame(width: 42, height: 42)
                .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(author.displayName).font(.headline)
                    if !author.headline.isEmpty {
                        Text(author.headline).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(author.personIntent == nil)
        .accessibilityHint(author.personIntent == nil ? "" : "打开作者主页")
    }
}

private struct QAEndorsementLabel: View {
    let endorsement: QAEndorsementDTO
    let isActionable: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark.seal")
            Text(endorsement.text)
            if isActionable { Image(systemName: "chevron.right").font(.caption2) }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(isActionable ? Color.accentColor : Color(uiColor: .secondaryLabel))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary, in: Capsule())
    }
}

private struct QADateMetadata: View {
    let content: AnswerDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if content.createdTimeSeconds > 0 {
                Text("发布于 \(date(content.createdTimeSeconds))")
            }
            if content.updatedTimeSeconds > 0,
               content.updatedTimeSeconds != content.createdTimeSeconds {
                Text("编辑于 \(date(content.updatedTimeSeconds))")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func date(_ seconds: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(
            .dateTime.year().month().day().hour().minute()
        )
    }
}

private struct AnswerActionBar: View {
    let content: AnswerDTO
    let voteInFlight: Bool
    let onAuthor: () -> Void
    let onVoteUp: () -> Void
    let onVoteDown: () -> Void
    let onFavorite: () -> Void
    let onComments: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            GeometryReader { proxy in
                let metrics = QAEngagementBarLayoutPolicy.metrics(for: proxy.size.width)
                actions(metrics: metrics)
                    .padding(.horizontal, metrics.horizontalPadding)
                    .padding(.vertical, metrics.verticalPadding)
            }
            .frame(height: QAEngagementBarLayoutPolicy.contentHeight)
        }
        .background {
            Rectangle()
                .fill(.bar)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private func actions(metrics: QAEngagementBarLayoutMetrics) -> some View {
        HStack(spacing: 0) {
            authorAction(maxWidth: metrics.authorWidth)
            Spacer(minLength: metrics.sectionSpacing)
            HStack(spacing: metrics.actionSpacing) {
                action(
                    .triangle(.up),
                    label: "赞同",
                    count: content.voteUpCount,
                    selected: content.voteState == .up,
                    metrics: metrics,
                    action: onVoteUp
                )
                .disabled(voteInFlight)
                action(
                    .triangle(.down),
                    label: "反对",
                    selected: content.voteState == .down,
                    metrics: metrics,
                    action: onVoteDown
                )
                .disabled(voteInFlight || content.route.kind == .article)
                action(
                    .system(content.favoriteState == .favorited ? "star.fill" : "star"),
                    label: "收藏",
                    count: content.favoriteCount,
                    selected: content.favoriteState == .favorited,
                    metrics: metrics,
                    action: onFavorite
                )
                action(
                    .system("bubble.left"),
                    label: "评论",
                    count: content.commentCount,
                    selected: false,
                    metrics: metrics,
                    action: onComments
                )
            }
        }
    }

    private func authorAction(maxWidth: CGFloat) -> some View {
        Button(action: onAuthor) {
            HStack(spacing: 7) {
                AsyncImage(url: content.author.avatarURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .foregroundStyle(.tertiary)
                }
                .frame(width: 30, height: 30)
                .clipShape(Circle())

                Text(content.author.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.leading, 3)
            .padding(.trailing, 10)
            .frame(minHeight: 44)
            .background(Color(uiColor: .secondarySystemFill), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(content.author.personIntent == nil)
        .frame(width: maxWidth, alignment: .leading)
        .accessibilityLabel(content.author.displayName)
        .accessibilityHint(content.author.personIntent == nil ? "" : "打开作者主页")
    }

    private func action(
        _ icon: QAEngagementIcon,
        label: String,
        count: Int? = nil,
        selected: Bool,
        metrics: QAEngagementBarLayoutMetrics,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                engagementIcon(icon, selected: selected, metrics: metrics)
                if let count {
                    Text(QAEngagementCountFormatter.string(for: count))
                        .font(.caption2.monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: metrics.badgeMaxWidth)
                        .padding(.horizontal, 2)
                        .background(.bar, in: Capsule())
                        .offset(x: metrics.badgeOffset.width, y: metrics.badgeOffset.height)
                }
            }
            .frame(width: metrics.actionHitArea, height: metrics.actionHitArea)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.accentColor : Color(uiColor: .secondaryLabel))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue(count: count, selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func engagementIcon(
        _ icon: QAEngagementIcon,
        selected: Bool,
        metrics: QAEngagementBarLayoutMetrics
    ) -> some View {
        switch icon {
        case let .triangle(direction):
            QAEquilateralTriangle(direction: direction)
                .stroke(
                    style: StrokeStyle(
                        lineWidth: selected
                            ? metrics.selectedTriangleLineWidth
                            : metrics.triangleLineWidth,
                        lineJoin: .round
                    )
                )
                .frame(width: metrics.triangleSide, height: metrics.triangleHeight)
                .offset(y: metrics.triangleVisualCenterOffset(for: direction))
                .frame(width: metrics.iconCanvas, height: metrics.iconCanvas)
        case let .system(systemName):
            Image(systemName: systemName)
                .font(.system(size: metrics.systemIconSize, weight: selected ? .semibold : .regular))
                .frame(width: metrics.iconCanvas, height: metrics.iconCanvas)
        }
    }

    private func accessibilityValue(count: Int?, selected: Bool) -> String {
        [
            count.map { "\($0)" },
            selected ? "已选择" : nil
        ]
        .compactMap { $0 }
        .joined(separator: "，")
    }
}

private enum QAEngagementIcon {
    case triangle(QATriangleDirection)
    case system(String)
}

enum QATriangleDirection: Equatable {
    case up
    case down
}

struct QAEquilateralTriangle: Shape {
    let direction: QATriangleDirection

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch direction {
        case .up:
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        case .down:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        }
        path.closeSubpath()
        return path
    }
}

struct QAEngagementBarLayoutMetrics: Equatable {
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let sectionSpacing: CGFloat
    let actionSpacing: CGFloat
    let actionHitArea: CGFloat
    let authorWidth: CGFloat
    let iconCanvas: CGFloat
    let systemIconSize: CGFloat
    let triangleSide: CGFloat
    let triangleLineWidth: CGFloat
    let selectedTriangleLineWidth: CGFloat
    let badgeMaxWidth: CGFloat
    let badgeOffset: CGSize

    var triangleHeight: CGFloat { triangleSide * CGFloat(3).squareRoot() / 2 }
    var actionGroupWidth: CGFloat { actionHitArea * 4 + actionSpacing * 3 }
    var fixedContentWidth: CGFloat {
        horizontalPadding * 2 + authorWidth + sectionSpacing + actionGroupWidth
    }

    func triangleVisualCenterOffset(for direction: QATriangleDirection) -> CGFloat {
        let centroidCorrection = triangleHeight / 6
        return direction == .up ? -centroidCorrection : centroidCorrection
    }
}

enum QAEngagementBarLayoutPolicy {
    static let contentHeight: CGFloat = 56

    static func metrics(for containerWidth: CGFloat) -> QAEngagementBarLayoutMetrics {
        let isWide = containerWidth >= 414
        let isRegular = containerWidth >= 375
        return QAEngagementBarLayoutMetrics(
            horizontalPadding: isWide ? 16 : (isRegular ? 12 : 8),
            verticalPadding: 6,
            sectionSpacing: isWide ? 10 : (isRegular ? 8 : 6),
            actionSpacing: isWide ? 8 : (isRegular ? 6 : 2),
            actionHitArea: 44,
            authorWidth: isWide ? 132 : (isRegular ? 112 : 84),
            iconCanvas: 32,
            systemIconSize: 22,
            triangleSide: 25,
            triangleLineWidth: 1.8,
            selectedTriangleLineWidth: 2.4,
            badgeMaxWidth: 38,
            badgeOffset: CGSize(width: 8, height: -12)
        )
    }
}

enum QAEngagementCountFormatter {
    static func string(for count: Int) -> String {
        let value = max(0, count)
        if value >= 100_000_000 { return abbreviated(value, divisor: 100_000_000, suffix: "亿") }
        if value >= 10_000 { return abbreviated(value, divisor: 10_000, suffix: "万") }
        return String(value)
    }

    private static func abbreviated(_ value: Int, divisor: Int, suffix: String) -> String {
        var whole = value / divisor
        var tenths = ((value % divisor) * 10 + divisor / 2) / divisor
        if tenths == 10 {
            whole += 1
            tenths = 0
        }
        return tenths == 0 ? "\(whole) \(suffix)" : "\(whole).\(tenths) \(suffix)"
    }
}

private struct QACollectionsSheet: View {
    @ObservedObject var store: AnswerStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Group {
                if store.collections.isEmpty {
                    switch store.collectionsState {
                    case let .failed(message):
                        QAErrorState(message: message, actionTitle: "重试") {
                            Task { await store.loadCollections(force: true) }
                        }
                    case .idle, .loading, .loaded:
                        ProgressView("正在加载收藏夹")
                    }
                } else {
                    List(store.collections) { collection in
                        Button {
                            Task { await store.setCollection(collection, selected: !collection.isFavorited) }
                        } label: {
                            HStack {
                                Text(collection.title).foregroundStyle(.primary)
                                Spacer()
                                if store.activeCollectionID == collection.id {
                                    ProgressView()
                                } else if collection.isFavorited {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(store.activeCollectionID != nil)
                    }
                    .refreshable { await store.loadCollections(force: true) }
                }
            }
            .navigationTitle("收藏到")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .modifier(QACollectionSheetPresentationModifier())
    }
}

private struct QACollectionSheetPresentationModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.presentationDetents([.medium, .large])
        } else {
            content
        }
    }
}
