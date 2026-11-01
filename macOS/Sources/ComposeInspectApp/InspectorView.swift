import ComposeInspectCore
import SwiftUI

struct InspectorView: View {
    @Bindable var store: WorkspaceStore
    @Environment(ToolchainSettings.self) private var tools
    @State private var expandedGroups: Set<NodeParameter.Group> = [.layout, .font, .modifier, .parameter, .attribute]
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("组件与参数选择").font(.system(size: 12, weight: .medium))
                Spacer()
                Button { store.showRawJSON() } label: { Image(systemName: "curlybraces") }
                    .buttonStyle(.plain).help("查看节点、窗口、显示配置和完整原始 JSON")
                    .accessibilityLabel("查看完整 JSON")
                    .disabled(store.snapshot.document == nil)
            }.padding(.horizontal, 14).frame(height: 35).overlay(alignment: .bottom) { Divider() }
            if let node = store.selectedNode {
                let visibleParameters = node.selectableParameters.filter {
                    $0.hasDisplayContent || store.selectedParameters.contains($0.id)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Label(node.shortName, systemImage: "square.on.square")
                                .font(.system(size: 16, weight: .semibold))
                            Text("\(node.kind) · #\(node.rawID)\(node.label.map { " · \($0)" } ?? "")")
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            SectionCaption(text: "源码位置")
                            HStack(spacing: 7) {
                                Image(systemName: "doc.text").foregroundStyle(.secondary)
                                Text(node.source?.text ?? "此节点没有源码位置")
                                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                Spacer(minLength: 0)
                            }.padding(8).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            SectionCaption(text: node.isVirtualLayoutGroup ? "组合范围 · 屏幕像素" : "布局 · 屏幕像素")
                            HStack {
                                Text("x \(Int(node.bounds.minX))  y \(Int(node.bounds.minY))")
                                Spacer()
                                Text("\(Int(node.bounds.width)) × \(Int(node.bounds.height))")
                            }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        if let text = TextComponentPreview(node: node) { TextComponentPreviewView(preview: text) }
                        ComponentStylePreview(node: node)
                        Divider()
                        if node.idResource != nil || node.layoutResource != nil {
                            VStack(alignment: .leading, spacing: 4) {
                                SectionCaption(text: "资源")
                                if let resource = node.idResource { Text(resource).textSelection(.enabled) }
                                if let resource = node.layoutResource { Text(resource).textSelection(.enabled) }
                            }.font(.system(size: 10, design: .monospaced))
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            SectionCaption(text: "选择要提供给 AI 的参数")
                            Text("仅勾选需要的项；输入描述后自动记录。")
                                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        if visibleParameters.isEmpty {
                            Text("没有可用参数").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.vertical, 10)
                        }
                        ForEach(NodeParameter.Group.allCases, id: \.self) { group in
                            let parameters = visibleParameters.filter { $0.presentationGroup(isText: ["Text", "BasicText"].contains(node.shortName)) == group }
                            if !parameters.isEmpty {
                                DisclosureGroup(isExpanded: Binding(get: { expandedGroups.contains(group) }, set: {
                                    if $0 { expandedGroups.insert(group) } else { expandedGroups.remove(group) }
                                })) {
                                    LazyVStack(spacing: 0) {
                                        ForEach(parameters) { parameter in parameterRow(parameter) }
                                    }.padding(.top, 3)
                                } label: {
                                    HStack {
                                        Text(group.rawValue).font(.system(size: 11, weight: .medium))
                                        Text("\(parameters.count)").font(.system(size: 10)).foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                    }.padding(12)
                }
                HStack(spacing: 7) {
                    Image(systemName: "checklist")
                    Text("已选 \(store.selectedParameters.count) 项 · 当前组件")
                    Spacer(minLength: 0)
                }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 30)
                    .background(AppStyle.sidebar).overlay(alignment: .top) { Divider() }
            } else {
                EmptyState(icon: "cursorarrow", title: "未选中组件", subtitle: "点击截图或左侧组件树，查看参数。")
            }
        }.background(AppStyle.background)
    }

    private func parameterRow(_ parameter: NodeParameter) -> some View {
        VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .top, spacing: 6) {
            Toggle(isOn: Binding(get: { store.selectedParameters.contains(parameter.id) }, set: {
                store.toggleParameter(parameter.id, enabled: $0)
            })) { Text(parameter.name).font(.system(size: 10, design: .monospaced)).lineLimit(2) }
                .toggleStyle(.checkbox)
            Spacer(minLength: 2)
            if let argb = parameter.colorARGB { ParameterColorSwatch(argb: argb) }
            Text(parameter.value + (parameter.isTruncated ? " …" : ""))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle).frame(maxWidth: 115, alignment: .trailing)
                .help(parameter.value + (parameter.isTruncated ? "（截断值，可按需继续读取）" : ""))
            if parameter.original != nil {
                Button { store.showRawJSON(parameter: parameter) } label: { Image(systemName: "curlybraces") }
                    .buttonStyle(.plain).help("完整参数、来源链、截断状态和 continuation token")
            }
        }
        if parameter.continuationToken != nil {
            HStack {
                Text("上游已截断").foregroundStyle(.secondary)
                Spacer()
                Button(store.readingParameters.contains(parameter.id) ? "读取中…" : "继续读取") {
                    Task { await store.readParameter(parameter, settings: tools) }
                }.disabled(!store.canRead(parameter) || store.readingParameters.contains(parameter.id))
                    .help("仅当前实时快照可续读；新响应单独保存，不覆盖原始快照。")
            }.font(.system(size: 10))
        }
        }.padding(.vertical, 6).overlay(alignment: .bottom) { Divider().opacity(0.4) }
    }
}

