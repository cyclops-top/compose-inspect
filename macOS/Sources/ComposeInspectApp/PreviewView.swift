import ComposeInspectCore
import AppKit
import SwiftUI

struct PreviewView: View {
    @Bindable var store: WorkspaceStore
    @GestureState private var dragTranslation: CGSize = .zero
    private var imagePan: CGSize {
        CGSize(width: store.imagePan.width + dragTranslation.width, height: store.imagePan.height + dragTranslation.height)
    }
    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let mapper = CoordinateMapper(imageSize: store.snapshot.pixelSize, canvasSize: geometry.size, zoom: store.zoom, pan: imagePan)
                ZStack(alignment: .topLeading) {
                    AppStyle.canvas
                    if let image = store.image {
                        Image(nsImage: image).resizable().interpolation(.high)
                            .frame(width: store.snapshot.pixelSize.width * mapper.scale,
                                   height: store.snapshot.pixelSize.height * mapper.scale)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                            .position(x: geometry.size.width / 2 + imagePan.width, y: geometry.size.height / 2 + imagePan.height)
                            .accessibilityLabel("\(store.snapshot.packageName) 的界面截图")
                        if store.canPickImage && store.showWireframes {
                            ComponentWireframes(snapshotID: store.snapshot.id, rootID: store.visibleRoot?.id,
                                                hidingInternals: store.hideInternalNodes, onlyClickable: store.onlyClickableNodes,
                                                presentationRevision: store.presentationRevision,
                                                nodes: store.visibleNodes, imageSize: store.snapshot.pixelSize,
                                                canvasSize: geometry.size, zoom: store.zoom, pan: imagePan)
                                .equatable().allowsHitTesting(false)
                        }
                        Canvas { context, _ in
                            if store.canPickImage, let node = store.highlightedNode,
                               store.isInVisibleWindow(node.id) {
                                let rect = mapper.display(node.bounds)
                                let outline = ComponentStyleDrawing.path(in: rect,
                                    shape: ComponentStyleDrawing.outlineShape(style: node.style, bounds: node.bounds), scale: mapper.scale)
                                context.fill(outline, with: .color(.accentColor.opacity(0.08)))
                                context.stroke(outline, with: .color(.accentColor), lineWidth: 1.5)
                                for point in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                                              CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)] {
                                    let handle = CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)
                                    context.fill(Path(handle), with: .color(.white))
                                    context.stroke(Path(handle), with: .color(.accentColor), lineWidth: 1)
                                }
                            }
                        }.allowsHitTesting(false)
                        if store.canPickImage, let node = store.highlightedNode, store.isInVisibleWindow(node.id), !node.bounds.isEmpty {
                            let rect = mapper.display(node.bounds)
                            Text("\(node.shortName) · #\(node.rawID)")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .foregroundStyle(.white).background(Color.accentColor, in: RoundedRectangle(cornerRadius: 3))
                                .position(x: min(max(rect.minX + 50, 55), geometry.size.width - 55),
                                          y: max(12, rect.minY - 12))
                                .allowsHitTesting(false)
                        }
                    } else {
                        EmptyState(icon: "camera", title: "尚未获取界面", subtitle: "选择设备和应用，点击右上角相机。")
                    }
                }
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { event in
                    store.selectImage(at: event.location, mapper: mapper)
                })
                .simultaneousGesture(DragGesture(minimumDistance: 3)
                    .updating($dragTranslation) { value, translation, _ in
                        if !store.selectionEnabled, store.image != nil { translation = value.translation }
                    }
                    .onEnded { value in
                        guard !store.selectionEnabled, store.image != nil else { return }
                        store.imagePan.width += value.translation.width
                        store.imagePan.height += value.translation.height
                    })
                .clipped()
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 16)
            .background(AppStyle.canvas)
            .overlay(alignment: .bottomTrailing) { floatingTools.padding(12) }
            .overlay(alignment: .bottomLeading) {
                if store.hitCandidates.count > 1 {
                    Menu {
                        ForEach(store.hitCandidates, id: \.self) { id in
                            if let node = store.presentationIndex.byID[id] {
                                Button(node.displayName) { store.select(id) }
                            }
                        }
                    } label: { Text("\(store.hitCandidates.count) 个候选") }
                        .menuStyle(.borderlessButton).font(.system(size: 10)).fixedSize()
                        .padding(7).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6)).padding(12)
                }
            }
            .overlay(alignment: .topLeading) {
                if store.snapshot.roots.count > 1 {
                    Menu {
                        ForEach(Array(store.snapshot.roots.enumerated()), id: \.element.id) { index, root in
                            Button("窗口 \(index + 1) · \(root.shortName)") { store.windowRootID = root.id; store.hitCandidates = [] }
                        }
                    } label: { Label("选择窗口", systemImage: "macwindow.on.rectangle") }
                    .fixedSize().font(.system(size: 11)).padding(10)
                }
            }
            breadcrumb
        }
    }

    private var floatingTools: some View {
        VStack(spacing: 10) {
            toolGroup {
                VerticalZoomSlider(value: $store.zoom, enabled: store.image != nil)
                    .frame(width: 24, height: 110)
                    .help("缩放 \(Int(store.zoom * 100))%")
                toolButton("适合窗口", icon: "arrow.up.left.and.arrow.down.right") {
                    store.fitImage()
                }.disabled(store.image == nil)
            }
            toolGroup {
                toolButton("拖拽", icon: "hand.draw", active: !store.selectionEnabled) {
                    store.selectionEnabled = false
                }.disabled(store.image == nil)
                toolButton("选择", icon: "cursorarrow", active: store.selectionEnabled) {
                    store.selectionEnabled = true
                }.disabled(!store.canPickImage)
            }
            toolGroup {
                toolButton("线框", icon: "square.dashed", active: store.showWireframes) {
                    store.showWireframes.toggle()
                }.disabled(!store.canPickImage)
            }
        }
    }

    private func toolGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 5, content: content)
            .frame(width: 30).padding(6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }

    private func toolButton(_ title: String, icon: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .frame(width: 30, height: 30)
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .background(active ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain).help(title).accessibilityLabel(title)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                if store.path.isEmpty { Text("点击截图或组件树选择组件").foregroundStyle(.secondary) }
                ForEach(Array(store.path.enumerated()), id: \.element.id) { index, node in
                    if index > 0 { Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.tertiary) }
                    Button(node.shortName) { store.select(node.id) }
                        .buttonStyle(.plain).foregroundStyle(node.id == store.selectedNodeID ? .primary : .secondary)
                }
            }.font(.system(size: 10)).padding(.horizontal, 12).frame(height: 29)
        }.background(AppStyle.background).overlay(alignment: .top) { Divider() }
    }
}

