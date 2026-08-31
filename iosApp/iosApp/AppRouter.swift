import Foundation
import SwiftUI

enum RiskControlURLPolicy {
    static func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty })
        else { return false }
        return host == "zhihu.com" || host.hasSuffix(".zhihu.com")
    }
}

struct RiskControlFailure: Identifiable, Equatable {
    let requestId: String
    let message: String
    var id: String { requestId }
}

struct RiskControlRequest: Identifiable, Equatable {
    let requestId: String
    let url: URL
    let cookiesJSON: String

    var id: String { requestId }

    init?(requestId: String = UUID().uuidString, url: URL, cookiesJSON: String) {
        guard !requestId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              RiskControlURLPolicy.allows(url),
              (try? RiskControlCookieCodec.cookieValues(from: cookiesJSON)) != nil
        else { return nil }
        self.requestId = requestId
        self.url = url
        self.cookiesJSON = cookiesJSON
    }
}

enum NativeModalRoute: Identifiable, Equatable {
    case login
    case qrAuthorization(QrAuthorizationRequest)
    case riskControl(RiskControlRequest)

    var id: String {
        switch self {
        case .login: return "login"
        case let .qrAuthorization(request): return "qr:\(request.requestId)"
        case let .riskControl(request): return "risk:\(request.requestId)"
        }
    }
}

@MainActor
final class AppRouter: ObservableObject {
    @Published var presentedModal: NativeModalRoute?
    @Published var riskControlFailure: RiskControlFailure?
    @Published var externalURLFailure: ExternalURLFailure?

    func presentLogin() {
        presentedModal = .login
    }

    func presentQrAuthorization(_ request: QrAuthorizationRequest) {
        presentedModal = .qrAuthorization(request)
    }

    func presentRiskControl(_ request: RiskControlRequest) {
        presentedModal = .riskControl(request)
    }

    func dismissModal() {
        presentedModal = nil
    }
}

@MainActor
final class HostModel: ObservableObject {
    let router: AppRouter
    let accountStore: AccountJSONStore
    let apiClient: ZhihuAPIClient
    let account: NativeAccountStore
    let preferences: NativeShellPreferences
    let questionAuthorBlocklist: QuestionAuthorBlocklistStore
    let notificationPreferences: NativeNotificationPreferences
    let notifications: NativeNotificationStore
    let libraryRepository: NativeLibraryRepository
    let specialRepository: NativeSpecialRepository
    let columnRepository: NativeColumnRepository
    let homeRecommendationCachePersistence: HomeRecommendationCachePersisting
    let homeRepository: HomeFeedRepository
    let followRepository: FollowRepository
    let hotRepository: HotFeedRepository
    let searchRepository: SearchRepository
    let dailyRepository: DailyRepository
    let pinRepository: PinRepository
    let creationRepository: CreationRepository
    let questionAnswerRepository: QuestionAnswerRepository
    let videoRepository: NativeVideoRepository
    let answerOpenedHistory: AnswerOpenedHistory
    let systemSettings: NativeSystemIntegrationSettings
    let performanceDiagnostics: NativePerformanceDiagnosticsController
    let appLock: NativeAppLockCoordinator

    private let externalURLCoordinator: ExternalURLCoordinator
    private var riskRetries: [String: () async -> Void] = [:]

    init(
        router: AppRouter? = nil,
        accountStore: AccountJSONStore = KeychainAccountStore(),
        externalURLCoordinator: ExternalURLCoordinator? = nil,
        defaults: UserDefaults = .standard
    ) {
        let router = router ?? AppRouter()
        let externalURLCoordinator = externalURLCoordinator ?? ExternalURLCoordinator(
            opener: UIApplicationExternalURLOpener()
        )
        let performanceDiagnostics = NativePerformanceDiagnosticsController(defaults: defaults)
        let client = ZhihuAPIClient(
            accountStore: accountStore,
            diagnostics: performanceDiagnostics.client
        )
        let notificationPreferences = NativeNotificationPreferences(defaults: defaults)
        let systemSettings = NativeSystemIntegrationSettings(defaults: defaults)

        self.router = router
        self.accountStore = accountStore
        apiClient = client
        account = NativeAccountStore(
            repository: .live(accountStore: accountStore, client: client)
        )
        preferences = NativeShellPreferences(defaults: defaults)
        questionAuthorBlocklist = QuestionAuthorBlocklistStore(defaults: defaults)
        self.notificationPreferences = notificationPreferences
        notifications = NativeNotificationStore(
            repository: .live(client: client),
            preferences: notificationPreferences
        )
        libraryRepository = .live(client: client)
        specialRepository = .live(client: client)
        columnRepository = .live(client: client)
        homeRecommendationCachePersistence = FileHomeRecommendationCachePersistence(
            diagnostics: performanceDiagnostics.client
        )
        homeRepository = URLSessionHomeFeedRepository(
            client: client,
            diagnostics: performanceDiagnostics.client
        )
        followRepository = URLSessionFollowRepository(client: client)
        hotRepository = URLSessionHotFeedRepository(client: client)
        searchRepository = URLSessionSearchRepository(client: client)
        dailyRepository = URLSessionDailyRepository(client: client)
        pinRepository = URLSessionPinRepository(client: client)
        creationRepository = URLSessionCreationRepository(client: client)
        questionAnswerRepository = URLSessionQuestionAnswerRepository(client: client)
        videoRepository = URLSessionNativeVideoRepository(client: client)
        answerOpenedHistory = UserDefaultsAnswerOpenedHistory(defaults: defaults)
        self.systemSettings = systemSettings
        self.performanceDiagnostics = performanceDiagnostics
        appLock = NativeAppLockCoordinator(storedPreference: systemSettings.appLock)
        self.externalURLCoordinator = externalURLCoordinator
    }

