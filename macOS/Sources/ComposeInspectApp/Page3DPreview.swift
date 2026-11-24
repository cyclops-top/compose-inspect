import AppKit
import ComposeInspectCore
import SceneKit
import SwiftUI

struct PagePreviewGroup: Identifiable {
    let id: String
    var names: [String]
    let bounds: CGRect
    let outline: Path
    let contentClip: Path?
    var children: [PagePreviewGroup]
    var branches: [PagePreviewGroup]? { children.isEmpty ? nil : children }

    init(_ node: InspectorNode) {
        id = node.id
        bounds = node.bounds
        let outer = node.style?.layers.first {
            $0.bounds == node.bounds && ($0.kind == "background" || $0.kind == "clip")
        }
        outline = ComponentStyleDrawing.path(in: node.bounds, shape: outer?.shape, scale: 1)
        var mask: Path?
        for layer in node.style?.layers ?? [] where layer.kind == "clip" && layer.unsupported == nil {
            guard let shape = layer.shape, ["rectangle", "rounded", "cut"].contains(shape.kind) else { continue }
            let path = ComponentStyleDrawing.path(in: layer.bounds, shape: shape, scale: 1)
            mask = mask?.intersection(path) ?? path
        }
        contentClip = mask
        names = [node.displayName]
        children = []
        func hasVisibleGeometry(_ node: InspectorNode) -> Bool {
            !node.bounds.isEmpty || node.children.contains(where: hasVisibleGeometry)
        }
        func appendChildren(of parent: InspectorNode) {
            let visible = parent.children.filter(hasVisibleGeometry)
            for child in parent.children {
                if visible.count == 1, visible.first?.id == child.id,
                   child.bounds == parent.bounds, child.style == parent.style {
                    names.append(child.displayName)
                    appendChildren(of: child)
                } else {
                    children.append(PagePreviewGroup(child))
                }
            }
        }
        appendChildren(of: node)
    }
}

struct PageSceneLayer {
    let id: String
    let face: Path
    let box: CGRect
    let depth: Int
    var coveringLayers: [Int] = []

    static func layout(_ root: PagePreviewGroup, screen: CGRect) -> [Self] {
        var layers: [Self] = []
        func visit(_ group: PagePreviewGroup, minimumDepth: Int, clip: Path?) {
            var face = clip.map { group.outline.intersection($0) } ?? group.outline
            if !screen.contains(group.bounds) { face = face.intersection(Path(screen)) }
            let box = face.boundingRect.integral.intersection(screen)
            var childDepth = minimumDepth
            if !box.isEmpty {
                var depth = minimumDepth
                let index = layers.count
                // Visit a sibling's entire subtree before placing the next sibling.
                // Only physical overlap requires a new level between branches.
                for prior in layers.indices where !layers[prior].box.intersection(box).isEmpty {
                    guard !layers[prior].face.intersection(face).boundingRect.isEmpty else { continue }
                    depth = max(depth, layers[prior].depth + 1)
                    layers[prior].coveringLayers.append(index)
                }
                layers.append(Self(id: group.id, face: face, box: box, depth: depth))
                childDepth = depth + 1
            }
            let childClip = group.contentClip.map { mask in clip?.intersection(mask) ?? mask } ?? clip
            for child in group.children {
                visit(child, minimumDepth: childDepth, clip: childClip)
            }
        }
        visit(root, minimumDepth: 0, clip: nil)
        return layers
    }
}

struct InlinePagePreview: View {
    let node: InspectorNode
    let image: NSImage
    let store: WorkspaceStore
    @State private var page: (root: PagePreviewGroup, image: CGImage)?

    var body: some View {
        Group {
            if let page {
                Page3DPreview(root: page.root, screenshot: page.image, store: store)
            } else {
                Text("暂无可显示的截图").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.onAppear {
            if let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                page = (PagePreviewGroup(node), pixels)
            }
        }
    }
}

private struct Page3DPreview: View {
    let root: PagePreviewGroup
    let screenshot: CGImage
    let store: WorkspaceStore
    @State private var resetRequest = 0
    @State private var expanded = Set<String>()