private struct ComponentStylePreview: View {
    let node: InspectorNode
    private func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...1))) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption(text: "当前组件 · 分层样式")
            if let style = node.style {
                let paddingCount = style.layers.reduce(0) { $0 + ($1.padding == nil ? 0 : 1) }
                StyleLayerCanvas(style: style).frame(height: 170)
                    .overlay { Rectangle().stroke(.secondary.opacity(0.25), lineWidth: 1) }
                    .accessibilityLabel("当前组件的独立背景与内边距预览")
                Text("外框 \(number(style.selectionBounds.width / style.density)) × \(number(style.selectionBounds.height / style.density)) dp")
                if style.selectionBounds != style.outerBounds {
                    Text("布局占位 \(number(style.outerBounds.width / style.density)) × \(number(style.outerBounds.height / style.density)) dp")
                        .foregroundStyle(.secondary)
                }
                Text("内容 \(number(style.contentBounds.width / style.density)) × \(number(style.contentBounds.height / style.density)) dp")
                    .foregroundStyle(.secondary)
                if paddingCount > 0 {
                    PaddingBoxDiagram(insets: style.totalPadding, title: "Padding 合计 · dp")
                }
                if style.layers.isEmpty {
                    Text("当前布局没有采集到 padding、背景或裁剪层。")
                        .foregroundStyle(.secondary)
                }
                ForEach(style.layers.filter { $0.kind != "padding" || paddingCount > 1 }) { layer in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .top, spacing: 6) {
                            Text("\(layer.id + 1)").foregroundStyle(.tertiary).frame(width: 16)
                            VStack(alignment: .leading, spacing: 4) {
                                if let padding = layer.padding {
                                    PaddingBoxDiagram(insets: padding, title: "Padding · dp")
                                } else if layer.kind == "background" {
                                    HStack(spacing: 5) {
                                        if let argb = layer.argb, styleColor(argb) != nil {
                                            ParameterColorSwatch(argb: argb, alpha: layer.alpha)
                                        }
                                        Text("背景 · \(layer.argb.map { "#" + $0 } ?? "未解析")")
                                    }
                                    if layer.alpha != 1 { Text("Alpha \(number(layer.alpha))").foregroundStyle(.secondary) }
                                } else if layer.kind == "clip" { Text("裁剪") }
                                if let shape = layer.shape {
                                    if shape.kind == "unknown" {
                                        Text("未知的 shape").foregroundStyle(.orange)
                                        Text(shape.name).textSelection(.enabled).foregroundStyle(.secondary)
                                    } else if shape.kind == "rounded" {
                                        CornerRadiiDiagram(shape: shape, density: style.density)
                                    } else { Text("矩形").foregroundStyle(.secondary) }
                                }
                                if let unsupported = layer.unsupported { Text(unsupported).foregroundStyle(.orange).textSelection(.enabled) }
                            }
                        }
                    }.padding(7).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 5))
                }
                Text("由外到内 · 仅当前布局自身的样式，棋盘格表示透明；不包含父背景及子组件内容。")
                    .foregroundStyle(.secondary)
            } else if node.isVirtualLayoutGroup {
                Text("组合包装节点：选框包含子组件外框；此节点没有独立背景或 padding。")
                    .foregroundStyle(.secondary)
            } else {
                Text("未取得可可靠关联的分层样式，请使用内置采集器重新获取界面。")
                    .foregroundStyle(.secondary)
            }
        }.font(.system(size: 10, design: .monospaced)).fixedSize(horizontal: false, vertical: true)
    }

}