    func openLogin() {
        router.presentLogin()
    }

    func loginCompleted() {
        router.dismissModal()
        account.reloadFromKeychain()
        Task { await notifications.refreshUnreadCounts() }
    }

    func openQrAuthorization() {
        guard let cookiesJSON = currentCookiesJSON(),
              let request = QrAuthorizationRequest(
                requestId: UUID().uuidString,
                cookiesJSON: cookiesJSON
              )
        else {
            router.presentLogin()
            return
        }
        router.presentQrAuthorization(request)
    }

    func openRiskControl(url: URL, retry: @escaping () async -> Void) {
        guard let cookiesJSON = currentCookiesJSON(),
              let request = RiskControlRequest(url: url, cookiesJSON: cookiesJSON)
        else {
            router.riskControlFailure = RiskControlFailure(
                requestId: UUID().uuidString,
                message: "安全验证信息无效，请重新登录后重试"
            )
            return
        }
        riskRetries.removeAll()
        riskRetries[request.requestId] = retry
        router.presentRiskControl(request)
    }

    func cancelRiskControl(_ requestID: String) {
        riskRetries.removeValue(forKey: requestID)
        guard case let .riskControl(request) = router.presentedModal,
              request.requestId == requestID
        else { return }
        router.dismissModal()
    }

    func completeRiskControl(_ request: RiskControlRequest, cookiesJSON: String) async throws {
        guard case let .riskControl(current) = router.presentedModal,
              current.requestId == request.requestId
        else { throw ZhihuAPIError.invalidResponse }
        let values = try RiskControlCookieCodec.cookieValues(from: cookiesJSON)
        try ZhihuAccountCookieWriter.merge(cookieValues: values, into: accountStore)
        let retry = riskRetries.removeValue(forKey: request.requestId)
        router.dismissModal()
        await retry?()
    }

    func openExternal(_ url: URL) {
        guard let validated = ExternalWebURLPolicy.validatedURL(from: url.absoluteString) else {
            router.externalURLFailure = ExternalURLFailure(
                url: url.absoluteString,
                message: "链接地址无效"
            )
            return
        }
        externalURLCoordinator.open(
            validated,
            mode: preferences.externalPageOpeningMode
        ) { [weak router] failure in
            router?.externalURLFailure = failure
        }
    }

    func openSystemExternalLink(_ link: SystemExternalLink) {
        guard let url = link.validatedURL else {
            router.externalURLFailure = ExternalURLFailure(
                url: link.destination,
                message: "链接地址无效"
            )
            return
        }
        openExternal(url)
    }

    func setAppLock(_ enabled: Bool) {
        guard !enabled || appLock.settingPresentation.canEnable else { return }
        systemSettings.setAppLock(enabled)
        appLock.updatePreference(enabled)
        if enabled {
            appLock.lock()
            Task { await appLock.unlockIfNeeded() }
        }
    }

    func protectForBackground() {
        guard systemSettings.appLock == true else { return }
        if case let .riskControl(request) = router.presentedModal {
            riskRetries.removeValue(forKey: request.requestId)
        }
        router.dismissModal()
        appLock.lock()
    }

    func modalDidDismiss() {
        guard router.presentedModal == nil else { return }
        riskRetries.removeAll()
    }

    private func currentCookiesJSON() -> String? {
        do {
            guard let credentials = try ZhihuAccountSessionCodec.credentials(from: accountStore.load()),
                  JSONSerialization.isValidJSONObject(credentials.cookies)
            else { return nil }
            let encoded = try JSONSerialization.data(
                withJSONObject: credentials.cookies,
                options: [.sortedKeys]
            )
            return String(decoding: encoded, as: UTF8.self)
        } catch {
            return nil
        }
    }
}