    private var selectionPath: [String] {
        guard let id = store.selectedNodeID else { return [] }
        return store.snapshotIndex.path(to: id).map(\.id)
    }

    // Merged wrappers share the solid identified by the outermost node.
    private func groupPath(_ path: [String]) -> [String] {
        var result: [String] = []
        var candidates = [root]
        for id in path {
            if let group = candidates.first(where: { $0.id == id }) {
                result.append(id)
                candidates = group.children
            }
        }
        return result
    }

    var body: some View {
        let path = groupPath(selectionPath)
        VSplitView {
            PageScene(root: root, image: screenshot, selected: path.last, resetRequest: resetRequest, onSelect: store.selectPageComponent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) {
                    IconButton(title: "重置视角", systemImage: "arrow.counterclockwise") {
                        resetRequest += 1
                    }.padding(10)
                }
            VStack(alignment: .leading, spacing: 8) {
                Text("组件层级").font(.headline)
                Text("点击选中，拖动旋转，⌘ 拖动平移。指向组件后滚动或双指捏合，可围绕该处缩放。仅有一个可见子组件且边界、采集样式一致时，父子共用一层。× 表示合并数。")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollViewReader { scroll in
                    List(selection: Binding(get: { path.last }, set: { id in
                        if let id { store.selectPageComponent(id) }
                    })) {
                        hierarchyRow(root)
                    }.listStyle(.sidebar)
                        .onChange(of: path, initial: true) { _, ids in
                            expanded.formUnion(ids.dropLast())
                            if let last = ids.last { scroll.scrollTo(last) }
                        }
                }
            }.padding(8).frame(minHeight: 100, idealHeight: 145, maxHeight: 240)
        }.onAppear { expanded.insert(root.id) }
    }

    private func hierarchyRow(_ group: PagePreviewGroup) -> AnyView {
        if group.children.isEmpty { return AnyView(row(group)) }
        let open = Binding(get: { expanded.contains(group.id) }, set: { value in
            if value { expanded.insert(group.id) } else { expanded.remove(group.id) }
        })
        return AnyView(DisclosureGroup(isExpanded: open) {
            ForEach(group.children) { hierarchyRow($0) }
        } label: { row(group) }.tag(group.id).id(group.id))
    }

