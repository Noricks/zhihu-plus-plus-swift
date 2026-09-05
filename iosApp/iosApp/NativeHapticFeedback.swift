import SwiftUI
import UIKit

enum NativeHapticStrength: String, CaseIterable, Identifiable {
    case light
    case standard
    case strong

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "轻"
        case .standard: return "标准"
        case .strong: return "强"
        }
    }
}

struct NativeHapticFeedbackConfiguration: Equatable {
    var isEnabled = true
    var strength = NativeHapticStrength.standard
}

enum NativeHapticFeedbackEvent: Equatable {
    case selection
    case commit
    case longPress
    case dismiss
    case navigationBoundary
    case refreshSucceeded
    case refreshIgnored
    case strengthPreview
}

struct NativeHapticFeedbackAction {
    private let configuration: NativeHapticFeedbackConfiguration
    private let perform: @MainActor (NativeHapticFeedbackEvent, NativeHapticStrength) -> Void

    init(
        configuration: NativeHapticFeedbackConfiguration,
        perform: @escaping @MainActor (NativeHapticFeedbackEvent, NativeHapticStrength) -> Void
    ) {
        self.configuration = configuration
        self.perform = perform
    }

    @MainActor
    func callAsFunction(_ event: NativeHapticFeedbackEvent) {
        guard configuration.isEnabled else { return }
        perform(event, configuration.strength)
    }

    @MainActor
    func previewStrength(_ strength: NativeHapticStrength) {
        guard configuration.isEnabled else { return }
        perform(.strengthPreview, strength)
    }

    @MainActor
    static func live(configuration: NativeHapticFeedbackConfiguration) -> Self {
        Self(configuration: configuration) { event, strength in
            NativeHapticFeedbackPerformer.perform(event, strength: strength)
        }
    }

    static let disabled = Self(
        configuration: .init(isEnabled: false),
        perform: { _, _ in }
    )
}

@MainActor
private enum NativeHapticFeedbackPerformer {
    static func perform(_ event: NativeHapticFeedbackEvent, strength: NativeHapticStrength) {
        let generator = UIImpactFeedbackGenerator(style: impactStyle(for: strength))
        generator.prepare()
        generator.impactOccurred(intensity: NativeHapticFeedbackIntensityPolicy.intensity(for: event))
    }

    private static func impactStyle(
        for strength: NativeHapticStrength
    ) -> UIImpactFeedbackGenerator.FeedbackStyle {
        switch strength {
        case .light: return .light
        case .standard: return .medium
        case .strong: return .heavy
        }
    }
}

enum NativeHapticFeedbackIntensityPolicy {
    static func intensity(for event: NativeHapticFeedbackEvent) -> CGFloat {
        switch event {
        case .selection: return 0.5
        case .commit: return 1
        case .longPress: return 0.8
        case .dismiss: return 0.6
        case .navigationBoundary: return 1
        case .refreshSucceeded: return 0.55
        case .refreshIgnored: return 0.45
        case .strengthPreview: return 0.8
        }
    }
}

enum NativeHapticStrengthSelectionPolicy {
    static func shouldPreview(
        current: NativeHapticStrength,
        selected: NativeHapticStrength,
        isHapticsEnabled: Bool
    ) -> Bool {
        isHapticsEnabled && current != selected
    }
}

struct NativeRefreshHapticPolicy {
    static func shouldEmit(
        previousSuccessfulRefreshAt: Date?,
        currentSuccessfulRefreshAt: Date?
    ) -> Bool {
        guard previousSuccessfulRefreshAt != nil,
              currentSuccessfulRefreshAt != nil
        else { return false }
        return currentSuccessfulRefreshAt != previousSuccessfulRefreshAt
    }
}

private struct NativeHapticFeedbackEnvironmentKey: EnvironmentKey {
    static let defaultValue = NativeHapticFeedbackAction.disabled
}

extension EnvironmentValues {
    var nativeHapticFeedback: NativeHapticFeedbackAction {
        get { self[NativeHapticFeedbackEnvironmentKey.self] }
        set { self[NativeHapticFeedbackEnvironmentKey.self] = newValue }
    }
}
