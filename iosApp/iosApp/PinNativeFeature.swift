import Foundation
import SwiftUI

struct PinRouteDTO: Hashable, Sendable {
    let pinID: Int64
}

enum PinContentBlockDTO: Identifiable, Hashable, Sendable {
    case text(id: String, text: String, links: [URL])
    case image(id: String, url: URL, originalURL: URL?)
    case link(id: String, title: String, destination: PinLinkDestination)

    var id: String {
        switch self {
        case let .text(id, _, _), let .image(id, _, _), let .link(id, _, _): return id
        }
    }
}

enum PinLinkDestination: Hashable, Sendable {
    case feed(FeedItemRoute)
    case external(URL)
}

struct PinPollOptionDTO: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let voteCount: Int
    let isSelected: Bool
}

struct PinPollDTO: Hashable, Sendable {
    let id: String
    let title: String
    let voteCount: Int
    let isVoted: Bool
    let isReviewing: Bool
    let endTime: Int64
    let options: [PinPollOptionDTO]

    var acceptsVote: Bool {
        !isVoted && !isReviewing && (endTime < 0 || endTime > Int64(Date().timeIntervalSince1970))
    }
}

struct PinDetailDTO: Hashable, Sendable {
    let id: Int64
    let sourceURL: URL
    let author: FeedAuthorDTO
    let blocks: [PinContentBlockDTO]
    let createdTime: Int64
    let updatedTime: Int64
    let likeCount: Int
    let commentCount: Int
    let isLiked: Bool
    let topics: [String]
    let poll: PinPollDTO?

    func replacingLike(isLiked: Bool, likeCount: Int) -> Self {
        Self(
            id: id,
            sourceURL: sourceURL,
            author: author,
            blocks: blocks,
            createdTime: createdTime,
            updatedTime: updatedTime,
            likeCount: max(0, likeCount),
            commentCount: commentCount,
            isLiked: isLiked,
            topics: topics,
            poll: poll
        )
    }
}

protocol PinRepository: Sendable {
    func fetch(pinID: Int64) async throws -> PinDetailDTO
    func setLiked(pinID: Int64, liked: Bool) async throws -> Int
    func vote(pollID: String, optionID: String) async throws
    func recordReadHistory(pinID: Int64) async
}

extension PinRepository {
    func recordReadHistory(pinID: Int64) async {}
}

actor URLSessionPinRepository: PinRepository {
    private let client: ZhihuAPIClient

    init(client: ZhihuAPIClient) {
        self.client = client
    }

    func fetch(pinID: Int64) async throws -> PinDetailDTO {
        let url = URL(string: "https://www.zhihu.com/api/v4/pins/\(pinID)?include=topics")!
        let data = try await client.data(for: url, authentication: .accountRequired)
        return try PinResponseMapper.detail(from: data, expectedID: pinID)
    }

    func setLiked(pinID: Int64, liked: Bool) async throws -> Int {
        let url = URL(string: "https://www.zhihu.com/api/v4/pins/\(pinID)/voters/up")!
        let data = try await client.data(
            for: url,
            method: liked ? "POST" : "DELETE",
            authentication: .accountRequired
        )
        return try PinResponseMapper.likedCount(from: data)
    }

    func vote(pollID: String, optionID: String) async throws {
        guard pollID.range(of: #"^\d+$"#, options: .regularExpression) != nil else {
            throw ZhihuAPIError.malformedPayload
        }
        let url = URL(string: "https://www.zhihu.com/api/v4/polls/\(pollID)")!
        let body = try JSONSerialization.data(withJSONObject: ["options": [optionID]])
        _ = try await client.data(
            for: url,
            method: "POST",
            body: body,
            additionalHeaders: ["Content-Type": "application/json"],
            authentication: .accountRequired
        )
    }

    func recordReadHistory(pinID: Int64) async {
        await client.recordReadHistory(contentToken: String(pinID), contentType: "pin")
    }
}

