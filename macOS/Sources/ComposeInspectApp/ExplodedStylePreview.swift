import ComposeInspectCore
import SwiftUI

private extension ComponentStyle.Layer {
    var clipPath: Path? {
        guard kind == "clip", unsupported == nil, let shape,
              ["rectangle", "rounded", "cut", "path"].contains(shape.kind) else { return nil }
        return ComponentStyleDrawing.path(in: bounds, shape: shape, scale: 1)
    }

    var title: String {
        switch kind {
        case "padding": "Padding"
        case "background": "背景"
        case "clip": "裁剪"
        default: "未解析操作"
        }
    }
    var uncertain: Bool {
        unsupported != nil || shape?.kind == "unknown" ||
            (kind == "background" && argb.flatMap(styleColor) == nil) ||
            !["clip", "padding", "background"].contains(kind)
    }
}

struct StylePlane {
    let outline: Path
    let surface: Path
    let layer: ComponentStyle.Layer

    let labelBounds: CGRect

    init(_ index: Int, style: ComponentStyle, transform: CGAffineTransform) {
        let layer = style.layers[index]
        self.layer = layer
        let shape = ComponentStyleDrawing.path(in: layer.bounds, shape: layer.shape, scale: 1)
        labelBounds = shape.applying(transform).boundingRect
        var visible = shape
        // All masks use the measured screen coordinates, before separating the planes.
        for mask in style.layers[..<index].compactMap(\.clipPath) {
            visible = visible.intersection(mask)
        }
        outline = visible.applying(transform)
        if let p = layer.padding {
            let px = ComponentStyle.Insets(left: p.left * style.density, top: p.top * style.density,
                                            right: p.right * style.density, bottom: p.bottom * style.density)
            var bands = Path()
            for band in PaddingGeometry.regions(in: layer.bounds, insets: px) { bands.addRect(band) }
            surface = bands.intersection(visible).applying(transform)
        } else { surface = outline }
    }

    func contains(_ point: CGPoint) -> Bool {
        outline.contains(point)
    }

    func draw(in context: GraphicsContext, selected: Bool) {
        let ink: Color = selected ? .accentColor : .secondary
        if !layer.uncertain {
            switch layer.kind {
            case "padding": context.fill(surface, with: .color(.orange.opacity(0.64)))
            case "background":
                if let color = layer.argb.flatMap(styleColor) {
                    context.fill(surface, with: .color(color.opacity(layer.alpha)))
                }
            case "clip": context.fill(surface, with: .color(.teal.opacity(0.12)))
            default: break
            }
        }
        context.stroke(outline, with: .color(ink), style: StrokeStyle(lineWidth: selected ? 2.4 : 1,
                                                                    dash: layer.uncertain ? [4, 3] : []))
    }
}

struct StyleStackLayout {
    let style: ComponentStyle
    let size: CGSize
    private var step: CGFloat { min(64, size.height * 0.62 / CGFloat(max(1, style.layers.count - 1))) }

    func plane(_ index: Int) -> StylePlane {
        let skew = CGAffineTransform(a: 0.90, b: 0.13, c: -0.48, d: 0.31, tx: 0, ty: 0)
        let box = style.selectionBounds.applying(skew)
        let stack = CGFloat(style.layers.count - 1) * step
        let scale = min(max(1, size.width - 108) / max(1, box.width),
                        max(1, size.height - stack - 56) / max(1, box.height))
        var t = skew.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        t.tx = size.width / 2 + 4 - box.midX * scale
        t.ty = (size.height + stack) / 2 - box.midY * scale - CGFloat(index) * step
        return StylePlane(index, style: style, transform: t)
    }

    func hit(_ point: CGPoint) -> Int? {
        var nearby: Int?
        for index in style.layers.indices.reversed() {
            let candidate = plane(index)
            if candidate.contains(point) { return index }
            if nearby == nil, candidate.outline.strokedPath(StrokeStyle(lineWidth: 18)).contains(point) {
                nearby = index
            }
        }
        return nearby
    }
}

@MainActor @Observable
final class StylePreviewSelection {
    var index = 0
}

struct ExplodedStylePreview: View {
    let name: String
    let style: ComponentStyle
    let screenshot: NSImage?
    let bounds: CGRect
    @Bindable var selection = StylePreviewSelection()
    @State private var crop: CGImage?
    let dismiss: () -> Void

