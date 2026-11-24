import Foundation

public struct NodeFilterConfiguration: Codable, Equatable, Sendable {
    public var hideTextImplementation: Bool
    public var hideLayoutImplementation: Bool
    public var hideCompositionWrappers: Bool
    public var hideComposeHosts: Bool

    public static let defaults = NodeFilterConfiguration()
    public init(hideTextImplementation: Bool = true, hideLayoutImplementation: Bool = true,
                hideCompositionWrappers: Bool = true, hideComposeHosts: Bool = true) {
        self.hideTextImplementation = hideTextImplementation
        self.hideLayoutImplementation = hideLayoutImplementation
        self.hideCompositionWrappers = hideCompositionWrappers
        self.hideComposeHosts = hideComposeHosts
    }

    private enum CodingKeys: String, CodingKey {
        case hideTextImplementation, hideLayoutImplementation, hideCompositionWrappers, hideComposeHosts
    }

    // Earlier versions stored the SDK host preference among the Android View class rules.
    private enum LegacyKey: String, CodingKey { case viewRules }
    private struct LegacyRule: Decodable {
        let className: String
        let enabled: Bool
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hideTextImplementation = try values.decode(Bool.self, forKey: .hideTextImplementation)
        hideLayoutImplementation = try values.decode(Bool.self, forKey: .hideLayoutImplementation)
        hideCompositionWrappers = try values.decode(Bool.self, forKey: .hideCompositionWrappers)
        if let enabled = try values.decodeIfPresent(Bool.self, forKey: .hideComposeHosts) {
            hideComposeHosts = enabled
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKey.self)
            let rules = try legacy.decode([LegacyRule].self, forKey: .viewRules)
            hideComposeHosts = rules.contains {
                $0.enabled && ["androidx.compose.ui.platform.AndroidComposeView", "AndroidComposeView"].contains($0.className)
            }
        }
    }
}
