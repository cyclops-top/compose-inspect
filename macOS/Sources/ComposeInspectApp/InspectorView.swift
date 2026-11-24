import ComposeInspectCore
import SwiftUI

struct InspectorView: View {
    @Bindable var store: WorkspaceStore
    @Environment(ToolchainSettings.self) private var tools
    private enum Tab: String, CaseIterable {
        case basic = "基础"
        case state = "状态"
        case style = "样式"
        case location = "定位"
        case parameters = "参数"
    }

    @State private var expectedText = ""
    @State private var selectedTab = Tab.state
    @State private var expandedGroups: Set<NodeParameter.Group> = [.layout, .font, .modifier, .parameter, .attribute]
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("组件属性").font(.system(size: 12, weight: .medium))
                Spacer()
                Button { store.showRawJSON() } label: { Image(systemName: "curlybraces") }
                    .buttonStyle(.plain).help("查看节点、窗口、显示配置和完整原始 JSON")
                    .accessibilityLabel("查看完整 JSON")
                    .disabled(store.snapshot.document == nil)
            }.padding(.horizontal, 14).frame(height: 35).overlay(alignment: .bottom) { Divider() }
            if let result = store.verificationResult {
                Text(result).font(.caption).textSelection(.enabled).padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            if let watch = store.observation {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(watch.component) · \(watch.group.rawValue) \(watch.field)").font(.caption.bold())
                        Spacer()
                        IconButton(title: "结束关注", systemImage: "eye.slash") { store.observation = nil }.buttonStyle(.borderless)
                    }
                    if let before = watch.previous {
                        Text("上次 \(before.time.formatted(date: .omitted, time: .standard)) · \(before.value)")
                    }
                    Text("最近有效 \(watch.latest.time.formatted(date: .omitted, time: .standard)) · \(watch.latest.value)")
                    Text(watch.detail).foregroundStyle(.secondary)
                }.font(.caption).textSelection(.enabled).padding(10)
                Divider()
            }
            if let node = store.selectedNode {
                HStack {
                    Text(node.shortName)
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        .lineLimit(1).help(node.shortName)
                        .textSelection(.enabled)
                    Spacer()
                    let location = store.sourceLocation(for: node.id)
                    SourceNavigationButtons(location: location, project: tools.androidProjectPath,
                        index: store.usesProjectSources || location?.inProject == true ? store.projectSources : nil,
                        copy: { store.copy($0) }, showNotice: { store.notice = $0 })
                        .id(store.selectedKey).id(tools.androidProjectPath)
                }
                .padding(.horizontal, 12).padding(.top, 10)
                Picker("组件属性分组", selection: $selectedTab) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented).labelsHidden()
                .padding(.horizontal, 12).padding(.vertical, 8)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        switch selectedTab {
                        case .basic:
                            PrimaryAttributes(node: node) { selectedTab = .style }
                            layoutBounds(for: node)
                            if let style = node.style {
                                BoxPreview(style: style)
                            }
                        case .state:
                            if node.isClickable, store.snapshot.captureMetadata != nil {
                                VStack(alignment: .leading, spacing: 6) {
                                    SectionCaption(text: "单次点击验证")
                                    TextField("点击后出现的完整文本或描述", text: $expectedText)
                                        .textFieldStyle(.roundedBorder)
                                    IconButton(title: "点击一次并验证", systemImage: "hand.tap") {
                                        let condition = expectedText
                                        Task { await store.verifyClick(expected: condition, settings: tools) }
                                    }.disabled(expectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }.disabled(store.isCapturing)
                                Divider()
                            }
                            if LazyViewport.componentNames.contains(node.shortName) { viewportSection(node) }
                            let fields = node.observableFields
                            if fields.isEmpty { Text("本次采集没有可观察的标量字段").foregroundStyle(.secondary) }
                            ForEach(fields) { field in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(field.name).font(.caption.bold())
                                        Text(field.group == .unmergedSemantics || field.group == .mergedSemantics
                                             ? "\(field.group.rawValue) · 关联布局" : field.group.rawValue).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(field.original?["value"] == .null ? "null" : field.value).textSelection(.enabled)
                                    IconButton(title: "关注\(field.name)", systemImage: "eye") { store.observe(field, on: node) }
                                        .disabled(store.isCapturing)
                                }
                            }
                            if node.kind == "ComposeNode", !fields.contains(where: { $0.group == .mergedSemantics }) {
                                let reason = node.parameters.first { $0.name == "合并语义采集限制" || $0.name == "交互采集限制" }
                                Text(reason.map { "\($0.name) · \($0.value)" } ?? "未取得此组件独立的合并语义节点")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        case .style:
                            if let text = TextComponentPreview(node: node), let content = text.content {
                                TextComponentPreviewView(content: content, preview: text)
                            }
                            ComponentStylePreview(node: node, ancestors: Array(store.snapshotIndex.path(to: node.id).dropLast()),
                                                  snapshotID: store.snapshot.id, screenshot: store.image)
                        case .location:
                            locationDetails(for: node)
                        case .parameters:
                            parameterGroups(for: node)
                        }
                    }.padding(12)
                }
                .id(selectedTab)
                if selectedTab == .parameters || !store.selectedParameters.isEmpty {
                    HStack(spacing: 7) {
                        Image(systemName: "checklist")
                        Text("已选 \(store.selectedParameters.count) 项 · 当前组件")
                        Spacer(minLength: 0)
                    }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 30)
                        .background(AppStyle.sidebar).overlay(alignment: .top) { Divider() }
                }
            } else {
                EmptyState(icon: "cursorarrow", title: "未选中组件", subtitle: "点击截图或左侧组件树，查看参数。")
            }
        }.background(AppStyle.background)
    }

    @ViewBuilder
    private func viewportSection(_ node: InspectorNode) -> some View {
        SectionCaption(text: "列表视口")
        if let viewport = LazyViewport(node: node) {
            Text("\(viewport.axis) · \(viewport.start)…\(viewport.end) px")
            Text("state.layoutInfo · 可见条目 \(viewport.count) 个")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(viewport.items) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text("索引 \(item.id) · 主轴\(item.extent)")
                    Text(item.gridBounds ?? "主轴偏移 \(item.offset) px · 长度 \(item.size) px")
                    Text(item.key.map { "条目 key " + $0 } ?? "key 未提供标量值")
                }.font(.caption).textSelection(.enabled)
            }
            if viewport.items.count < viewport.count {
                Text("已采集前 \(viewport.items.count) 项").font(.caption)
            }
            Text("相交范围按列表主轴计算。祖先裁剪与窗口遮挡需结合截图判断。")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text("本次未取得该列表的 state.layoutInfo").font(.caption).foregroundStyle(.secondary)
        }
        Divider()
    }

    @ViewBuilder
    private func locationDetails(for node: InspectorNode) -> some View {
        Text("\(node.kind) · #\(node.rawID)\(node.label.map { " · " + $0 } ?? "")")
            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        VStack(alignment: .leading, spacing: 5) {
            SectionCaption(text: "源码定位线索")
            HStack(spacing: 7) {
                Image(systemName: "doc.text").foregroundStyle(.secondary)
                Text(store.sourceSummary)
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                Spacer(minLength: 0)
            }.padding(8).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func layoutBounds(for node: InspectorNode) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionCaption(text: node.isVirtualLayoutGroup ? "组合范围 · 屏幕像素" : "布局 · 屏幕像素")
            HStack {
                Text("x \(Int(node.bounds.minX))  y \(Int(node.bounds.minY))")
                Spacer()
                Text("\(Int(node.bounds.width)) × \(Int(node.bounds.height))")
            }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func parameterGroups(for node: InspectorNode) -> some View {
        let visibleParameters = node.selectableParameters.filter {
            $0.hasDisplayContent || store.selectedParameters.contains($0.id)
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
                        Text(group == .attribute ? "附加信息" : group.rawValue).font(.system(size: 11, weight: .medium))
                        Text("\(parameters.count)").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func parameterRow(_ parameter: NodeParameter) -> some View {
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
                .help(parameter.value + (parameter.isTruncated ? "（SDK 已截断）" : ""))
            if parameter.original != nil {
                Button { store.showRawJSON(parameter: parameter) } label: { Image(systemName: "curlybraces") }
                    .buttonStyle(.plain).help("查看参数原始 JSON")
            }
        }.padding(.vertical, 6).overlay(alignment: .bottom) { Divider().opacity(0.4) }
    }
}

private struct BoxPreview: View {
    let style: ComponentStyle

    private func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption(text: "框预览")
            StyleLayerCanvas(style: style).frame(height: 170)
                .overlay { Rectangle().stroke(.secondary.opacity(0.25), lineWidth: 1) }
                .accessibilityLabel("当前组件的独立背景与内边距预览")
                .help("棋盘格表示透明。预览仅绘制当前组件的背景、裁剪和内边距。")
            Text("外框 \(number(style.selectionBounds.width / style.density)) × \(number(style.selectionBounds.height / style.density)) dp")
            if style.selectionBounds != style.outerBounds {
                Text("布局占位 \(number(style.outerBounds.width / style.density)) × \(number(style.outerBounds.height / style.density)) dp")
                    .foregroundStyle(.secondary)
            }
            Text("内容 \(number(style.contentBounds.width / style.density)) × \(number(style.contentBounds.height / style.density)) dp")
                .foregroundStyle(.secondary)
            if style.layers.contains(where: { $0.padding != nil }) {
                PaddingBoxDiagram(insets: style.totalPadding, title: "Padding 合计 · dp")
            }
        }.font(.system(size: 10, design: .monospaced))
    }
}