/// NSSlider chooses its vertical orientation from its initial tall frame.
private struct VerticalZoomSlider: NSViewRepresentable {
    @Binding var value: CGFloat
    let enabled: Bool

    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }
    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(frame: NSRect(x: 0, y: 0, width: 24, height: 110))
        slider.sliderType = .linear
        slider.minValue = 0.5
        slider.maxValue = 4
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.setAccessibilityLabel("缩放")
        return slider
    }
    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.value = $value
        slider.doubleValue = Double(value)
        slider.isEnabled = enabled
        slider.setAccessibilityValueDescription("\(Int(value * 100))%")
    }
    @MainActor final class Coordinator: NSObject {
        var value: Binding<CGFloat>
        init(value: Binding<CGFloat>) { self.value = value }
        @objc func changed(_ sender: NSSlider) { value.wrappedValue = CGFloat(sender.doubleValue) }
    }
}

/// Static bounds have no dependency on selection or parameter data. Selecting a row updates only
/// the lightweight highlight above this layer, not every rectangle on the screen.
private struct ComponentWireframes: View, Equatable {
    let snapshotID: UUID
    let rootID: String?
    let hidingInternals: Bool
    let onlyClickable: Bool
    let presentationRevision: UInt
    let nodes: [InspectorNode]
    let imageSize: CGSize
    let canvasSize: CGSize
    let zoom: Double
    let pan: CGSize

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.snapshotID == rhs.snapshotID && lhs.rootID == rhs.rootID && lhs.hidingInternals == rhs.hidingInternals && lhs.onlyClickable == rhs.onlyClickable && lhs.presentationRevision == rhs.presentationRevision && lhs.imageSize == rhs.imageSize
            && lhs.canvasSize == rhs.canvasSize && lhs.zoom == rhs.zoom && lhs.pan == rhs.pan
    }

    var body: some View {
        let mapper = CoordinateMapper(imageSize: imageSize, canvasSize: canvasSize, zoom: zoom, pan: pan)
        var seen: Set<[CGFloat]> = []
        let outlines = nodes.filter { node in
            guard !node.bounds.isEmpty else { return false }
            let shape = ComponentStyleDrawing.outlineShape(style: node.style, bounds: node.bounds)
            let radii: [CGFloat]
            if let shape, shape.kind == "rounded" {
                radii = [shape.topLeft, shape.topRight, shape.bottomLeft, shape.bottomRight].map { CGFloat($0) }
            } else { radii = [0, 0, 0, 0] }
            return seen.insert([node.bounds.minX, node.bounds.minY, node.bounds.width, node.bounds.height] + radii).inserted
        }
        let path = Path { path in
            for node in outlines {
                path.addPath(ComponentStyleDrawing.path(in: mapper.display(node.bounds),
                    shape: ComponentStyleDrawing.outlineShape(style: node.style, bounds: node.bounds), scale: mapper.scale))
            }
        }
        let corners = Path { path in
            for node in outlines {
                // Right-angle corner marks would obscure a measured rounded outline.
                guard ComponentStyleDrawing.outlineShape(style: node.style, bounds: node.bounds)?.kind != "rounded" else { continue }
                let rect = mapper.display(node.bounds)
                let length = min(3, rect.width / 2, rect.height / 2)
                for (x, dx) in [(rect.minX, length), (rect.maxX, -length)] {
                    for (y, dy) in [(rect.minY, length), (rect.maxY, -length)] {
                        path.move(to: CGPoint(x: x + dx, y: y))
                        path.addLine(to: CGPoint(x: x, y: y))
                        path.addLine(to: CGPoint(x: x, y: y + dy))
                    }
                }
            }
        }
        Canvas { context, _ in
            // Screenshot colors are independent of the Mac appearance. A contrasting
            // underlay keeps boundaries visible on both light and dark Android UIs.
            context.clip(to: Path(mapper.display(CGRect(origin: .zero, size: imageSize))))
            context.stroke(path, with: .color(.black.opacity(0.2)), lineWidth: 0.9)
            context.stroke(path, with: .color(Color(red: 0.2, green: 0.5, blue: 1).opacity(0.75)), lineWidth: 0.5)
            context.stroke(corners, with: .color(.red.opacity(0.8)), lineWidth: 0.6)
        }
    }
}
