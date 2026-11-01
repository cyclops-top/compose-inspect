import Foundation

public struct NodeFilterConfiguration: Codable, Equatable, Sendable {
    public struct ViewRule: Codable, Equatable, Identifiable, Sendable {
        public let className: String
        public var enabled: Bool
        public var id: String { className }
        public var shortName: String { className.components(separatedBy: ".").last ?? className }

        public init(className: String, enabled: Bool = true) {
            self.className = className
            self.enabled = enabled
        }

        public func matches(_ node: InspectorNode) -> Bool {
            guard enabled, node.kind == "ViewNode" else { return false }
            // Fully qualified rules do not hide business subclasses with the same short name.
            // Some dump formats contain only short names; accept those for built-in rules too.
            return node.name == className || (!className.contains(".") && node.shortName == className)
                || (!node.name.contains(".") && node.name == shortName)
        }
    }

    public var hideTextImplementation: Bool
    public var hideLayoutImplementation: Bool
    public var hideCompositionWrappers: Bool
    public var viewRules: [ViewRule]

    public init(hideTextImplementation: Bool = true, hideLayoutImplementation: Bool = true,
                hideCompositionWrappers: Bool = true, viewRules: [ViewRule] = Self.defaultViewRules) {
        self.hideTextImplementation = hideTextImplementation
        self.hideLayoutImplementation = hideLayoutImplementation
        self.hideCompositionWrappers = hideCompositionWrappers
        self.viewRules = viewRules
    }

    public static let defaults = NodeFilterConfiguration()
    public static let defaultViewRules: [ViewRule] = [
        .init(className: "android.widget.FrameLayout"),
        .init(className: "android.widget.LinearLayout"),
        .init(className: "android.widget.RelativeLayout"),
        .init(className: "android.widget.GridLayout"),
        .init(className: "android.widget.TableLayout"),
        .init(className: "android.widget.TableRow"),
        .init(className: "androidx.constraintlayout.widget.ConstraintLayout"),
        .init(className: "androidx.coordinatorlayout.widget.CoordinatorLayout"),
        .init(className: "android.view.ViewStub"),
        .init(className: "androidx.appcompat.widget.ViewStubCompat"),
        .init(className: "androidx.compose.ui.platform.ComposeView"),
        .init(className: "androidx.compose.ui.platform.AndroidComposeView"),
        .init(className: "androidx.compose.ui.platform.AbstractComposeView"),
        .init(className: "android.widget.ScrollView", enabled: false),
        .init(className: "android.widget.HorizontalScrollView", enabled: false),
        .init(className: "androidx.core.widget.NestedScrollView", enabled: false)
    ]

    /// Add only valid class names; adding an existing rule enables it instead of duplicating it.
    @discardableResult public mutating func addViewRule(_ input: String) -> Bool {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = name.split(separator: ".", omittingEmptySubsequences: false)
        guard !segments.isEmpty, segments.allSatisfy({ segment in
            guard let first = segment.first, first.isLetter || first == "_" || first == "$" else { return false }
            return segment.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }
        }) else { return false }
        if let index = viewRules.firstIndex(where: { $0.className == name }) {
            viewRules[index].enabled = true
        } else {
            viewRules.append(.init(className: name))
        }
        return true
    }
}