private struct ComponentStylePreview: View {
    let node: InspectorNode
    let ancestors: [InspectorNode]
    let snapshotID: UUID
    let screenshot: NSImage?
    @State private var showingLayers = false
    @FocusState private var previewFocused: Bool
    var includeInternalStyles = true

    private var internalStyles: [InspectorNode] {
        guard includeInternalStyles, node.isClickable else { return [] }
        var result: [InspectorNode] = []
        var seen = Set<String>()
        if let identity = node.clickTargetID { seen.insert(identity) }
        var pending = Array(node.children.reversed())
        while let child = pending.popLast() {
            // Independent actions own their visuals; inspect them by selecting that action.
            if child.isClickable && (child.clickTargetID == nil || child.clickTargetID != node.clickTargetID) { continue }
            let identity = child.clickTargetID ?? child.id
            if let style = child.style,
               style.layers.contains(where: { $0.kind == "background" || $0.kind == "clip" }),
               seen.insert(identity).inserted {
                result.append(child)
            }
            pending.append(contentsOf: child.children.reversed())
        }
        return result
    }
    private var relatedShape: (InspectorNode, ComponentStyle, ComponentStyle.Layer)? {
        for ancestor in ancestors.reversed() {
            guard let style = ancestor.style, style.contentBounds == node.bounds else { continue }
            for kind in ["clip", "background"] {
                if let layer = style.layers.first(where: { $0.kind == kind && $0.bounds == node.bounds && ["rounded", "cut"].contains($0.shape?.kind ?? "") }) {
                    return (ancestor, style, layer)
                }
            }
        }
        return nil
    }
    private func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...1))) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionCaption(text: includeInternalStyles ? "当前组件 · 自身样式" : "内部组件 · 自身样式")
                Spacer()
                IconButton(title: "立体样式预览", systemImage: "square.3.layers.3d") { showingLayers = true }
                    .focused($previewFocused)
                    .disabled(node.style?.layers.isEmpty != false)
            }
            .background {
                if let style = node.style, !style.layers.isEmpty {
                    StylePreviewSheet(isPresented: $showingLayers, onDismiss: { previewFocused = true }) {
                        ExplodedStylePreview(name: node.shortName, style: style, screenshot: screenshot,
                                             bounds: node.bounds, dismiss: { showingLayers = false })
                    }
                }
            }
            .onChange(of: snapshotID) { showingLayers = false }
            .onChange(of: node.id) { showingLayers = false }
            if node.style == nil { Text("未取得组件样式").foregroundStyle(.secondary) }
            if includeInternalStyles && node.isClickable {
                Text("点击布局范围 · x \(number(node.bounds.minX)) y \(number(node.bounds.minY)) · \(number(node.bounds.width)) × \(number(node.bounds.height)) px")
                    .foregroundStyle(.secondary)
            }
            if let style = node.style {
                if !includeInternalStyles {
                    BoxPreview(style: style)
                }
                if style.layers.isEmpty {
                    Text("未采集到外观层")
                        .foregroundStyle(.secondary)
                }
                ForEach(style.layers) { layer in
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
                                    } else if ["rounded", "cut"].contains(shape.kind) {
                                        CornerRadiiDiagram(shape: shape, density: style.density, bounds: layer.bounds)
                                    } else { Text("矩形").foregroundStyle(.secondary) }
                                }
                                if let unsupported = layer.unsupported { Text(unsupported).foregroundStyle(.orange).textSelection(.enabled) }
                            }
                        }
                    }.padding(7).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 5))
                }
            } else if node.isVirtualLayoutGroup {
                Text("组合包装节点：选框包含子组件外框；此节点没有独立背景或 padding。")
                    .foregroundStyle(.secondary)
            } else {
                Text("未取得可可靠关联的自身分层样式。")
                    .foregroundStyle(.secondary)
                if let (ancestor, style, layer) = relatedShape, let shape = layer.shape {
                    Text("同边界外层形状参考 · " + ancestor.name).fontWeight(.medium)
                    if let source = ancestor.source { Text(source.text).foregroundStyle(.secondary) }
                    CornerRadiiDiagram(shape: shape, density: style.density, bounds: layer.bounds)
                    Text("以上来自外层组件，不计入当前节点的样式或 padding。")
                        .foregroundStyle(.secondary)
                }
            }
            if !internalStyles.isEmpty {
                Divider()
                SectionCaption(text: "内部视觉样式 · 不改变点击范围")
                ForEach(internalStyles) { child in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("归属：" + child.name).fontWeight(.medium)
                        if let source = child.source { Text(source.text).foregroundStyle(.secondary) }
                        Text("位置：x \(number(child.bounds.minX)) y \(number(child.bounds.minY)) · \(number(child.bounds.width)) × \(number(child.bounds.height)) px").foregroundStyle(.secondary)
                        ComponentStylePreview(node: child, ancestors: [], snapshotID: snapshotID, screenshot: screenshot, includeInternalStyles: false)
                    }.padding(8)
                        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }.font(.system(size: 10, design: .monospaced)).fixedSize(horizontal: false, vertical: true)
    }

}