enum PinResponseMapper {
    static func detail(from data: Data, expectedID: Int64) throws -> PinDetailDTO {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let author = author(root["author"] as? [String: Any])
        else { throw ZhihuAPIError.malformedPayload }
        let sourceURL = securePinURL(root["url"] as? String)
            ?? URL(string: "https://www.zhihu.com/pin/\(expectedID)")!
        let content = root["content"] as? [[String: Any]] ?? []
        let blocks = content.enumerated().compactMap { index, item in
            block(item, index: index)
        }
        let html = root["content_html"] as? String ?? root["contentHtml"] as? String ?? ""
        let resolvedBlocks: [PinContentBlockDTO]
        if blocks.isEmpty, !html.isEmpty {
            let parsed = PinHTMLParser.parse(html)
            resolvedBlocks = [.text(id: "html", text: parsed.text, links: parsed.links)]
        } else {
            resolvedBlocks = blocks
        }
        return PinDetailDTO(
            id: Int64(identifier(root["id"]) ?? "") ?? expectedID,
            sourceURL: sourceURL,
            author: author,
            blocks: resolvedBlocks,
            createdTime: int64(root["created"]) ?? 0,
            updatedTime: int64(root["updated"]) ?? 0,
            likeCount: int(root["like_count"] ?? root["likeCount"]) ?? 0,
            commentCount: int(root["comment_count"] ?? root["commentCount"]) ?? 0,
            isLiked: relationshipBoolean(root["virtuals"], snake: "is_liked", camel: "isLiked"),
            topics: (root["topics"] as? [[String: Any]] ?? []).compactMap { ($0["name"] as? String)?.nonBlank },
            poll: poll((root["bottom_poll"] ?? root["bottomPoll"]) as? [String: Any])
        )
    }

    static func likedCount(from data: Data) throws -> Int {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let count = int(root["liked_count"] ?? root["likedCount"])
        else { throw ZhihuAPIError.malformedPayload }
        return count
    }

    private static func block(_ item: [String: Any], index: Int) -> PinContentBlockDTO? {
        switch item["type"] as? String {
        case "text":
            let parsed = PinHTMLParser.parse(item["content"] as? String ?? "")
            guard !parsed.text.isEmpty || !parsed.links.isEmpty else { return nil }
            return .text(id: "text-\(index)", text: parsed.text, links: parsed.links)
        case "image":
            guard let url = securePinMediaURL(item["url"] as? String) else { return nil }
            return .image(
                id: "image-\(index)",
                url: url,
                originalURL: securePinMediaURL(item["original_url"] as? String ?? item["originalUrl"] as? String)
            )
        case "link_card":
            guard let url = securePinURL(item["url"] as? String) else { return nil }
            let type = item["data_content_type"] as? String ?? item["dataContentType"] as? String ?? "内容"
            let id = item["data_content_id"] as? String ?? item["dataContentId"] as? String ?? ""
            return .link(
                id: "link-\(index)",
                title: "\(linkTitle(type)) · \(id)",
                destination: pinDestination(url: url, type: type, contentID: id)
            )
        default:
            return nil
        }
    }

    private static func author(_ root: [String: Any]?) -> FeedAuthorDTO? {
        guard let root,
              let id = (root["id"] as? String)?.nonBlank,
              let name = (root["name"] as? String)?.nonBlank
        else { return nil }
        return FeedAuthorDTO(
            memberID: id,
            urlToken: (root["url_token"] as? String ?? root["urlToken"] as? String)?.nonBlank,
            displayName: name,
            avatarURL: securePinMediaURL(root["avatar_url"] as? String ?? root["avatarUrl"] as? String),
            headline: root["headline"] as? String ?? ""
        )
    }

    private static func poll(_ root: [String: Any]?) -> PinPollDTO? {
        guard let voting = root?["voting"] as? [String: Any],
              let id = identifier(voting["id"]),
              let options = voting["options"] as? [[String: Any]]
        else { return nil }
        return PinPollDTO(
            id: id,
            title: voting["title"] as? String ?? "想法投票",
            voteCount: int(voting["member_count"] ?? voting["memberCount"] ?? voting["voting_count"] ?? voting["votingCount"]) ?? 0,
            isVoted: voting["is_voted"] as? Bool ?? voting["isVoted"] as? Bool ?? false,
            isReviewing: voting["is_reviewing"] as? Bool ?? voting["isReviewing"] as? Bool ?? false,
            endTime: int64(voting["end_at"] ?? voting["endAt"]) ?? -1,
            options: options.compactMap { option in
                guard let optionID = identifier(option["id"]), let title = (option["title"] as? String)?.nonBlank else { return nil }
                return PinPollOptionDTO(
                    id: optionID,
                    title: title,
                    voteCount: int(option["voting_count"] ?? option["votingCount"]) ?? 0,
                    isSelected: option["is_selected"] as? Bool ?? option["isSelected"] as? Bool ?? false
                )
            }
        )
    }