private func styleColor(_ hex: String) -> Color? {
    guard hex.count == 8, let value = UInt32(hex, radix: 16) else { return nil }
    return Color(.sRGB, red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
                 blue: Double(value & 255) / 255, opacity: Double(value >> 24) / 255)
}

private struct StyleLayerCanvas: View {
    let style: ComponentStyle
    var body: some View {
        Canvas { context, size in
            let tile: CGFloat = 10
            for row in 0...Int(size.height / tile) {
                for column in 0...Int(size.width / tile) {
                    context.fill(Path(CGRect(x: CGFloat(column) * tile, y: CGFloat(row) * tile, width: tile, height: tile)),
                        with: .color((row + column) % 2 == 0 ? Color.gray.opacity(0.12) : Color.gray.opacity(0.25)))
                }
            }
            let outer = style.selectionBounds
            guard outer.width > 0, outer.height > 0 else { return }
            let scale = min((size.width - 24) / outer.width, (size.height - 24) / outer.height)
            let offset = CGPoint(x: (size.width - outer.width * scale) / 2, y: (size.height - outer.height * scale) / 2)
            func rect(_ source: CGRect) -> CGRect {
                CGRect(x: (source.minX - outer.minX) * scale + offset.x, y: (source.minY - outer.minY) * scale + offset.y,
                       width: source.width * scale, height: source.height * scale)
            }
            var painting = context
            var unknownClip = false
            for layer in style.layers {
                let box = rect(layer.bounds)
                let path = ComponentStyleDrawing.path(in: box, shape: layer.shape, scale: scale)
                if layer.kind == "clip" {
                    if layer.shape?.kind == "unknown" { unknownClip = true }
                    else { painting.clip(to: path) }
                }
                if !unknownClip, layer.kind == "background", layer.shape?.kind != "unknown", let color = layer.argb.flatMap(styleColor) {
                    painting.fill(path, with: .color(color.opacity(layer.alpha)))
                }
                if layer.kind == "padding", let padding = layer.padding {
                    let pixels = ComponentStyle.Insets(left: padding.left * style.density, top: padding.top * style.density,
                        right: padding.right * style.density, bottom: padding.bottom * style.density)
                    for band in PaddingGeometry.regions(in: layer.bounds, insets: pixels, contentBounds: style.contentBounds) {
                        painting.fill(Path(rect(band)), with: .color(.orange.opacity(0.28)))
                    }
                }
            }
            // A transparent component still needs an explicit outline to show its clip shape.
            for layer in style.layers where layer.kind == "clip" && layer.shape?.kind != "unknown" {
                let path = ComponentStyleDrawing.path(in: rect(layer.bounds), shape: layer.shape, scale: scale)
                context.stroke(path, with: .color(.accentColor.opacity(0.8)), lineWidth: 1)
            }
            context.stroke(Path(rect(style.contentBounds)), with: .color(.secondary.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            let outline = ComponentStyleDrawing.path(in: rect(outer),
                shape: ComponentStyleDrawing.outlineShape(style: style, bounds: outer), scale: scale)
            context.stroke(outline, with: .color(.accentColor), lineWidth: 1)
        }
    }
}

/// A spatial box model: values are placed on their physical sides, without implying
/// that the schematic spacing is to scale or equals the measured layout allocation.
private struct PaddingBoxDiagram: View {
    let insets: ComponentStyle.Insets
    let title: String
    private func value(_ number: Double) -> String { number.formatted(.number.precision(.fractionLength(0...1))) }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: 32, height: 20)
                    Text(value(insets.top)).frame(maxWidth: .infinity).frame(height: 20)
                        .background(insets.top > 0 ? Color.orange.opacity(0.2) : Color.clear)
                    Color.clear.frame(width: 32, height: 20)
                }
                HStack(spacing: 0) {
                    Text(value(insets.left)).frame(width: 32, height: 27)
                        .background(insets.left > 0 ? Color.orange.opacity(0.2) : Color.clear)
                    Text("内容").foregroundStyle(.secondary).frame(maxWidth: .infinity).frame(height: 27)
                        .background(AppStyle.background, in: RoundedRectangle(cornerRadius: 3))
                        .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary.opacity(0.3), lineWidth: 1) }
                    Text(value(insets.right)).frame(width: 32, height: 27)
                        .background(insets.right > 0 ? Color.orange.opacity(0.2) : Color.clear)
                }
                HStack(spacing: 0) {
                    Color.clear.frame(width: 32, height: 20)
                    Text(value(insets.bottom)).frame(maxWidth: .infinity).frame(height: 20)
                        .background(insets.bottom > 0 ? Color.orange.opacity(0.2) : Color.clear)
                    Color.clear.frame(width: 32, height: 20)
                }
            }.padding(5)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(title)：上 \(value(insets.top))，右 \(value(insets.right))，下 \(value(insets.bottom))，左 \(value(insets.left))")
        }.font(.system(size: 10, design: .monospaced)).frame(maxWidth: .infinity)
    }
}