func styleColor(_ hex: String) -> Color? {
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
struct PaddingBoxDiagram: View {
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

struct CornerRadiiDiagram: View {
    let shape: ComponentStyle.Shape
    let density: Double
    let bounds: CGRect
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(shape.title(in: bounds)) · 实际 dp").foregroundStyle(.secondary)
            Grid(horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    corner("左上", key: "topLeft", value: shape.topLeft, rotation: 0)
                    corner("右上", key: "topRight", value: shape.topRight, rotation: 90)
                }
                GridRow {
                    corner("左下", key: "bottomLeft", value: shape.bottomLeft, rotation: 270)
                    corner("右下", key: "bottomRight", value: shape.bottomRight, rotation: 180)
                }
            }
        }
    }
    private func corner(_ name: String, key: String, value: Double, rotation: Double) -> some View {
        let text = (value / density).formatted(.number.precision(.fractionLength(0...1)))
        return HStack(spacing: 5) {
            CornerRadiusGlyph(cut: shape.kind == "cut").stroke(.secondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .frame(width: 13, height: 13).rotationEffect(.degrees(rotation))
            VStack(alignment: .leading, spacing: 2) {
                Text(text).monospacedDigit()
                if let input = shape.corners?[key] { Text("配置 " + input.label).foregroundStyle(.secondary) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore).accessibilityLabel("\(name)\(shape.kind == "cut" ? "切角" : "圆角") \(text) dp \(shape.corners?[key].map { "配置 " + $0.label } ?? "")")
            .help("\(name)圆角")
    }
}

private struct CornerRadiusGlyph: Shape {
    var cut = false
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.15, y: rect.minY + rect.height * 0.9))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.15, y: rect.minY + rect.height * 0.6))
        if cut { path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.6, y: rect.minY + rect.height * 0.15)) }
        else { path.addQuadCurve(to: CGPoint(x: rect.minX + rect.width * 0.6, y: rect.minY + rect.height * 0.15),
                         control: CGPoint(x: rect.minX + rect.width * 0.15, y: rect.minY + rect.height * 0.15)) }
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.9, y: rect.minY + rect.height * 0.15))
        return path
    }
}

