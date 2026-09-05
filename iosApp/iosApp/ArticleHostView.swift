import SwiftUI

/// Stable SwiftUI owner for one Answer/Article route. Business state lives in the native pager;
/// comments, media and sharing are delegated upward as typed navigation intents.
struct ArticleHostView: View {
    @StateObject private var pager: AnswerPagerStore
    @AppStorage("pinAnswerDate") private var pinAnswerDate = false
    let onNavigate: (QANavigationIntent) -> Void

    init(
        route: AnswerRouteDTO,
        repository: QuestionAnswerRepository,
        openedHistory: AnswerOpenedHistory,
        diagnostics: PerformanceDiagnosticsClient = .disabled,
        offlineInteractions: OfflineInteractionCoordinator? = nil,
        onNavigate: @escaping (QANavigationIntent) -> Void
    ) {
        _pager = StateObject(
            wrappedValue: AnswerPagerStore(
                route: route,
                repository: repository,
                openedHistory: openedHistory,
                diagnostics: diagnostics,
                offlineInteractions: offlineInteractions
            )
        )
        self.onNavigate = onNavigate
    }

    var body: some View {
        NativeAnswerPager(
            store: pager,
            preferences: QAReadingPreferences(pinAnswerDate: pinAnswerDate),
            onNavigate: onNavigate
        )
    }
}

extension QAReadingPreferences {
    init(pinAnswerDate: Bool) {
        self.pinAnswerDate = pinAnswerDate
    }
}