    static func crop(_ image: CGImage, to bounds: CGRect) -> CGImage? {
        let area = bounds.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !area.isEmpty else { return nil }
        return image.cropping(to: area)
    }

    private var layer: ComponentStyle.Layer { style.layers[selection.index] }
    private func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...2))) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(name).font(.headline)
                Text("立体样式预览").foregroundStyle(.secondary)
                Spacer()
                IconButton(title: "关闭立体样式预览", systemImage: "xmark") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(14)
            Divider()
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        Text("样式顺序 · ① 最外层在下，向上逐层靠近内容")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding([.top, .horizontal], 14)
                        stack
                    }.frame(width: proxy.size.width * 0.58)
                        .background(Color(nsColor: .underPageBackgroundColor))
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("第 \(selection.index + 1) / \(style.layers.count) 层 · \(layer.title)").font(.headline)
                            face.frame(height: 112).accessibilityLabel("当前层正视预览")
                            if let padding = layer.padding { PaddingBoxDiagram(insets: padding, title: "Padding · dp") }
                            if layer.kind == "background" {
                                Text("ARGB  " + (layer.argb.map { "#" + $0 } ?? "未知"))
                                Text("Alpha  " + number(layer.alpha))
                            }
                            if let shape = layer.shape {
                                if ["rounded", "cut"].contains(shape.kind) {
                                    CornerRadiiDiagram(shape: shape, density: style.density, bounds: layer.bounds)
                                } else { Text(shape.kind == "unknown" ? "未知形状 · " + shape.name : shape.title(in: layer.bounds)) }
                            }
                            let b = layer.bounds
                            Text("屏幕边界  (\(number(b.minX)), \(number(b.minY))) · \(number(b.width)) × \(number(b.height)) px")
                            if layer.uncertain {
                                Text(layer.name).textSelection(.enabled)
                                Text(layer.unsupported ?? "仅取得实测边界").foregroundStyle(.secondary)
                            }
                            if let crop {
                                Divider()
                                Text("截图局部").foregroundStyle(.secondary)
                                screenshotPreview(crop)
                                    .frame(maxWidth: .infinity, maxHeight: 100)
                            }
                        }.font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                }
            }
            Divider()
            HStack {
                Picker("选择层", selection: $selection.index) {
                    ForEach(style.layers.indices, id: \.self) { i in
                        Text("\(i + 1) · \(style.layers[i].title)").tag(i)
                    }
                }.pickerStyle(.menu).fixedSize()
                Spacer()
                IconButton(title: "选择下方样式层", systemImage: "arrow.down") { selection.index -= 1 }
                    .keyboardShortcut(.downArrow, modifiers: [])
                    .disabled(selection.index == 0)
                IconButton(title: "选择上方样式层", systemImage: "arrow.up") { selection.index += 1 }
                    .keyboardShortcut(.upArrow, modifiers: [])
                    .disabled(selection.index == style.layers.count - 1)
            }.padding(12)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if let cg = screenshot?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                crop = Self.crop(cg, to: bounds)
            }
        }
    }

    private func screenshotPreview(_ crop: CGImage) -> some View {
        // The crop starts at the first on-screen pixel for partially visible components.
        let origin = bounds.integral.origin
        let masks = style.layers[...selection.index].compactMap(\.clipPath)
        return Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            if !masks.isEmpty {
                Self.drawCheckerboard(in: context, size: size)
                let scale = size.width / CGFloat(crop.width)
                let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                                  tx: -max(0, origin.x) * scale,
                                                  ty: -max(0, origin.y) * scale)
                for mask in masks { context.clip(to: mask.applying(transform)) }
            }
            context.draw(Image(decorative: crop, scale: 1), in: rect)
        }
        .aspectRatio(CGFloat(crop.width) / CGFloat(crop.height), contentMode: .fit)
    }

    private static func drawCheckerboard(in context: GraphicsContext, size: CGSize) {
        for y in stride(from: 0, to: Int(ceil(size.height)), by: 8) {
            for x in stride(from: 0, to: Int(ceil(size.width)), by: 8) where (x / 8 + y / 8).isMultiple(of: 2) {
                context.fill(Path(CGRect(x: x, y: y, width: 8, height: 8)), with: .color(.secondary.opacity(0.13)))
            }
        }
    }

    private var face: some View {
        Canvas { context, size in
            let b = layer.bounds
            let scale = min((size.width - 16) / max(1, b.width), (size.height - 16) / max(1, b.height))
            let t = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: size.width / 2 - b.midX * scale,
                                      ty: size.height / 2 - b.midY * scale)
            if layer.kind == "background" {
                Self.drawCheckerboard(in: context, size: size)
            }
            StylePlane(selection.index, style: style, transform: t).draw(in: context, selected: false)
        }
    }

    private var stack: some View {
        GeometryReader { proxy in
            let layout = StyleStackLayout(style: style, size: proxy.size)
            ZStack {
                Canvas { context, _ in
                    for index in style.layers.indices {
                        layout.plane(index).draw(in: context, selected: index == selection.index)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { point in
                    if let i = layout.hit(point) { selection.index = i }
                }
                ForEach(style.layers.indices, id: \.self) { i in
                    let b = layout.plane(i).labelBounds
                    Button { selection.index = i } label: {
                        Text("\(i + 1)").font(.caption.monospacedDigit().weight(.semibold))
                            .frame(minWidth: 22, minHeight: 22)
                            .background(i == selection.index ? Color.accentColor : Color(nsColor: .controlBackgroundColor), in: Circle())
                            .foregroundStyle(i == selection.index ? Color.white : Color.primary)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .position(x: max(14, b.minX - 16), y: b.midY)
                    .accessibilityLabel("第 \(i + 1) 层 · \(style.layers[i].title)")
                    .accessibilityAddTraits(i == selection.index ? .isSelected : [])
                }
            }
        }.background(Color(nsColor: .underPageBackgroundColor))
    }
}

private final class StylePreviewPanel: NSPanel {
    var handleKey: ((String?) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           handleKey?(event.charactersIgnoringModifiers) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Present a native resizable sheet and share its content size across component previews.
struct StylePreviewSheet: NSViewRepresentable {
    @Binding var isPresented: Bool
    let onDismiss: () -> Void
    let content: () -> ExplodedStylePreview

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        guard isPresented else {
            coordinator.endSheet()
            return
        }
        guard coordinator.panel == nil, let parent = view.window else { return }
        let key = "StylePreviewContentSize"
        let stored = NSSizeFromString(UserDefaults.standard.string(forKey: key) ?? "")
        let available = parent.screen?.visibleFrame.size ?? CGSize(width: 740, height: 480)
        let size = CGSize(width: min(available.width, max(580, stored.width > 0 ? stored.width : 740)),
                          height: min(available.height - 40, max(360, stored.height > 0 ? stored.height : 480)))
        let panel = StylePreviewPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
                            backing: .buffered, defer: false)
        panel.title = "立体样式预览"
        let preview = content()
        panel.handleKey = { key in
            switch key {
            case KeyEquivalent.upArrow.character.description, KeyEquivalent.rightArrow.character.description:
                preview.selection.index = min(preview.style.layers.count - 1, preview.selection.index + 1)
            case KeyEquivalent.downArrow.character.description, KeyEquivalent.leftArrow.character.description:
                preview.selection.index = max(0, preview.selection.index - 1)
            case KeyEquivalent.escape.character.description:
                preview.dismiss()
            default: return false
            }
            return true
        }
        let host = NSHostingView(rootView: preview)
        host.sizingOptions = []
        panel.contentView = host
        panel.contentMinSize = CGSize(width: 580, height: 360)
        panel.setContentSize(size)
        panel.delegate = coordinator
        coordinator.panel = panel
        parent.beginSheet(panel) { _ in
            panel.orderOut(nil)
            coordinator.panel = nil
            onDismiss()
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.endSheet() }

    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        var panel: NSPanel?

        func endSheet() {
            guard let panel, let parent = panel.sheetParent else { return }
            parent.endSheet(panel)
        }

        func windowDidResize(_ notification: Notification) {
            guard let panel, let size = panel.contentView?.bounds.size else { return }
            UserDefaults.standard.set(NSStringFromSize(size), forKey: "StylePreviewContentSize")
        }
    }
}