private struct ParameterColorSwatch: View {
    let argb: String
    var alpha: Double = 1
    var side: CGFloat = 16
    var body: some View {
        Canvas { context, size in
            let tile = size.width / 4
            for row in 0..<4 {
                for column in 0..<4 {
                    context.fill(Path(CGRect(x: CGFloat(column) * tile, y: CGFloat(row) * tile, width: tile, height: tile)),
                        with: .color((row + column) % 2 == 0 ? .white : Color(white: 0.65)))
                }
            }
            if let color = styleColor(argb) {
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color.opacity(alpha)))
            }
        }.frame(width: side, height: side).clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary.opacity(0.5), lineWidth: 0.5) }
            .help("#\(argb) · 棋盘格表示透明")
            .accessibilityLabel("颜色预览 #\(argb)")
    }
}

private struct PrimaryAttributes: View {
    let node: InspectorNode
    let showStyle: () -> Void

    private var isSurface: Bool {
        node.shortName.hasSuffix("Button") || node.shortName.hasSuffix("Card")
            || node.shortName.hasSuffix("CardView") || node.shortName == "Surface"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let text = TextComponentPreview(node: node) {
                if let content = text.content {
                    Text(verbatim: content.isEmpty ? "（空文本）" : content)
                        .font(.system(size: 16, weight: .medium)).lineLimit(4).help(content)
                }
                if text.fontSize != nil || text.fontWeight != nil {
                    HStack(spacing: 6) {
                        if let size = text.fontSize, let unit = text.fontUnit { field("字号", number(size) + " " + unit) }
                        if let weight = text.fontWeight { field("字重", String(weight)) }
                    }
                }
                if let color = text.colorARGB { colorField("文字颜色", color) }
            } else if !node.isVirtualLayoutGroup {
                if isSurface { surface } else { layout }
            }
        }.font(.callout).textSelection(.enabled)
    }

    @ViewBuilder private var layout: some View {
        let style = node.style
        let bounds = style?.outerBounds ?? node.bounds
        let density = style?.density ?? 1
        let unit = style == nil ? " px" : " dp"
        field("尺寸", number(bounds.width / density) + " × " + number(bounds.height / density) + unit)
        if let style, style.layers.contains(where: { $0.padding != nil }) {
            field("内边距", padding(style.totalPadding, unit: " dp"))
        }
    }

    @ViewBuilder private var surface: some View {
        let backgrounds = node.style?.layers.filter { $0.kind == "background" } ?? []
        if backgrounds.count > 1 {
            attributeTile("背景") {
                Button("\(backgrounds.count) 层背景") { showStyle() }.buttonStyle(.link)
            }
        } else if let layer = backgrounds.first, let argb = layer.argb, styleColor(argb) != nil {
            colorField("背景色", argb, alpha: layer.alpha)
        }
        if isSurface, node.style == nil, node.kind == "ComposeNode",
           let color = node.parameters.first(where: { $0.group == .parameter && ["containerColor", "backgroundColor"].contains($0.name) && $0.colorARGB != nil })?.colorARGB {
            colorField("背景色（参数）", color)
        }
        if let style = node.style {
            let clips = style.layers.filter { $0.kind == "clip" }
            let layers = clips.isEmpty ? backgrounds : clips
            if let shape = layers.first?.shape, shape.kind == "rounded",
               layers.allSatisfy({ $0.shape == shape }) {
                let radii = [shape.topLeft, shape.topRight, shape.bottomRight, shape.bottomLeft].map { number($0 / style.density) }
                if radii.allSatisfy({ $0 == radii[0] }) {
                    field("圆角", radii[0] + " dp")
                } else {
                    field("圆角", "左上 " + radii[0] + " · 右上 " + radii[1] + "\n右下 " + radii[2] + " · 左下 " + radii[3] + " dp")
                }
            }
        }
    }

    private func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...2))) }

    private func padding(_ inset: ComponentStyle.Insets, unit: String) -> String {
        if inset.left == inset.right && inset.top == inset.bottom {
            if inset.left == inset.top { return number(inset.left) + unit }
            return "水平 " + number(inset.left) + " · 垂直 " + number(inset.top) + unit
        }
        return "左 " + number(inset.left) + " · 右 " + number(inset.right) + "\n上 " + number(inset.top) + " · 下 " + number(inset.bottom) + unit
    }

    private func attributeTile(_ label: String, swatch: ParameterColorSwatch? = nil, @ViewBuilder value: () -> some View) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                value()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            swatch
        }
        .padding(9)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
    }

    private func field(_ label: String, _ value: String) -> some View {
        attributeTile(label) {
            Text(verbatim: value).font(.system(size: 14, weight: .medium)).monospacedDigit()
        }
    }

    private func colorField(_ label: String, _ argb: String, alpha: Double = 1) -> some View {
        attributeTile(label, swatch: ParameterColorSwatch(argb: argb, alpha: alpha, side: 22)) {
            HStack(spacing: 6) {
                Text(verbatim: "#" + (argb.hasPrefix("FF") ? String(argb.dropFirst(2)) : argb))
                if alpha != 1 { Text(verbatim: "× " + alpha.formatted(.percent)) }
            }.font(.system(.body, design: .monospaced))
        }
    }
}

private struct TextComponentPreviewView: View {
    let content: String
    let preview: TextComponentPreview
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption(text: "文本预览")
            Text(verbatim: content.isEmpty ? "（空文本）" : content)
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
        }
    }
}