    private static func pinDestination(url: URL, type: String, contentID: String) -> PinLinkDestination {
        guard let numericID = Int64(contentID) else { return .external(url) }
        switch type.lowercased() {
        case "answer":
            if case let .feed(route) = DailyRouteResolver.destination(url: url, fallbackTitle: "关联回答") {
                return .feed(route)
            }
            return .external(url)
        case "article": return .feed(.article(articleID: numericID, title: "关联文章"))
        case "question": return .feed(.question(questionID: numericID, title: "关联问题"))
        case "pin": return .feed(.pin(pinID: numericID))
        case "video", "zvideo":
            return .feed(.video(.init(
                contentID: numericID,
                contentType: .zvideo,
                title: "关联视频",
                webURL: url
            )))
        default: return .external(url)
        }
    }

    private static func linkTitle(_ type: String) -> String {
        switch type.lowercased() {
        case "answer": return "回答"
        case "article": return "文章"
        case "question": return "问题"
        case "pin": return "想法"
        case "video", "zvideo": return "视频"
        default: return "关联内容"
        }
    }

    private static func relationshipBoolean(_ value: Any?, snake: String, camel: String) -> Bool {
        guard let root = value as? [String: Any] else { return false }
        return root[snake] as? Bool ?? root[camel] as? Bool ?? false
    }

    private static func identifier(_ value: Any?) -> String? {
        value as? String ?? (value as? NSNumber)?.stringValue
    }

    private static func int(_ value: Any?) -> Int? {
        value as? Int ?? (value as? NSNumber)?.intValue
    }

    private static func int64(_ value: Any?) -> Int64? {
        value as? Int64 ?? (value as? NSNumber)?.int64Value
    }
}

enum PinHTMLParser {
    struct Result {
        let text: String
        let links: [URL]
    }

    static func parse(_ html: String) -> Result {
        let text: String
        if let data = html.data(using: .utf8),
           let attributed = try? NSAttributedString(
               data: data,
               options: [
                   .documentType: NSAttributedString.DocumentType.html,
                   .characterEncoding: String.Encoding.utf8.rawValue,
               ],
               documentAttributes: nil
           ) {
            text = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            text = html.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let pattern = #"href=[\"']([^\"']+)[\"']"#
        let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        let matches = expression?.matches(in: html, range: NSRange(html.startIndex..., in: html)) ?? []
        let links = matches.compactMap { match -> URL? in
            guard let range = Range(match.range(at: 1), in: html) else { return nil }
            return securePinURL(String(html[range]).replacingOccurrences(of: "&amp;", with: "&"))
        }
        var known: Set<URL> = []
        return Result(text: text, links: links.filter { known.insert($0).inserted })
    }
}

@MainActor
final class PinNativeStore: ObservableObject {
    @Published private(set) var detail: PinDetailDTO?
    @Published private(set) var isLoading = false
    @Published private(set) var isMutatingLike = false
    @Published private(set) var votingOptionID: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var mutationErrorMessage: String?

    let route: PinRouteDTO
    private let repository: PinRepository
    private let offlineInteractions: OfflineInteractionCoordinator?
    private var likeQueueRevision: UInt64 = 0

