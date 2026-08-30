import SwiftUI

enum NativeZhihuVisualStyle {
    static let backgroundColor = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .secondarySystemBackground : .systemBackground
    })
    static let separatorColor = Color(uiColor: .separator).opacity(0.55)
    static let titlePointSize: CGFloat = 18
    static let summaryPointSize: CGFloat = 16
    static let contentSpacing: CGFloat = 8
}

enum FeedItemTitleDisplayMode: Equatable {
    case compact
    case full

    var lineLimit: Int? {
        switch self {
        case .compact: return 2
        case .full: return nil
        }
    }
}

struct FeedItemRow: View {
    let item: FeedItemDTO
    let showsThumbnail: Bool
    let titleDisplayMode: FeedItemTitleDisplayMode
    let onOpen: (FeedItemRoute) -> Void
    @EnvironmentObject private var questionAuthorBlocklist: QuestionAuthorBlocklistStore
    @Environment(\.nativeContentPresentation) private var presentation
    @Environment(\.nativeHapticFeedback) private var hapticFeedback
    @ScaledMetric(relativeTo: .headline) private var titlePointSize = NativeZhihuVisualStyle.titlePointSize
    @ScaledMetric(relativeTo: .body) private var summaryPointSize = NativeZhihuVisualStyle.summaryPointSize
    @ScaledMetric(relativeTo: .body) private var wideThumbnailHeight: CGFloat = 96

    init(
        item: FeedItemDTO,
        showsThumbnail: Bool,
        titleDisplayMode: FeedItemTitleDisplayMode = .compact,
        onOpen: @escaping (FeedItemRoute) -> Void
    ) {
        self.item = item
        self.showsThumbnail = showsThumbnail
        self.titleDisplayMode = titleDisplayMode
        self.onOpen = onOpen
    }

    var body: some View {
        rowButton
            .questionAuthorContextMenu(
                author: item.questionAuthor,
                block: blockQuestionAuthor
            )
            .accessibilityLabel("\(item.title)，\(item.details)")
    }

