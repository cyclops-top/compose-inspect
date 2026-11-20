import ComposeInspectCore
import AppKit
import SwiftUI

struct PreviewView: View {
    @Bindable var store: WorkspaceStore
    @GestureState private var pinch: MagnifyGesture.Value?
    private static let zoomRange: ClosedRange<CGFloat> = 0.5...4
    @State private var dragOrigin: CGSize?
    @State private var spaceHeld = false
    private var pickingColor: Bool { store.pickingColor }
    @State private var bitmap: ScreenshotPixels?
    @State private var copiedColor: String?
    @State private var copyCount = 0
    @AppStorage("colorLoupeMagnification") private var magnification = LoupeMagnification.x12
    @State private var cursorPixel: CGPoint?
    @State private var loupeCursor: NSCursor?
    private var panning: Bool { spaceHeld || (!pickingColor && !store.selectionEnabled) || dragOrigin != nil }
    @State private var canvasSize: CGSize = .zero
    @State private var hoverPoint: CGPoint?
    @State private var commandHeld = false
    @State private var inputMonitor: Any?
    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let viewport = pinchedViewport(pinch, in: geometry.size)
                let mapper = CoordinateMapper(imageSize: store.snapshot.pixelSize, canvasSize: geometry.size, zoom: viewport.zoom, pan: viewport.pan)
                let hovered = !pickingColor && !panning && store.canPickImage ? hoverPoint.flatMap {
                    mapper.candidates(at: $0, in: store.presentationIndex, imageSize: store.snapshot.pixelSize,
                                      rootID: store.visibleRoot?.id).first
                } : nil
                let measurement = measurement(to: hovered)
                ZStack(alignment: .topLeading) {
                    AppStyle.canvas
                    if let image = store.image {
                        Image(nsImage: image).resizable().interpolation(pickingColor ? .none : .high)
                            .frame(width: store.snapshot.pixelSize.width * mapper.scale,
                                   height: store.snapshot.pixelSize.height * mapper.scale)
                            .clipShape(RoundedRectangle(cornerRadius: pickingColor ? 0 : 9))
                            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                            .position(x: geometry.size.width / 2 + viewport.pan.width, y: geometry.size.height / 2 + viewport.pan.height)
                            .accessibilityLabel("\(store.snapshot.packageName) 的界面截图")
                        if !pickingColor {
                            if store.canPickImage && store.showWireframes {
                                ComponentWireframes(snapshotID: store.snapshot.id, rootID: store.visibleRoot?.id,
                                                    hidingInternals: store.hideInternalNodes, onlyClickable: store.onlyClickableNodes,
                                                    presentationRevision: store.presentationRevision,
                                                    nodes: store.visibleNodes, imageSize: store.snapshot.pixelSize,
                                                    canvasSize: geometry.size, zoom: viewport.zoom, pan: viewport.pan)
                                    .equatable().allowsHitTesting(false)
                            }
                            Canvas { context, size in
                                if let hovered, hovered.id != store.selectedNodeID {
                                    context.stroke(Path(mapper.display(hovered.bounds)), with: .color(.orange),
                                                   style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                                }
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
                                measurement?.draw(in: context, size: size, mapper: mapper)
                            }.allowsHitTesting(false)
                            if !commandHeld, store.canPickImage, let node = store.highlightedNode,
                               store.isInVisibleWindow(node.id), !node.bounds.isEmpty {
                                let rect = mapper.display(node.bounds)
                                Text("\(node.shortName) · #\(node.rawID)")
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .foregroundStyle(.white).background(Color.accentColor, in: RoundedRectangle(cornerRadius: 3))
                                    .position(x: min(max(rect.minX + 50, 55), geometry.size.width - 55),
                                              y: max(12, rect.minY - 12))
                                    .allowsHitTesting(false)
                            }
                            if measurement == nil, let hovered, let point = hoverPoint, hovered.id != store.selectedNodeID {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(hovered.displayName).fontWeight(.medium)
                                    Text(LocatorTextBuilder.sourceSummary(for: hovered.id, index: store.snapshotIndex))
                                        .foregroundStyle(.secondary)
                                }.font(.system(size: 10)).lineLimit(2).padding(6)
                                    .frame(width: min(240, geometry.size.width - 12), alignment: .leading)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                                    .position(x: min(max(point.x, 126), max(126, geometry.size.width - 126)),
                                              y: min(max(point.y + 40, 30), geometry.size.height - 30))
                                    .allowsHitTesting(false)
                            }
                        }
                    } else {
                        EmptyState(icon: "camera", title: "尚未获取界面", subtitle: "选择设备和应用，点击右上角相机。")
                    }
                }
                .contentShape(Rectangle())
                .onChange(of: geometry.size, initial: true) { _, size in canvasSize = size }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        hoverPoint = point
                        updateLoupe(at: point, mapper: mapper)
                        if panning || pickingColor { updateCursor() }
                        commandHeld = NSApp.isActive && NSEvent.modifierFlags.contains(.command)
                    case .ended:
                        hoverPoint = nil
                        if panning || pickingColor { NSCursor.arrow.set() }
                    }
                }
                .onChange(of: viewport.pan) { _, _ in
                    if pickingColor, let hoverPoint {
                        updateLoupe(at: hoverPoint, mapper: mapper)
                        updateCursor()
                    }
                }
                .onChange(of: store.snapshot.id) { _, _ in hoverPoint = nil }
                .onChange(of: store.presentationRevision) { _, _ in hoverPoint = nil }
                .gesture(SpatialTapGesture().onEnded { event in
                    guard !spaceHeld, dragOrigin == nil else { return }
                    if pickingColor {
                        if let hex = sample(at: event.location, mapper: mapper),
                           store.copy(hex, successNotice: "已复制 " + hex) {
                            copiedColor = hex
                            copyCount += 1
                        }
                    } else {
                        store.selectImage(at: event.location, mapper: mapper)
                    }
                })
                .simultaneousGesture(MagnifyGesture()
                    .updating($pinch) { value, state, _ in state = value }
                    .onEnded { value in
                        let viewport = pinchedViewport(value, in: geometry.size)
                        store.zoom = viewport.zoom
                        store.imagePan = viewport.pan
                    })
                .simultaneousGesture(DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        guard panning, store.image != nil else { return }
                        let origin = dragOrigin ?? store.imagePan
                        dragOrigin = origin
                        store.imagePan = CGSize(width: origin.width + value.translation.width,
                                                height: origin.height + value.translation.height)
                        updateCursor()
                    }
                    .onEnded { _ in
                        dragOrigin = nil
                        updateCursor()
                    })
                .clipped()
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 16)
            .background(AppStyle.canvas)
            .allowsHitTesting(!store.isCapturing)
            .overlay(alignment: .bottomTrailing) {
                floatingTools.padding(12)
            }
            .overlay(alignment: .bottomLeading) {
                if !pickingColor && store.hitCandidates.count > 1 {
                    HStack(spacing: 6) {
                        Button { store.cycleHitCandidate(-1) } label: { Image(systemName: "chevron.left") }
                            .help("上一个重叠组件（⌘⌥[）").accessibilityLabel("上一个重叠组件")
                        Menu {
                            ForEach(store.hitCandidates, id: \.self) { id in
                                if let node = store.presentationIndex.byID[id] {
                                    Button {
                                        store.selectHitCandidate(id)
                                    } label: {
                                        Text((id == store.selectedNodeID ? "✓ " : "") + node.displayName)
                                        Text(LocatorTextBuilder.sourceSummary(for: id, index: store.snapshotIndex))
                                    }
                                }
                            }
                        } label: {
                            Text("\((store.selectedNodeID.flatMap { store.hitCandidates.firstIndex(of: $0) } ?? 0) + 1)/\(store.hitCandidates.count) 重叠组件")
                        }.menuStyle(.borderlessButton).fixedSize()
                        Button { store.cycleHitCandidate(1) } label: { Image(systemName: "chevron.right") }
                            .help("下一个重叠组件（⌘⌥]）").accessibilityLabel("下一个重叠组件")
                    }.buttonStyle(.plain).font(.system(size: 10))
                        .padding(7).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6)).padding(12)
                }
            }
            .overlay(alignment: .topLeading) {
                if !pickingColor && store.snapshot.roots.count > 1 {
                    Menu {
                        ForEach(Array(store.snapshot.roots.enumerated()), id: \.element.id) { index, root in
                            Button("窗口 \(index + 1) · \(root.shortName)") { store.windowRootID = root.id; store.hitCandidates = [] }
                        }
                    } label: { Label("选择窗口", systemImage: "macwindow.on.rectangle") }
                    .fixedSize().font(.system(size: 11)).padding(10)
                }
            }
            .overlay(alignment: .top) {
                if pickingColor, let copiedColor {
                    Label("已复制 " + copiedColor, systemImage: "checkmark")
                        .font(.caption.monospaced()).padding(7)
                        .background(.regularMaterial, in: Capsule()).padding(8)
                        .allowsHitTesting(false)
                }
            }
            .task(id: copyCount) {
                guard copiedColor != nil else { return }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                copiedColor = nil
            }
            .disabled(store.isCapturing)
            .overlay {
                if store.isCapturing {
                    ZStack {
                        Color.black.opacity(0.26)
                        ProgressView {
                            Text(store.captureProgressText)
                                .font(.callout)
                                .multilineTextAlignment(.center)
                        }
                        .padding(18)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .padding()
                    }
                    .contentShape(Rectangle())
                }
            }
            HStack(spacing: 8) {
                breadcrumb
                if pickingColor {
                    Picker("倍率", selection: $magnification) {
                        ForEach(LoupeMagnification.allCases, id: \.self) { value in
                            Text("\(value.rawValue)×").tag(value)
                        }
                    }
                    .pickerStyle(.menu).controlSize(.small).fixedSize()
                    .accessibilityLabel("取色放大倍率").padding(.trailing, 12)
                }
            }
        }
        .onChange(of: magnification) { _, value in
            if pickingColor, let bitmap, let cursorPixel {
                loupeCursor = bitmap.cursor(for: cursorPixel, magnification: value)
                updateCursor()
            }
        }
        .onChange(of: pickingColor) { _, active in
            if !active {
                bitmap = nil
                copiedColor = nil
                cursorPixel = nil
                loupeCursor = nil
                updateCursor()
            }
        }
        .onChange(of: store.image) { _, _ in
            if pickingColor { prepareBitmap() }
        }
        .onAppear {
            guard inputMonitor == nil else { return }
            inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp, .scrollWheel, .smartMagnify]) { event in
                let consumed = MainActor.assumeIsolated {
                    if event.type == .smartMagnify {
                        guard event.window?.isKeyWindow == true, let hoverPoint,
                              store.image != nil, !store.isCapturing, dragOrigin == nil, pinch == nil else { return false }
                        if store.zoom > 1 {
                            store.fitImage()
                        } else {
                            let viewport = zoomedViewport(to: 2, at: hoverPoint, in: canvasSize)
                            store.zoom = viewport.zoom
                            store.imagePan = viewport.pan
                        }
                        return true
                    }
                    if event.type == .scrollWheel {
                        guard event.hasPreciseScrollingDeltas, event.window?.isKeyWindow == true,
                              hoverPoint != nil, store.image != nil, !store.isCapturing,
                              dragOrigin == nil, pinch == nil else { return false }
                        store.imagePan = CGSize(width: store.imagePan.width + event.scrollingDeltaX,
                                                height: store.imagePan.height + event.scrollingDeltaY)
                        return true
                    }
                    if event.type == .flagsChanged {
                        commandHeld = event.modifierFlags.contains(.command)
                    } else if event.keyCode == 49 {
                        if event.type == .keyUp && spaceHeld {
                            spaceHeld = false
                            updateCursor()
                            return true
                        }
                        if event.type == .keyDown, !store.isCapturing, hoverPoint != nil, store.image != nil,
                           event.window?.isKeyWindow == true, !(event.window?.firstResponder is NSTextView),
                           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                            spaceHeld = true
                            updateCursor()
                            return true
                        }
                    }
                    return false
                }
                return consumed ? nil : event
            }
        }
        .onDisappear {
            if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
            inputMonitor = nil
            clearMeasurementHover()
            store.pickingColor = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            clearMeasurementHover()
        }
    }

    private func prepareBitmap() {
        copiedColor = nil
        cursorPixel = nil
        loupeCursor = nil
        bitmap = store.image?.cgImage(forProposedRect: nil, context: nil, hints: nil).flatMap(ScreenshotPixels.init)
        store.pickingColor = bitmap != nil
    }

    private func sample(at point: CGPoint, mapper: CoordinateMapper) -> String? {
        bitmap?.hex(at: mapper.imagePoint(point), imageSize: store.snapshot.pixelSize)
    }

    private func updateLoupe(at point: CGPoint, mapper: CoordinateMapper) {
        guard pickingColor, let bitmap else { return }
        let pixel = bitmap.pixel(at: mapper.imagePoint(point), imageSize: store.snapshot.pixelSize)
        if pixel != cursorPixel {
            cursorPixel = pixel
            loupeCursor = pixel.map { bitmap.cursor(for: $0, magnification: magnification) }
        }
    }

    private func updateCursor() {
        guard hoverPoint != nil else { return }
        (dragOrigin != nil ? NSCursor.closedHand : panning ? NSCursor.openHand : pickingColor ? (loupeCursor ?? NSCursor.arrow) : NSCursor.arrow).set()
    }

    private func clearMeasurementHover() {
        if (panning || pickingColor) && hoverPoint != nil { NSCursor.arrow.set() }
        spaceHeld = false
        dragOrigin = nil
        commandHeld = false
        hoverPoint = nil
    }

    private func measurement(to hovered: InspectorNode?) -> ComponentMeasurement? {
        guard commandHeld, let hovered, let selected = store.highlightedNode, selected.id != hovered.id,
              store.isInVisibleWindow(selected.id), store.isInVisibleWindow(hovered.id) else { return nil }
        return ComponentMeasurement(from: selected.bounds, to: hovered.bounds,
                                    selectedDensity: selected.style?.density, hoveredDensity: hovered.style?.density)
    }

    private func pinchedViewport(_ gesture: MagnifyGesture.Value?, in size: CGSize) -> (zoom: CGFloat, pan: CGSize) {
        guard let gesture, store.image != nil else { return (store.zoom, store.imagePan) }
        let zoom = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, store.zoom * gesture.magnification))
        let anchor = CGPoint(x: gesture.startAnchor.x * size.width, y: gesture.startAnchor.y * size.height)
        return zoomedViewport(to: zoom, at: anchor, in: size)
    }

    private func zoomedViewport(to zoom: CGFloat, at point: CGPoint, in size: CGSize) -> (zoom: CGFloat, pan: CGSize) {
        let pan = store.imagePan
        let ratio = zoom / store.zoom
        // Keep the image pixel under the gesture anchor fixed as the screenshot scales.
        let x = point.x - size.width / 2
        let y = point.y - size.height / 2
        return (zoom, CGSize(width: x + (pan.width - x) * ratio, height: y + (pan.height - y) * ratio))
    }

    private var floatingTools: some View {
        HStack(spacing: 4) {
            toolGroup {
                toolButton("缩小", icon: "minus.magnifyingglass") {
                    store.zoom = max(Self.zoomRange.lowerBound, store.zoom / 1.25)
                }.disabled(store.image == nil || store.zoom <= Self.zoomRange.lowerBound)
                toolButton("放大", icon: "plus.magnifyingglass") {
                    store.zoom = min(Self.zoomRange.upperBound, store.zoom * 1.25)
                }.disabled(store.image == nil || store.zoom >= Self.zoomRange.upperBound)
                toolButton("适合窗口（双指轻点两下切换缩放）", icon: "arrow.up.left.and.arrow.down.right") {
                    store.fitImage()
                }.disabled(store.image == nil)
            }
            toolGroup {
                toolButton("拖拽（空格拖动或触控板双指滑动）", icon: "hand.draw", active: panning) {
                    store.pickingColor = false
                    store.selectionEnabled = false
                }.disabled(store.image == nil)
                toolButton("选择", icon: "cursorarrow", active: !panning && !pickingColor) {
                    store.pickingColor = false
                    store.selectionEnabled = true
                }.disabled(!store.canPickImage)
                toolButton("取色器（点击复制，Esc 退出）", icon: "eyedropper", active: pickingColor) {
                    if pickingColor {
                        store.pickingColor = false
                    } else {
                        prepareBitmap()
                    }
                }.disabled(store.image == nil)
            }
            toolGroup {
                toolButton("选择父组件（⌘⌥↑）", icon: "arrow.up.to.line") {
                    if let id = store.selectedParentID { store.select(id) }
                }.disabled(store.selectedParentID == nil)
                toolButton("线框", icon: "square.dashed", active: store.showWireframes) {
                    store.showWireframes.toggle()
                }.disabled(!store.canPickImage)
            }.disabled(pickingColor)
        }
    }

    private func toolGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 0, content: content)
            .frame(height: 30).padding(4)
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