    init(
        route: PinRouteDTO,
        repository: PinRepository,
        offlineInteractions: OfflineInteractionCoordinator? = nil
    ) {
        self.route = route
        self.repository = repository
        self.offlineInteractions = offlineInteractions
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            let loaded = try await repository.fetch(pinID: route.pinID)
            if let offlineInteractions {
                let projection = offlineInteractions.overlay.pinLike(
                    pinID: loaded.id,
                    serverIsLiked: loaded.isLiked,
                    serverLikeCount: loaded.likeCount
                )
                detail = loaded.replacingLike(
                    isLiked: projection.value,
                    likeCount: projection.count
                )
            } else {
                detail = loaded
            }
            Task { await repository.recordReadHistory(pinID: loaded.id) }
        } catch is CancellationError {
            isLoading = false
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func toggleLike() async {
        guard let current = detail else { return }
        if let offlineInteractions {
            likeQueueRevision &+= 1
            let acceptedRevision = likeQueueRevision
            let target = !current.isLiked
            detail = current.replacingLike(
                isLiked: target,
                likeCount: current.likeCount + (target ? 1 : -1)
            )
            do {
                try await offlineInteractions.setPinLiked(target, pinID: current.id)
            } catch {
                guard likeQueueRevision == acceptedRevision,
                      detail?.id == current.id
                else { return }
                detail = current
                mutationErrorMessage = "无法保存点赞：\(error.localizedDescription)"
            }
            return
        }
        guard !isMutatingLike else { return }
        isMutatingLike = true
        mutationErrorMessage = nil
        do {
            let count = try await repository.setLiked(pinID: current.id, liked: !current.isLiked)
            detail = PinDetailDTO(
                id: current.id, sourceURL: current.sourceURL, author: current.author, blocks: current.blocks,
                createdTime: current.createdTime, updatedTime: current.updatedTime, likeCount: count,
                commentCount: current.commentCount, isLiked: !current.isLiked, topics: current.topics, poll: current.poll
            )
        } catch {
            mutationErrorMessage = error.localizedDescription
        }
        isMutatingLike = false
    }

    func vote(option: PinPollOptionDTO) async {
        guard let current = detail, let poll = current.poll, poll.acceptsVote, votingOptionID == nil else { return }
        votingOptionID = option.id
        mutationErrorMessage = nil
        do {
            try await repository.vote(pollID: poll.id, optionID: option.id)
            if !current.isLiked {
                _ = try await repository.setLiked(pinID: current.id, liked: true)
            }
            await load()
        } catch {
            mutationErrorMessage = error.localizedDescription
        }
        votingOptionID = nil
    }
}

@available(iOS 16.0, *)
struct PinNativeView: View {
    @StateObject private var store: PinNativeStore
    @State private var gallery: PinGalleryDestination?
    @State private var posterDocument: NativeContentPosterDocument?
    let onOpenPerson: (PersonRoutePayload) -> Void
    let onOpenLink: (PinLinkDestination) -> Void
    let onOpenComments: (Int64) -> Void

    init(
        route: PinRouteDTO,
        repository: PinRepository,
        offlineInteractions: OfflineInteractionCoordinator? = nil,
        onOpenPerson: @escaping (PersonRoutePayload) -> Void,
        onOpenLink: @escaping (PinLinkDestination) -> Void,
        onOpenComments: @escaping (Int64) -> Void
    ) {
        _store = StateObject(wrappedValue: PinNativeStore(
            route: route,
            repository: repository,
            offlineInteractions: offlineInteractions
        ))
        self.onOpenPerson = onOpenPerson
        self.onOpenLink = onOpenLink
        self.onOpenComments = onOpenComments
    }