    private func row(_ group: PagePreviewGroup) -> some View {
        Text(group.names.count == 1 ? group.names[0] : "\(group.names[0]) ×\(group.names.count)")
            .tag(group.id).id(group.id).help(group.names.joined(separator: " → "))
    }
}

final class PageSceneView: SCNView {
    private var panMonitor: Any?
    private var panAnchor: SCNVector3?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let panMonitor { NSEvent.removeMonitor(panMonitor) }
        panMonitor = nil
        panAnchor = nil
        guard window != nil else { return }
        // Claim the whole modified drag before SceneKit's orbit and click recognizers see it.
        panMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handlePan(event) == true }
            return handled ? nil : event
        }
    }

    private func handlePan(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        let point = convert(event.locationInWindow, from: nil)
        switch event.type {
        case .leftMouseDown:
            panAnchor = nil
            guard event.modifierFlags.contains(.command), isMousePoint(point, in: visibleRect) else { return false }
            defaultCameraController.stopInertia()
            panAnchor = focalPoint(at: point)
            return panAnchor != nil
        case .leftMouseDragged:
            guard let anchor = panAnchor, let camera = pointOfView else { return false }
            let depth = projectPoint(anchor).z
            let underPointer = unprojectPoint(SCNVector3(point.x, point.y, depth))
            let delta = SIMD3<Float>(anchor) - SIMD3<Float>(underPointer)
            let target = SIMD3<Float>(defaultCameraController.target)
            SCNTransaction.begin()
            SCNTransaction.disableActions = true
            camera.simdWorldPosition += delta
            defaultCameraController.target = SCNVector3(target + delta)
            SCNTransaction.commit()
            return true
        case .leftMouseUp:
            guard panAnchor != nil else { return false }
            panAnchor = nil
            return true
        default: return false
        }
    }

    private func focalPoint(at point: CGPoint) -> SCNVector3? {
        if let hit = hitTest(point, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue]).first {
            return hit.worldCoordinates
        }
        let depth = projectPoint(defaultCameraController.target).z
        guard (0...1).contains(depth) else { return nil }
        return unprojectPoint(SCNVector3(point.x, point.y, depth))
    }

    override func scrollWheel(with event: NSEvent) {
        let sensitivity = event.hasPreciseScrollingDeltas ? 0.012 : 0.14
        let step = min(1, max(-1, event.scrollingDeltaY * sensitivity))
        zoom(at: convert(event.locationInWindow, from: nil), by: exp(step))
    }

    @objc func pinch(_ gesture: NSMagnificationGestureRecognizer) {
        guard gesture.state == .began || gesture.state == .changed else { return }
        let factor = 1 + gesture.magnification
        gesture.magnification = 0
        zoom(at: gesture.location(in: self), by: factor)
    }

    func zoom(at point: CGPoint, by factor: CGFloat) {
        guard factor.isFinite, factor > 0, factor != 1, let camera = pointOfView else { return }
        defaultCameraController.stopInertia()
        let target = defaultCameraController.target
        guard let anchor = focalPoint(at: point) else { return }

        let focus = SIMD3<Float>(anchor)
        let offset = camera.simdWorldPosition - focus
        let distance = simd_length(offset)
        guard distance > 0 else { return }
        let scale = min(100, max(0.12, distance / Float(factor))) / distance
        // Scale the eye and orbit target together to keep the hit point on its screen ray.
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        camera.simdWorldPosition = focus + offset * scale
        defaultCameraController.target = SCNVector3(focus + (SIMD3<Float>(target) - focus) * scale)
        SCNTransaction.commit()
    }
}

struct PageScene: NSViewRepresentable {
    let root: PagePreviewGroup
    let image: CGImage
    let selected: String?
    let resetRequest: Int
    let onSelect: (String) -> Void

    final class Coordinator: NSObject, NSGestureRecognizerDelegate {
        var lastResetRequest = 0
        var initialTransform = matrix_identity_float4x4
        var initialTarget = SCNVector3Zero
        var onSelect: (String) -> Void
        init(onSelect: @escaping (String) -> Void) { self.onSelect = onSelect }

        @MainActor @objc func click(_ gesture: NSClickGestureRecognizer) {
            guard let view = gesture.view as? SCNView,
                  let hit = view.hitTest(gesture.location(in: view), options: [
                    .searchMode: SCNHitTestSearchMode.closest.rawValue
                  ]).first, let id = hit.node.name else { return }
            onSelect(id)
        }