    private var rowButton: some View {
        Button {
            onOpen(item.route)
        } label: {
            VStack(alignment: .leading, spacing: NativeZhihuVisualStyle.contentSpacing) {
                if let sourceLabel = normalizedSourceLabel {
                    Text(sourceLabel)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(item.title)
                            .font(.system(size: titlePointSize, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineSpacing(3)
                            .lineLimit(titleDisplayMode.lineLimit)
                            .fixedSize(horizontal: false, vertical: true)

                        if let author = item.author {
                            FeedItemAuthorLabel(author: author)
                        }

                        if let summary = item.summary, !summary.isEmpty {
                            let renderedPointSize = summaryPointSize * presentation.fontScale
                            Text(summary)
                                .font(.system(size: renderedPointSize))
                                .foregroundStyle(.secondary)
                                .lineSpacing(
                                    3 + presentation.extraLineSpacing(for: renderedPointSize) * 0.45
                                )
                                .lineLimit(presentation.feedExcerptLines)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if showsThumbnail, presentation.showsFeedThumbnails, item.media.isEmpty,
                       thumbnailPlacement == .trailing,
                       let thumbnailURL = item.thumbnailURL {
                        FeedSingleThumbnail(
                            url: thumbnailURL,
                            cropAnchor: thumbnailPlacement.cropAnchor
                        )
                            .frame(width: 84, height: 60)
                            .clipped()
                    }
                }

                if showsThumbnail,
                   presentation.showsFeedThumbnails,
                   item.media.isEmpty,
                   thumbnailPlacement == .wideInline,
                   let thumbnailURL = item.thumbnailURL {
                    FeedSingleThumbnail(
                        url: thumbnailURL,
                        cropAnchor: thumbnailPlacement.cropAnchor
                    )
                        .frame(maxWidth: .infinity)
                        .frame(height: wideThumbnailHeight)
                        .clipped()
                }

                if showsThumbnail, presentation.showsFeedThumbnails, !item.media.isEmpty {
                    FeedMediaPreview(media: item.media)
                }

                FeedItemEngagementRow(kind: item.kind, details: item.details)
            }
            .contentShape(Rectangle())
            .padding(.vertical, presentation.feedDensity.rowVerticalPadding)
        }
        .buttonStyle(.plain)
    }

    private var normalizedSourceLabel: String? {
        guard let sourceLabel = item.sourceLabel?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !sourceLabel.isEmpty else { return nil }
        return sourceLabel
    }

    private var thumbnailPlacement: FeedThumbnailPlacement {
        FeedThumbnailPresentationPolicy.placement(
            pixelWidth: item.thumbnailPixelWidth,
            pixelHeight: item.thumbnailPixelHeight
        )
    }

    private func blockQuestionAuthor(_ author: FeedAuthorDTO) {
        hapticFeedback(.commit)
        questionAuthorBlocklist.block(author)
    }
}

private struct FeedSingleThumbnail: View {
    let url: URL
    let cropAnchor: FeedThumbnailCropAnchor

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case let .success(image):
                image
                    .resizable()
                    .scaledToFill()
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: cropAnchor.alignment
                    )
            default:
                Color.secondary.opacity(0.12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityHidden(true)
    }
}

private extension FeedThumbnailCropAnchor {
    var alignment: Alignment {
        switch self {
        case .center: return .center
        case .top: return .top
        }
    }
}

struct FeedItemMetadataFormatter {
    struct Metric: Equatable, Identifiable {
        let name: String
        let countText: String
        let systemImage: String

        var id: String { name }
        var displayText: String {
            let separator = countText.hasSuffix("万") || countText.hasSuffix("亿") ? "" : " "
            return "\(countText)\(separator)\(name)"
        }
    }

    static func displayText(kind: FeedItemKind, details: String) -> String {
        metrics(kind: kind, details: details)
            .map(\.displayText)
            .joined(separator: " · ")
    }

    static func metricsText(kind: FeedItemKind, details: String) -> String {
        displayText(kind: kind, details: details)
    }

    static func metrics(kind: FeedItemKind, details: String) -> [Metric] {
        details
            .components(separatedBy: " · ")
            .compactMap(metric)
            .filter { allowedMetricNames(for: kind).contains($0.name) }
            .map { metricPresentation(count: $0.count, name: $0.name) }
    }

    private static func metric(_ rawValue: String) -> (count: Int64, name: String)? {
        let parts = rawValue.split(
            maxSplits: 1,
            whereSeparator: \.isWhitespace
        )
        guard parts.count == 2,
              let count = Int64(parts[0].replacingOccurrences(of: ",", with: ""))
        else { return nil }

        return (max(0, count), String(parts[1]))
    }

    private static func allowedMetricNames(for kind: FeedItemKind) -> Set<String> {
        switch kind {
        case .answer:
            return ["赞同", "评论"]
        case .article, .pin, .video:
            return ["赞", "评论"]
        case .question:
            return ["关注", "回答"]
        }
    }

    private static func metricPresentation(count: Int64, name: String) -> Metric {
        Metric(
            name: name,
            countText: compactNumber(count),
            systemImage: systemImage(for: name)
        )
    }

    private static func systemImage(for name: String) -> String {
        switch name {
        case "赞同", "赞": return "arrowtriangle.up"
        case "关注": return "star"
        case "评论", "回答": return "bubble.left"
        default: return "circle"
        }
    }

    private static func compactNumber(_ count: Int64) -> String {
        switch count {
        case 100_000_000...:
            return compactUnit(count, divisor: 100_000_000, suffix: "亿")
        case 10_000...:
            return compactUnit(count, divisor: 10_000, suffix: "万")
        default:
            return count.formatted(.number.grouping(.automatic))
        }
    }

    private static func compactUnit(
        _ count: Int64,
        divisor: Int64,
        suffix: String
    ) -> String {
        let roundedTenths = ((count * 10) + (divisor / 2)) / divisor
        let whole = roundedTenths / 10
        let fraction = roundedTenths % 10
        return fraction == 0
            ? "\(whole) \(suffix)"
            : "\(whole).\(fraction) \(suffix)"
    }
}

private struct FeedItemEngagementRow: View {
    let kind: FeedItemKind
    let details: String

    private var metrics: [FeedItemMetadataFormatter.Metric] {
        FeedItemMetadataFormatter.metrics(kind: kind, details: details)
    }

    @ViewBuilder
    var body: some View {
        if !metrics.isEmpty {
            HStack(spacing: 26) {
                ForEach(metrics) { metric in
                    HStack(spacing: 7) {
                        Image(systemName: metric.systemImage)
                            .frame(width: 20)
                        Text(metric.countText)
                            .monospacedDigit()
                    }
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.tertiary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(metric.displayText)
                }

                Spacer(minLength: 0)
            }
            .padding(.top, 1)
        }
    }
}

private struct FeedItemAuthorLabel: View {
    let author: FeedAuthorDTO

    var body: some View {
        HStack(spacing: 6) {
            AsyncImage(url: author.avatarURL) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().scaledToFill()
                default:
                    ZStack {
                        Color.secondary.opacity(0.12)
                        Text(String(author.displayName.prefix(1)))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 24, height: 24)
            .clipShape(Circle())

            Text(author.displayName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
        }
    }
}

private extension View {
    @ViewBuilder
    func questionAuthorContextMenu(
        author: FeedAuthorDTO?,
        block: @escaping (FeedAuthorDTO) -> Void
    ) -> some View {
        if let author {
            contextMenu {
                Button(role: .destructive) {
                    block(author)
                } label: {
                    Label("屏蔽该提问者", systemImage: "person.crop.circle.badge.xmark")
                }
            }
            .accessibilityHint("长按可屏蔽该问题的提问者")
        } else {
            self
        }
    }
}

private struct FeedMediaPreview: View {
    let media: [FeedMediaDTO]
    private let spacing: CGFloat = 5
    private let height: CGFloat = 84

    private var visibleMedia: ArraySlice<FeedMediaDTO> {
        FeedMediaPreviewPolicy.visibleMedia(from: media)
    }

    var body: some View {
        GeometryReader { geometry in
            let itemWidth = width(
                availableWidth: geometry.size.width,
                itemCount: visibleMedia.count
            )
            HStack(spacing: spacing) {
                ForEach(visibleMedia) { item in
                    FeedMediaThumbnail(
                        media: item,
                        overflowCount: item.id == visibleMedia.last?.id
                            ? max(0, media.count - visibleMedia.count)
                            : 0
                    )
                    .frame(width: itemWidth, height: height)
                }
            }
            .frame(width: geometry.size.width, height: height, alignment: .leading)
            .clipped()
        }
        .frame(height: height)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("想法包含 \(media.count) 张图片")
    }

    private func width(availableWidth: CGFloat, itemCount: Int) -> CGFloat {
        guard itemCount > 0 else { return 0 }
        let totalSpacing = spacing * CGFloat(itemCount - 1)
        return max(0, (availableWidth - totalSpacing) / CGFloat(itemCount))
    }
}

private struct FeedMediaThumbnail: View {
    let media: FeedMediaDTO
    let overflowCount: Int

    var body: some View {
        AsyncImage(url: media.previewURL) { phase in
            switch phase {
            case let .success(image):
                image.resizable().scaledToFill()
            default:
                Color.secondary.opacity(0.12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .clipped()
        .overlay(alignment: .topLeading) {
            if media.isAnimated {
                Text("GIF")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.62), in: Capsule())
                    .padding(5)
            }
        }
        .overlay {
            if overflowCount > 0 {
                ZStack {
                    Color.black.opacity(0.52)
                    Text("+\(overflowCount)")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct FeedRetryRow: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("重试", action: retry)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
}