    var body: some View {
        Group {
            if let detail = store.detail {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        author(detail.author)
                        Text(metadata(detail)).font(.caption).foregroundStyle(.secondary)
                        ForEach(detail.blocks) { block in content(block) }
                        if let poll = detail.poll { pollView(poll) }
                        if !detail.topics.isEmpty {
                            Text("话题").font(.headline)
                            Text(detail.topics.map { "# \($0)" }.joined(separator: "   "))
                                .foregroundStyle(.tint)
                        }
                        if let error = store.mutationErrorMessage {
                            Text(error).font(.footnote).foregroundStyle(.red)
                        }
                    }
                    .padding()
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { actionBar(detail) }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button {
                                UIPasteboard.general.url = detail.sourceURL
                            } label: {
                                Label("复制链接", systemImage: "doc.on.doc")
                            }
                            Button {
                                posterDocument = NativeContentPosterDocument(pin: detail)
                            } label: {
                                Label("分享内容海报", systemImage: "photo.on.rectangle.angled")
                            }
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("分享")
                    }
                }
            } else if store.isLoading {
                ProgressView("正在加载想法")
            } else {
                VStack(spacing: 12) {
                    Text(store.errorMessage ?? "想法加载失败").foregroundStyle(.secondary)
                    Button("重试") { Task { await store.load() } }
                }
            }
        }
        .navigationTitle(store.detail.map { "\($0.author.displayName)的想法" } ?? "想法")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $gallery) { destination in
            NativeMediaGallery(urls: destination.urls, initialIndex: destination.initialIndex)
        }
        .sheet(item: $posterDocument) { document in
            NativeContentPosterShareView(document: document)
        }
        .task { if store.detail == nil { await store.load() } }
        .accessibilityIdentifier("pin_native")
    }

    private func author(_ author: FeedAuthorDTO) -> some View {
        Button {
            if let route = PersonRoutePayload(
                memberID: author.memberID,
                urlToken: author.urlToken,
                displayName: author.displayName
            ) { onOpenPerson(route) }
        } label: {
            HStack(spacing: 12) {
                AsyncImage(url: author.avatarURL) { image in image.resizable().scaledToFill() } placeholder: {
                    Color.secondary.opacity(0.12)
                }
                .frame(width: 42, height: 42).clipShape(Circle())
                VStack(alignment: .leading) {
                    Text(author.displayName).font(.headline).foregroundStyle(.primary)
                    if !author.headline.isEmpty { Text(author.headline).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func content(_ block: PinContentBlockDTO) -> some View {
        switch block {
        case let .text(_, text, links):
            VStack(alignment: .leading, spacing: 8) {
                if !text.isEmpty { Text(text).fixedSize(horizontal: false, vertical: true) }
                ForEach(links, id: \.self) { url in Link(url.host ?? url.absoluteString, destination: url) }
            }
        case let .image(_, url, _):
            Button { openGallery(at: url) } label: {
                AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { ProgressView() }
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("查看想法图片")
        case let .link(_, title, destination):
            Button { onOpenLink(destination) } label: {
                Label(title, systemImage: "link").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
        }
    }

    private func pollView(_ poll: PinPollDTO) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(poll.title).font(.headline)
            Text("\(poll.voteCount) 人参与").font(.caption).foregroundStyle(.secondary)
            ForEach(poll.options) { option in
                if poll.acceptsVote {
                    Button(option.title) { Task { await store.vote(option: option) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.votingOptionID != nil)
                } else {
                    HStack {
                        Text(option.title)
                        Spacer()
                        if option.isSelected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                        Text("\(option.voteCount) 票").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func actionBar(_ detail: PinDetailDTO) -> some View {
        NativeFullBleedBottomBar {
            HStack(spacing: 24) {
                Button { Task { await store.toggleLike() } } label: {
                    Label("\(detail.likeCount)", systemImage: detail.isLiked ? "hand.thumbsup.fill" : "hand.thumbsup")
                }
                .disabled(store.isMutatingLike)
                Button { onOpenComments(detail.id) } label: {
                    Label("\(detail.commentCount)", systemImage: "bubble.left")
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
        }
    }

    private func metadata(_ detail: PinDetailDTO) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        var value = "发布于 \(formatter.string(from: Date(timeIntervalSince1970: TimeInterval(detail.createdTime))))"
        if detail.updatedTime > detail.createdTime {
            value += " · 编辑于 \(formatter.string(from: Date(timeIntervalSince1970: TimeInterval(detail.updatedTime))))"
        }
        return value
    }

    private func openGallery(at selectedURL: URL) {
        let images = store.detail?.blocks.compactMap { block -> (display: URL, gallery: URL)? in
            guard case let .image(_, url, originalURL) = block else { return nil }
            return (url, originalURL ?? url)
        } ?? []
        guard let index = images.firstIndex(where: { $0.display == selectedURL }) else { return }
        gallery = PinGalleryDestination(urls: images.map { $0.gallery }, initialIndex: index)
    }
}

private struct PinGalleryDestination: Identifiable {
    let id = UUID()
    let urls: [URL]
    let initialIndex: Int
}

private func securePinURL(_ value: String?) -> URL? {
    guard let value, var components = URLComponents(string: value) else { return nil }
    if components.scheme?.lowercased() == "http" { components.scheme = "https" }
    guard let url = components.url, ZhihuAPIURLPolicy.allows(url) else { return nil }
    return url
}

private func securePinMediaURL(_ value: String?) -> URL? {
    guard let value, let url = URL(string: value), url.scheme?.lowercased() == "https" else { return nil }
    return url
}

private extension String {
    var nonBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