enum LoupeMagnification: Int, CaseIterable {
    case x6 = 6, x8 = 8, x12 = 12, x16 = 16, x24 = 24
}

struct ScreenshotPixels {
    let image: CGImage
    private let context: CGContext

    init?(_ image: CGImage) {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        self.image = image
        self.context = context
    }

    func cursor(for pixel: CGPoint, magnification: LoupeMagnification) -> NSCursor {
        let diameter: CGFloat = 108
        let pixelSide = CGFloat(magnification.rawValue)
        let span = diameter / pixelSide
        let region = CGRect(x: pixel.x + 0.5 - span / 2, y: pixel.y + 0.5 - span / 2,
                            width: span, height: span)
        let visible = region.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let crop = image.cropping(to: visible)
        let hex = hex(for: pixel)
        let hotSpot = CGPoint(x: 1 + diameter / 2, y: 1 + diameter / 2)
        let size = CGSize(width: diameter + 2, height: diameter + 24)
        let cursorImage = NSImage(size: size, flipped: true) { _ in
            let lens = NSBezierPath(ovalIn: CGRect(x: 1, y: 1, width: diameter, height: diameter))
            NSGraphicsContext.saveGraphicsState()
            lens.addClip()
            NSColor.darkGray.setFill()
            lens.fill()
            if let crop {
                let destination = CGRect(x: 1 + (visible.minX - region.minX) * pixelSide,
                                         y: 1 + (visible.minY - region.minY) * pixelSide,
                                         width: visible.width * pixelSide, height: visible.height * pixelSide)
                let patch = NSImage(cgImage: crop, size: visible.size)
                patch.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1,
                           respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none.rawValue])
            }
            let center = NSBezierPath(rect: CGRect(x: hotSpot.x - pixelSide / 2, y: hotSpot.y - pixelSide / 2,
                                                   width: pixelSide, height: pixelSide))
            for path in [lens, center] {
                NSColor.black.setStroke()
                path.lineWidth = 3
                path.stroke()
                NSColor.white.setStroke()
                path.lineWidth = 1
                path.stroke()
            }
            NSGraphicsContext.restoreGraphicsState()
            NSColor.black.setFill()
            NSBezierPath(roundedRect: CGRect(x: 10, y: diameter, width: size.width - 20, height: 24), xRadius: 5, yRadius: 5).fill()
            let label = NSAttributedString(string: hex, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.white
            ])
            label.draw(at: CGPoint(x: (size.width - label.size().width) / 2, y: diameter + (24 - label.size().height) / 2))
            return true
        }
        return NSCursor(image: cursorImage, hotSpot: hotSpot)
    }

    func hex(at point: CGPoint, imageSize: CGSize) -> String? {
        pixel(at: point, imageSize: imageSize).map(hex(for:))
    }

    func pixel(at point: CGPoint, imageSize: CGSize) -> CGPoint? {
        guard point.x >= 0, point.y >= 0, point.x < imageSize.width, point.y < imageSize.height else { return nil }
        return CGPoint(x: floor(point.x * CGFloat(context.width) / imageSize.width),
                       y: floor(point.y * CGFloat(context.height) / imageSize.height))
    }

    func hex(for location: CGPoint) -> String {
        let offset = Int(location.y) * context.bytesPerRow + 4 * Int(location.x)
        let pixel = context.data!.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
        let alpha = max(1, Int(pixel[3]))
        let channels = (0..<3).map { (Int(pixel[$0]) * 255 + alpha / 2) / alpha }
        return String(format: "#%02X%02X%02X", channels[0], channels[1], channels[2])
    }
}
