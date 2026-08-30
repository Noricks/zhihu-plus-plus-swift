import Foundation

/// The built-in home channels in their fixed presentation order.
///
/// Remote categories are intentionally not modeled until their API contract is
/// verified. Adding them later extends this domain model rather than the shell's
/// bottom-tab representation.
enum HomeChannel: String, CaseIterable, Hashable, Identifiable {
    case recommendation
    case following
    case hot
    case daily

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recommendation: return "推荐"
        case .following: return "关注"
        case .hot: return "热榜"
        case .daily: return "日报"
        }
    }
}
