import AppKit
import SwiftUI

/// A deterministic local screenshot fixture, rendered at 3x with matching Android-pixel bounds.
struct DemoScreen: View {
    private let ink = Color(red: 0.15, green: 0.20, blue: 0.18)
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0.98, green: 0.98, blue: 0.97)
            HStack {
                Text("9:41").font(.system(size: 13, weight: .semibold))
                Spacer()
                Image(systemName: "cellularbars")
                Image(systemName: "wifi")
                Image(systemName: "battery.100percent")
            }.font(.system(size: 11)).frame(width: 304, height: 20).position(x: 180, y: 28)
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 26, weight: .light)).frame(width: 48, height: 48)
                .background(Color(red: 0.9, green: 0.93, blue: 0.9), in: RoundedRectangle(cornerRadius: 14))
                .position(x: 52, y: 136)
            Text("欢迎回来").font(.system(size: 28, weight: .semibold))
                .frame(width: 304, height: 42, alignment: .leading).position(x: 180, y: 195)
            Text("登录，继续你的工作。").font(.system(size: 14)).foregroundStyle(.secondary)
                .frame(width: 304, height: 24, alignment: .leading).position(x: 180, y: 232)
            label("邮箱", y: 258)
            field("hello@example.com", y: 304)
            label("密码", y: 350)
            field("••••••••", y: 396)
            Text("登录").font(.system(size: 16, weight: .medium)).foregroundStyle(.white)
                .frame(width: 304, height: 48)
                .background(ink, in: RoundedRectangle(cornerRadius: 12))
                .position(x: 180, y: 482)
            Text("还没有账号？  创建账号").font(.system(size: 14)).foregroundStyle(.secondary)
                .frame(width: 196, height: 24).position(x: 180, y: 556)
            Capsule().fill(ink.opacity(0.8)).frame(width: 100, height: 4).position(x: 180, y: 724)
        }.foregroundStyle(ink).frame(width: 360, height: 740).environment(\.colorScheme, .light)
    }
    private func label(_ text: String, y: CGFloat) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            .frame(width: 304, height: 18, alignment: .leading).position(x: 180, y: y)
    }
    private func field(_ text: String, y: CGFloat) -> some View {
        Text(text).font(.system(size: 14)).foregroundStyle(.secondary)
            .padding(.horizontal, 16).frame(width: 304, height: 52, alignment: .leading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ink.opacity(0.14)))
            .position(x: 180, y: y)
    }
    @MainActor static func makeImage() -> NSImage {
        let renderer = ImageRenderer(content: DemoScreen())
        renderer.scale = 3
        guard let cgImage = renderer.cgImage else { return NSImage(size: NSSize(width: 360, height: 740)) }
        return NSImage(cgImage: cgImage, size: NSSize(width: 360, height: 740))
    }
}
