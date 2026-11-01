import Foundation
import CoreGraphics

public extension InspectorSnapshot {
    static func demo(id: UUID = UUID()) -> InspectorSnapshot {
        func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
            CGRect(x: x * 3, y: y * 3, width: w * 3, height: h * 3)
        }
        func parameter(_ name: String, _ value: String, _ group: NodeParameter.Group = .parameter) -> NodeParameter {
            NodeParameter(id: "\(group.rawValue).\(name)", name: name, value: value, group: group)
        }
        let nodes: [InspectorNode] = [
            InspectorNode(id: "welcome", rawID: 20, name: "Text", label: "欢迎回来", bounds: rect(28, 174, 304, 42),
                          source: SourceAnchor(file: "LoginScreen.kt", line: 42), parameters: [parameter("fontSize", "28sp"), parameter("text", "欢迎回来", .semantics)]),
            InspectorNode(id: "email", rawID: 30, name: "TextField", label: "邮箱", bounds: rect(28, 278, 304, 52),
                          source: SourceAnchor(file: "LoginScreen.kt", line: 64), parameters: [parameter("textStyle.fontSize", "14sp"), parameter("height", "52dp", .modifier), parameter("testTag", "login_email", .semantics)]),
            InspectorNode(id: "password", rawID: 31, name: "TextField", label: "密码", bounds: rect(28, 370, 304, 52),
                          source: SourceAnchor(file: "LoginScreen.kt", line: 75), parameters: [parameter("height", "52dp", .modifier), parameter("enabled", "true")]),
            InspectorNode(id: "login", rawID: 42, name: "Button", label: "登录", bounds: rect(28, 458, 304, 48),
                          source: SourceAnchor(file: "LoginScreen.kt", line: 86), parameters: [parameter("height", "48dp", .modifier), parameter("fillMaxWidth", "true", .modifier), parameter("enabled", "true"), parameter("shape", "RoundedCorner(12dp)"), parameter("text", "登录", .semantics), parameter("testTag", "login_submit", .semantics)],
                          children: [InspectorNode(id: "login-text", rawID: 43, name: "Text", label: "登录", bounds: rect(158, 470, 44, 24), parameters: [parameter("text", "登录", .semantics)])]),
            InspectorNode(id: "signup", rawID: 50, name: "Text", label: "创建账号", bounds: rect(82, 544, 196, 24),
                          source: SourceAnchor(file: "LoginScreen.kt", line: 98), parameters: [parameter("padding.top", "38dp", .modifier), parameter("fontSize", "14sp")]),
        ]
        let column = InspectorNode(id: "column", rawID: 12, name: "Column", bounds: rect(28, 120, 304, 480), children: nodes)
        let screen = InspectorNode(id: "screen", rawID: 10, name: "LoginScreen", bounds: rect(0, 0, 360, 740),
                                   source: SourceAnchor(file: "LoginScreen.kt", line: 30), children: [column])
        let root = InspectorNode(id: "root", rawID: 1, name: "ComposeView", kind: "ViewNode", bounds: rect(0, 0, 360, 740), children: [screen])
        return InspectorSnapshot(id: id, packageName: "com.example.app", deviceName: "Pixel 9", pixelSize: CGSize(width: 1080, height: 2220), roots: [root], isDemo: true)
    }
}