        func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer) -> Bool { true }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeNSView(context: Context) -> SCNView {
        let view = PageSceneView()
        view.scene = SCNScene()
        view.backgroundColor = .windowBackgroundColor
        view.allowsCameraControl = true
        for recognizer in view.gestureRecognizers where recognizer is NSMagnificationGestureRecognizer {
            view.removeGestureRecognizer(recognizer)
        }
        view.addGestureRecognizer(NSMagnificationGestureRecognizer(target: view, action: #selector(PageSceneView.pinch(_:))))
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.click(_:)))
        click.delegate = context.coordinator
        click.delaysPrimaryMouseButtonEvents = false
        view.addGestureRecognizer(click)
        view.antialiasingMode = .multisampling4X
        let scene = view.scene!.rootNode
        let screen = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let unit = 6 / max(screen.width, screen.height)
        let layers = PageSceneLayer.layout(root, screen: screen)
        let depthMax = layers.map(\.depth).max() ?? 0

        for layer in layers {
            let box = layer.box
            if let crop = image.cropping(to: box) {
                let thickness: CGFloat = 0.065

                let material = SCNMaterial()
                material.isDoubleSided = false
                material.lightingModel = .constant
                // Later surfaces own the screenshot pixels in the shared region.
                let scale = min(1, 800 / max(box.width, box.height))
                let size = CGSize(width: max(1, (box.width * scale).rounded()), height: max(1, (box.height * scale).rounded()))
                if let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                       bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    ctx.scaleBy(x: size.width / box.width, y: size.height / box.height)
                    ctx.draw(crop, in: CGRect(origin: .zero, size: box.size))
                    ctx.setFillColor(CGColor(gray: 0.65, alpha: 0.16))
                    ctx.setBlendMode(.copy)
                    let toBitmap = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -box.minX, ty: box.maxY)
                    for index in layer.coveringLayers {
                        ctx.addPath(layers[index].face.applying(toBitmap).cgPath)
                        ctx.fillPath()
                    }
                    material.diffuse.contents = ctx.makeImage()
                } else { material.diffuse.contents = crop }
                let side = SCNMaterial()
                side.lightingModel = .constant
                side.diffuse.contents = NSColor(srgbRed: 0.42, green: 0.49, blue: 0.59, alpha: 1)
                let back = SCNMaterial()
                back.lightingModel = .constant
                back.diffuse.contents = NSColor(srgbRed: 0.32, green: 0.38, blue: 0.47, alpha: 0.45)
                let solid = Self.solid(face: layer.face, box: box, unit: unit, thickness: thickness,
                                       front: material, side: side, back: back)
                let node = SCNNode(geometry: solid)
                node.name = layer.id
                node.position = SCNVector3((box.midX - screen.midX) * unit,
                                           (screen.midY - box.midY) * unit, CGFloat(layer.depth) * 0.22 - thickness / 2)
                node.renderingOrder = layer.depth
                scene.addChildNode(node)
            }
        }
        let target = SCNVector3(0, 0, CGFloat(depthMax) * 0.11)
        let distance = 9 + CGFloat(depthMax) * 0.22
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.automaticallyAdjustsZRange = true
        camera.position = SCNVector3(distance * 0.52, distance * 0.21, target.z + distance)
        camera.look(at: target)
        scene.addChildNode(camera)
        view.pointOfView = camera
        view.defaultCameraController.target = target
        context.coordinator.initialTransform = camera.simdWorldTransform
        context.coordinator.initialTarget = target
        context.coordinator.lastResetRequest = resetRequest
        return view
    }

    static func solid(face: Path, box: CGRect, unit: CGFloat, thickness: CGFloat,
                      front: SCNMaterial, side: SCNMaterial, back: SCNMaterial) -> SCNGeometry {
        var rectangle = CGRect.zero
        if face.cgPath.isRect(&rectangle), rectangle == box {
            let solid = SCNBox(width: box.width * unit, height: box.height * unit,
                               length: thickness, chamferRadius: 0)
            solid.materials = [front, side, back, side, side, side]
            return solid
        }
        // Compose measures corners in top-left screen coordinates. SceneKit extrudes in y-up space.
        let local = CGAffineTransform(a: unit, b: 0, c: 0, d: -unit, tx: -box.midX * unit, ty: box.midY * unit)
        let path = NSBezierPath(cgPath: face.applying(local).cgPath)
        path.flatness = unit * 0.35
        let solid = SCNShape(path: path, extrusionDepth: thickness)
        solid.materials = [front, back, side]
        return solid
    }

    func updateNSView(_ view: SCNView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.lastResetRequest != resetRequest {
            coordinator.lastResetRequest = resetRequest
            view.defaultCameraController.stopInertia()
            SCNTransaction.begin()
            SCNTransaction.disableActions = true
            view.defaultCameraController.target = coordinator.initialTarget
            view.pointOfView?.simdWorldTransform = coordinator.initialTransform
            SCNTransaction.commit()
        }
        coordinator.onSelect = onSelect
        for node in view.scene?.rootNode.childNodes ?? [] where node.geometry != nil {
            for material in node.geometry?.materials ?? [] {
                material.emission.contents = node.name == selected ? NSColor.systemBlue : NSColor.black
                material.emission.intensity = node.name == selected ? 0.5 : 0
            }
        }
    }
}