private struct CornerRadiiDiagram: View {
    let shape: ComponentStyle.Shape
    let density: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("圆角 · dp").foregroundStyle(.secondary)
            Grid(horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    corner("左上", value: shape.topLeft, rotation: 0)
                    corner("右上", value: shape.topRight, rotation: 90)
                }
                GridRow {
                    corner("左下", value: shape.bottomLeft, rotation: 270)
                    corner("右下", value: shape.bottomRight, rotation: 180)
                }
            }
        }
    }
    private func corner(_ name: String, value: Double, rotation: Double) -> some View {
        let text = (value / density).formatted(.number.precision(.fractionLength(0...1)))
        return HStack(spacing: 5) {
            CornerRadiusGlyph().stroke(.secondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .frame(width: 13, height: 13).rotationEffect(.degrees(rotation))
            Text(text).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore).accessibilityLabel("\(name)圆角 \(text) dp")
            .help("\(name)圆角")
    }
}

private struct CornerRadiusGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.15, y: rect.minY + rect.height * 0.9))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.15, y: rect.minY + rect.height * 0.6))
        path.addQuadCurve(to: CGPoint(x: rect.minX + rect.width * 0.6, y: rect.minY + rect.height * 0.15),
                         control: CGPoint(x: rect.minX + rect.width * 0.15, y: rect.minY + rect.height * 0.15))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.9, y: rect.minY + rect.height * 0.15))
        return path
    }
}

private struct ParameterColorSwatch: View {
    let argb: String
    var alpha: Double = 1
    var body: some View {
        Canvas { context, size in
            for row in 0..<4 {
                for column in 0..<4 {
                    context.fill(Path(CGRect(x: CGFloat(column) * 4, y: CGFloat(row) * 4, width: 4, height: 4)),
                        with: .color((row + column) % 2 == 0 ? .white : Color(white: 0.65)))
                }
            }
            if let color = styleColor(argb) {
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color.opacity(alpha)))
            }
        }.frame(width: 16, height: 16).clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary.opacity(0.5), lineWidth: 0.5) }
            .help("#\(argb) · 棋盘格表示透明")
            .accessibilityLabel("颜色预览 #\(argb)")
    }
}

private struct TextComponentPreviewView: View {
    let preview: TextComponentPreview
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption(text: "文本预览")
            Text(preview.content.isEmpty ? "（空文本）" : preview.content)
                .font(.system(size: preview.fontUnit == "sp" ? min(preview.fontSize ?? 14, 96) : 14))
                .foregroundStyle(preview.colorARGB.flatMap(styleColor) ?? .primary)
                .textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    Canvas { context, size in
                        for row in 0...Int(size.height / 8) {
                            for column in 0...Int(size.width / 8) {
                                context.fill(Path(CGRect(x: CGFloat(column) * 8, y: CGFloat(row) * 8, width: 8, height: 8)),
                                    with: .color((row + column) % 2 == 0 ? Color(white: 0.95) : Color(white: 0.8)))
                            }
                        }
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 5))
            HStack(spacing: 6) {
                if let argb = preview.colorARGB {
                    ParameterColorSwatch(argb: argb)
                    Text("#" + argb)
                } else { Text("颜色未采集 · 使用示意色") }
                Spacer(minLength: 0)
                if let size = preview.fontSize, let unit = preview.fontUnit {
                    Text(size.formatted(.number.precision(.fractionLength(0...1))) + unit)
                } else { Text("字号未采集") }
            }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        }
    }
}
