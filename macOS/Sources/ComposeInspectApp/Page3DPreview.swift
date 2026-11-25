import AppKit
import ComposeInspectCore
import SceneKit
import SwiftUI

struct PagePreviewGroup: Identifiable {
    let id: String
    private(set) var faceOwnerID: String
    let bounds: CGRect
    let outline: Path
    let contentClip: Path?
    let inheritedClip: Path?
    var children: [PagePreviewGroup]
    var isLazyViewport = false
    var stacksChildren = false
    let isDetachedItem: Bool
    let showsSurface: Bool

    // Use raw ancestors only to recover clips and detached-item membership lost
    // when a filter promotes a child. All renderable groups come from the visible tree.
    static func projected(_ root: InspectorNode, original: InspectorSnapshotIndex) -> Self {
        var items = Set<String>()
        var clips: [String: Path] = [:]
        func collect(_ parent: InspectorNode) {
            for child in parent.children {
                if parent.id == root.id && child.name == "SkippableItem" { items.insert(child.id) }
                var cursor = original.parentIDs[child.id]
                while let id = cursor, id != parent.id, let ancestor = original.byID[id] {
                    if parent.id == root.id && ancestor.name == "SkippableItem" { items.insert(child.id) }
                    for layer in ancestor.style?.layers ?? [] where layer.kind == "clip" && layer.unsupported == nil {
                        guard let shape = layer.shape, ["rectangle", "rounded", "cut", "path"].contains(shape.kind) else { continue }
                        let path = ComponentStyleDrawing.path(in: layer.bounds, shape: shape, scale: 1)
                        clips[child.id] = clips[child.id].map { $0.intersection(path) } ?? path
                    }
                    cursor = original.parentIDs[id]
                }
                collect(child)
            }
        }
        collect(root)
        return Self(root, itemIDs: items, inheritedClips: clips)
    }

    init(_ node: InspectorNode, insideBoxLayout: Bool = false, itemIDs: Set<String> = [], inheritedClips: [String: Path] = [:], isVisible: (String) -> Bool = { _ in true }) {
        func containsPinnableItem(_ node: InspectorNode) -> Bool {
            node.name == "LazyLayoutPinnableItem" || node.children.contains(where: containsPinnableItem)
        }
        isDetachedItem = itemIDs.contains(node.id) || node.kind == "ViewNode" && node.children.contains {
            $0.name == "SkippableItem" && containsPinnableItem($0)
        }
        showsSurface = isVisible(node.id)
        id = node.id
        faceOwnerID = node.id
        bounds = node.bounds
        let outer = node.style?.layers.first {
            $0.bounds == node.bounds && ($0.kind == "background" || $0.kind == "clip")
        }
        outline = ComponentStyleDrawing.path(in: node.bounds, shape: outer?.shape, scale: 1)
        inheritedClip = inheritedClips[node.id]
        var mask = inheritedClip
        for layer in node.style?.layers ?? [] where layer.kind == "clip" && layer.unsupported == nil {
            guard let shape = layer.shape, ["rectangle", "rounded", "cut", "path"].contains(shape.kind) else { continue }
            let path = ComponentStyleDrawing.path(in: layer.bounds, shape: shape, scale: 1)
            mask = mask?.intersection(path) ?? path
        }
        contentClip = mask
        children = []
        func hasVisibleGeometry(_ node: InspectorNode) -> Bool {
            !node.bounds.isEmpty || node.children.contains(where: hasVisibleGeometry)
        }
        func canShareFace(_ parent: InspectorNode, _ child: InspectorNode) -> Bool {
            guard parent.bounds == child.bounds else { return false }
            if parent.style == child.style { return true }
            // Pure layout measurements do not add paint or change the rectangular face.
            func layoutOnly(_ node: InspectorNode) -> Bool {
                (node.style?.layers ?? []).allSatisfy {
                    $0.kind == "padding" && $0.alpha == 1 && $0.unsupported == nil
                }
            }
            guard layoutOnly(parent) else { return false }
            return (child.style?.layers ?? []).allSatisfy {
                $0.unsupported == nil && $0.alpha == 1 &&
                    ($0.kind == "padding" || ($0.kind == "background" &&
                     $0.bounds == child.bounds && ($0.shape == nil || $0.shape?.kind == "rectangle")))
            }
        }
        func appendChildren(of parent: InspectorNode, insideBox: Bool) {
            let box = parent.name == "Box" || (insideBox && ["Layout", "ReusableComposeNode"].contains(parent.name))
            if parent.name == "LazyLayout" && !parent.bounds.isEmpty { isLazyViewport = true }
            let visible = parent.children.filter(hasVisibleGeometry)
            if box && visible.count > 1 { stacksChildren = true }
            for child in parent.children {
                if visible.count == 1, visible.first?.id == child.id,
                   inheritedClips[child.id] == nil, !itemIDs.contains(child.id), isVisible(parent.id) == isVisible(child.id), canShareFace(parent, child) {
                    faceOwnerID = child.id
                    appendChildren(of: child, insideBox: box)
                } else {
                    children.append(PagePreviewGroup(child, insideBoxLayout: box, itemIDs: itemIDs, inheritedClips: inheritedClips, isVisible: isVisible))
                }
            }
        }
        appendChildren(of: node, insideBox: insideBoxLayout)
    }
}

struct PageSceneLayer {
    let id: String
    let face: Path
    let box: CGRect
    var depth: Int
    var coveringLayers: [Int] = []
    var carriesTexture = true

    static let thickness: CGFloat = 0.065

    // Give overlapping solids disjoint z intervals within their logical depth.
    // Separate cards reuse a slot so that rows and columns stay aligned.
    static func frontPositions(_ layers: [Self]) -> [CGFloat] {
        var positions = Array(repeating: CGFloat.zero, count: layers.count)
        var base: CGFloat = 0
        for (_, indices) in Dictionary(grouping: layers.indices, by: { layers[$0].depth }).sorted(by: { $0.key < $1.key }) {
            var slots: [[Int]] = []
            let spacing = thickness + 0.008
            for index in indices {
                let layer = layers[index]
                let slot = slots.firstIndex { occupied in
                    !occupied.contains { other in
                        !layers[other].box.intersection(layer.box).isEmpty &&
                            !layers[other].face.intersection(layer.face).boundingRect.isEmpty
                    }
                } ?? slots.count
                if slot == slots.count { slots.append([]) }
                slots[slot].append(index)
                positions[index] = base + CGFloat(slot) * spacing
            }
            base += CGFloat(slots.count - 1) * spacing + 0.22
        }
        return positions
    }

    // A capture has one composited screenshot. A pixel belongs to the frontmost
    // solid at its screen coordinate, even when two solids come from separate tables.
    static func textureMasks(_ layers: [Self], positions: [CGFloat]) -> [[Int]] {
        let order = layers.indices.sorted { positions[$0] > positions[$1] }
        var masks = Array(repeating: [Int](), count: layers.count)
        for (offset, upper) in order.enumerated() where layers[upper].carriesTexture {
            for lower in order.dropFirst(offset + 1) where !layers[lower].box.intersection(layers[upper].box).isEmpty {
                masks[lower].append(upper)
            }
        }
        return masks
    }

    // SDK composition tables can enumerate a background after the content, and
    // subcompositions are separate roots. LayoutStyles visits the actual Android
    // layout children in tree order, including children of subcompose layouts.
    struct Placement {
        let rank: Int
        let carriesTexture: Bool
    }

    static func layoutOrder(root: InspectorNode, document: InspectorDocument?) -> [String: Placement] {
        guard let document, let window = document.window(for: root.id),
              let capture = window["sdkWindow"]?["captureIndex"]?.int64,
              let windows = document.root["sdkCapture"]?["windows"]?.array,
              windows.indices.contains(Int(capture)),
              let catalogs = windows[Int(capture)]["styleCatalogs"]?.array, catalogs.count == 1,
              let records = catalogs[0]["records"]?.array else { return [:] }
        var ranks: [String: Int] = [:]
        for (index, record) in records.enumerated() {
            guard let identity = record["layoutIdentity"]?.int64,
                  ranks.updateValue(index, forKey: "sdk:\(identity)") == nil else { return [:] }
        }
        // A SubcomposeLayout measures content from a different table. A clip or
        // padding on its host cannot supply screenshot pixels of its own.
        var layoutOnlyHosts = Set<String>()
        func identifyHosts(_ node: InspectorNode) {
            if ["SubcomposeLayout", "BoxWithConstraints"].contains(node.name), let identity = node.clickTargetID,
               let rank = ranks[identity], let modifiers = records[rank]["layers"]?.array,
               modifiers.allSatisfy({ layer in
                   let kind = layer["kind"]?.string
                   return kind == "clip" || kind == "padding" ||
                       (kind == "unsupported" && layer["name"]?.string?.hasSuffix("PaddingModifierElement") == true)
               }) {
                layoutOnlyHosts.insert(identity)
            }
            node.children.forEach(identifyHosts)
        }
        identifyHosts(root)
        var order: [String: Placement] = [:]
        func visit(_ node: InspectorNode) -> Int? {
            let firstChild = node.children.compactMap(visit).min()
            let rank = node.clickTargetID.flatMap { ranks[$0] } ?? firstChild
            if let rank {
                let syntheticHost = node.kind == "ViewNode" && node.id != root.id && node.clickTargetID == nil
                order[node.id] = Placement(rank: rank, carriesTexture: !syntheticHost &&
                    !(node.clickTargetID.map(layoutOnlyHosts.contains) ?? false))
            }
            return rank
        }
        _ = visit(root)
        return order
    }

    static func layout(_ root: PagePreviewGroup, screen: CGRect, structuralOnly: Bool = false, order: [String: Placement] = [:]) -> [Self] {
        var layers: [Self] = []
        var placements: [Placement] = []
        var detached: [PagePreviewGroup] = []
        var viewports: [(id: String, face: Path)] = []
        var viewportItems: [String: [PagePreviewGroup]] = [:]
        var attached = Set<String>()
        func visit(_ group: PagePreviewGroup, minimumDepth: Int, clip: Path?, ancestors: [Int]) {
            // Reject empty/disjoint geometry before Path boolean operations. An
            // empty SwiftUI path can otherwise yield the other operand's bounds.
            let clip = group.inheritedClip.map { inherited in clip.map { inherited.intersection($0) } ?? inherited } ?? clip
            let visibleBox = group.bounds.intersection(screen)
            var face = Path()
            if !visibleBox.isEmpty, !group.outline.isEmpty,
               clip.map({ !$0.isEmpty && !$0.boundingRect.intersection(visibleBox).isEmpty }) ?? true {
                face = clip.map { group.outline.intersection($0) } ?? group.outline
                if !face.isEmpty && !screen.contains(group.bounds) { face = face.intersection(Path(visibleBox)) }
            }
            let box = face.boundingRect.integral.intersection(screen)
            var childDepth = minimumDepth
            var childAncestors = ancestors
            if group.showsSurface && !box.isEmpty {
                var depth = minimumDepth
                let index = layers.count
                // Visit a sibling's entire subtree before placing the next sibling.
                // Only physical overlap requires a new level between branches.
                if structuralOnly {
                    for ancestor in ancestors { layers[ancestor].coveringLayers.append(index) }
                    childAncestors.append(index)
                } else {
                    for prior in layers.indices where !layers[prior].box.intersection(box).isEmpty {
                        guard !layers[prior].face.intersection(face).boundingRect.isEmpty else { continue }
                        depth = max(depth, layers[prior].depth + 1)
                        layers[prior].coveringLayers.append(index)
                    }
                }
                if let placement = order[group.faceOwnerID] ?? order[group.id] {
                    placements.append(placement)
                }
                layers.append(Self(id: group.id, face: face, box: box, depth: depth))
                childDepth = depth + 1
            }
            let childClip = group.contentClip.map { mask in clip?.intersection(mask) ?? mask } ?? clip
            if structuralOnly && group.isLazyViewport {
                viewports.append((group.id, childClip.map { face.intersection($0) } ?? face))
            }
            for child in group.children {
                if structuralOnly && group.id == root.id && child.isDetachedItem {
                    detached.append(child)
                    continue
                }
                visit(child, minimumDepth: childDepth, clip: childClip, ancestors: childAncestors)
            }
        }
        visit(root, minimumDepth: 0, clip: nil, ancestors: [])
        // Lazy items can arrive as independent composition tables. Place them above
        // the viewport surfaces before assigning their descendants a relative depth.
        let containerIndices = layers.indices
        for item in detached {
            let matches = viewports.filter { $0.face.boundingRect.intersects(item.bounds) }
            let candidates = matches.filter { viewport in
                matches.allSatisfy { $0.face.boundingRect.contains(viewport.face.boundingRect) }
            }
            if candidates.count == 1, let viewport = candidates.first {
                let box = viewport.face.boundingRect.integral.intersection(screen)
                let parents = containerIndices.filter { layers[$0].box.contains(box) }
                let depth = parents.map { layers[$0].depth }.max() ?? 0
                visit(item, minimumDepth: depth + 1, clip: viewport.face, ancestors: parents)
                viewportItems[viewport.id, default: []].append(item)
                attached.insert(item.id)
            } else {
                visit(item, minimumDepth: 1, clip: root.contentClip, ancestors: layers.first?.id == root.id ? [0] : [])
            }
        }
        let hasLayoutOrder = !placements.isEmpty && layers.count == placements.count
        if structuralOnly && !hasLayoutOrder {
            let indices = Dictionary(uniqueKeysWithValues: layers.indices.map { (layers[$0].id, $0) })
            func stack(_ group: PagePreviewGroup) -> [Int] {
                var preceding: [Int] = []
                for child in group.children where group.id != root.id || !attached.contains(child.id) {
                    let branch = stack(child)
                    if group.stacksChildren {
                        var offset = 0
                        for lower in preceding {
                            for upper in branch where layers[lower].box.intersects(layers[upper].box) {
                                guard !layers[lower].face.intersection(layers[upper].face).boundingRect.isEmpty else { continue }
                                offset = max(offset, layers[lower].depth + 1 - layers[upper].depth)
                                layers[lower].coveringLayers.append(upper)
                            }
                        }
                        for index in branch { layers[index].depth += offset }
                    }
                    preceding.append(contentsOf: branch)
                }
                for item in viewportItems[group.id] ?? [] { preceding.append(contentsOf: stack(item)) }
                if let index = indices[group.id] { preceding.append(index) }
                return preceding
            }
            _ = stack(root)
        }
        if hasLayoutOrder {
            let rectangles = layers.map { layer -> CGRect? in
                var rectangle = CGRect.zero
                return layer.face.cgPath.isRect(&rectangle) ? rectangle : nil
            }
            let ordered = layers.indices.sorted {
                let a = placements[$0].rank, b = placements[$1].rank
                return a == b ? $0 < $1 : a < b
            }
            // Only surfaces with overlapping clipped geometry constrain each other.
            // Disjoint cards stay aligned even when recorded in separate tables.
            for (offset, index) in ordered.enumerated() {
                var depth = 0
                for lower in ordered[..<offset] where !layers[lower].box.intersection(layers[index].box).isEmpty {
                    if let a = rectangles[lower], let b = rectangles[index] {
                        if a.intersection(b).isEmpty { continue }
                    } else if layers[lower].face.intersection(layers[index].face).boundingRect.isEmpty { continue }
                    depth = max(depth, layers[lower].depth + 1)
                }
                layers[index].depth = depth
                layers[index].carriesTexture = placements[index].carriesTexture
            }
        }
        return layers
    }
}

struct InlinePagePreview: View {
    let node: InspectorNode
    let image: NSImage
    let store: WorkspaceStore
    let active: Bool
    @State private var page: (root: PagePreviewGroup, surfaces: PageSurfaces, revision: UInt)?
    @State private var failed = false
    private struct FilterKey: Equatable {
        let revision: UInt
        let query: String
    }

    var body: some View {
        Group {
            if store.searchMatches?.contains(node.id) == false {
                Text("当前窗口没有匹配的组件").foregroundStyle(.secondary)
            } else if let page {
                Page3DPreview(root: page.root, surfaces: page.surfaces, revision: page.revision, store: store, active: active)
            } else if failed {
                Text("暂无可显示的截图")
            } else {
                ProgressView("正在准备 3D 预览")
            }
        }.task(id: FilterKey(revision: store.presentationRevision, query: store.search)) {
            let matches = store.searchMatches
            guard matches?.contains(node.id) != false else { return }
            let index = store.presentationIndex
            let revision = (page?.revision ?? 0) &+ 1
            guard let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { failed = true; return }
            let sdk = store.snapshot.document?.root["captureBackend"]?.string == "sdk"
            let document = store.snapshot.document
            let original = store.snapshotIndex
            let worker = Task.detached(priority: .userInitiated) { [node] in
                let displayed = matches.flatMap { ids in index.filteringNodes { ids.contains($0.id) }.byID[node.id] } ?? node
                let group = PagePreviewGroup.projected(displayed, original: original)
                try Task.checkCancellation()
                let order = PageSceneLayer.layoutOrder(root: original.byID[node.id] ?? node, document: document)
                let surfaces = try PageSurfaces(root: group, image: pixels, structuralOnly: sdk, order: order)
                return (group, surfaces, revision)
            }
            do {
                let next = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                page = next
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
}

private struct Page3DPreview: View {
    let root: PagePreviewGroup
    let surfaces: PageSurfaces
    let revision: UInt
    let store: WorkspaceStore
    let active: Bool
    @State private var resetRequest = 0

    private var selectionPath: [String] {
        guard let id = store.selectedNodeID else { return [] }
        return store.presentationIndex.path(to: id).map(\.id)
    }

    // Merged wrappers share the solid identified by the outermost node.
    private func groupPath(_ path: [String]) -> [String] {
        var result: [String] = []
        var candidates = [root]
        for id in path {
            if let group = candidates.first(where: { $0.id == id }) {
                if group.showsSurface { result.append(id) }
                candidates = group.children
            }
        }
        return result
    }

    var body: some View {
        let path = groupPath(selectionPath)
        PageScene(surfaces: surfaces, revision: revision, active: active, selected: path.last, resetRequest: resetRequest, onSelect: store.select)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                IconButton(title: "重置视角", systemImage: "arrow.counterclockwise") {
                    resetRequest += 1
                }.padding(10)
            }
    }
}

final class PageSceneView: SCNView {
    var active = true
    private var panMonitor: Any?
    private var spaceHeld = false
    private var panAnchor: SCNVector3?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let panMonitor { NSEvent.removeMonitor(panMonitor) }
        panMonitor = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        clearPan()
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(clearPan),
                                               name: NSWindow.didResignKeyNotification, object: window)
        // Claim the whole modified drag before SceneKit's orbit and click recognizers see it.
        panMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handlePan(event) == true }
            return handled ? nil : event
        }
    }

    @objc private func clearPan() {
        spaceHeld = false
        panAnchor = nil
    }

    private func handlePan(_ event: NSEvent) -> Bool {
        guard active, let window, event.window === window else { return false }
        if event.type == .keyDown || event.type == .keyUp {
            guard event.keyCode == 49 else { return false }
            if event.type == .keyUp {
                let handled = spaceHeld
                spaceHeld = false
                return handled
            }
            guard window.isKeyWindow, !(window.firstResponder is NSTextView),
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  isMousePoint(convert(window.mouseLocationOutsideOfEventStream, from: nil), in: visibleRect)
            else { return false }
            spaceHeld = true
            return true
        }
        let point = convert(event.locationInWindow, from: nil)
        switch event.type {
        case .leftMouseDown:
            panAnchor = nil
            guard spaceHeld, isMousePoint(point, in: visibleRect) else { return false }
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

// SceneKit nodes are built off-screen by one worker, then handed to the main actor.
struct PageSurfaces: @unchecked Sendable {
    let nodes: [SCNNode]
    let frontmost: CGFloat

    init(root: PagePreviewGroup, image: CGImage, structuralOnly: Bool, order: [String: PageSceneLayer.Placement] = [:]) throws {
        let screen = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let unit = 6 / max(screen.width, screen.height)
        let layers = PageSceneLayer.layout(root, screen: screen, structuralOnly: structuralOnly, order: order)
        let positions = PageSceneLayer.frontPositions(layers)
        let masks = PageSceneLayer.textureMasks(layers, positions: positions)
        frontmost = positions.max() ?? 0

        var nodes: [SCNNode] = []
        for (layerIndex, layer) in layers.enumerated() {
            try Task.checkCancellation()
            let frontZ = positions[layerIndex]
            let box = layer.box
            if let crop = image.cropping(to: box) {
                let thickness = PageSceneLayer.thickness

                let material = SCNMaterial()
                material.isDoubleSided = false
                material.lightingModel = .constant
                let scale = min(1, 800 / max(box.width, box.height))
                let size = CGSize(width: max(1, (box.width * scale).rounded()), height: max(1, (box.height * scale).rounded()))
                if !layer.carriesTexture {
                    material.diffuse.contents = NSColor.clear
                    material.writesToDepthBuffer = false
                } else if let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                       bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    ctx.scaleBy(x: size.width / box.width, y: size.height / box.height)
                    ctx.draw(crop, in: CGRect(origin: .zero, size: box.size))
                    ctx.setFillColor(CGColor(gray: 0.65, alpha: 0.16))
                    ctx.setBlendMode(.copy)
                    let toBitmap = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -box.minX, ty: box.maxY)
                    for index in masks[layerIndex] {
                        ctx.addPath(layers[index].face.applying(toBitmap).cgPath)
                        ctx.fillPath()
                    }
                    material.diffuse.contents = ctx.makeImage()
                } else { material.diffuse.contents = NSColor.gray.withAlphaComponent(0.16) }
                let side = SCNMaterial()
                side.lightingModel = .constant
                side.diffuse.contents = NSColor(srgbRed: 0.42, green: 0.49, blue: 0.59, alpha: 1)
                let back = SCNMaterial()
                back.lightingModel = .constant
                back.diffuse.contents = NSColor(srgbRed: 0.32, green: 0.38, blue: 0.47, alpha: 0.45)
                if !layer.carriesTexture {
                    back.diffuse.contents = NSColor.clear
                    back.writesToDepthBuffer = false
                }
                let solid = PageScene.solid(face: layer.face, box: box, unit: unit, thickness: thickness,
                                       front: material, side: side, back: back)
                let node = SCNNode(geometry: solid)
                node.name = layer.id
                node.position = SCNVector3((box.midX - screen.midX) * unit,
                                           (screen.midY - box.midY) * unit, frontZ - thickness / 2)
                node.renderingOrder = layer.depth
                nodes.append(node)
            }
        }
        self.nodes = nodes
    }

    @MainActor func install(in scene: SCNNode) {
        for node in scene.childNodes where node.geometry != nil { node.removeFromParentNode() }
        for node in nodes { scene.addChildNode(node) }
    }
}

struct PageScene: NSViewRepresentable {
    let surfaces: PageSurfaces
    let revision: UInt
    var active = true
    let selected: String?
    let resetRequest: Int
    let onSelect: (String) -> Void

    final class Coordinator: NSObject, NSGestureRecognizerDelegate {
        var revision: UInt?
        var lastResetRequest = 0
        var initialTransform = matrix_identity_float4x4
        var initialTarget = SCNVector3Zero
        var onSelect: (String) -> Void
        init(onSelect: @escaping (String) -> Void) { self.onSelect = onSelect }

        @MainActor @objc func click(_ gesture: NSClickGestureRecognizer) {
            guard let view = gesture.view as? SCNView,
                  let hit = view.hitTest(gesture.location(in: view), options: [
                    .searchMode: SCNHitTestSearchMode.all.rawValue, .sortResults: true
                  ]).first(where: { hit in
                      guard let materials = hit.node.geometry?.materials, !materials.isEmpty else { return false }
                      return materials[hit.geometryIndex % materials.count].writesToDepthBuffer
                  }), let id = hit.node.name else { return }
            onSelect(id)
        }

        func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer) -> Bool { true }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeNSView(context: Context) -> SCNView {
        let view = PageSceneView()
        let preparedScene = SCNScene()
        view.backgroundColor = .underPageBackgroundColor
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
        let scene = preparedScene.rootNode
        surfaces.install(in: scene)
        let frontmost = surfaces.frontmost
        context.coordinator.revision = revision
        let target = SCNVector3(0, 0, frontmost / 2)
        let distance = 9 + frontmost
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.automaticallyAdjustsZRange = true
        camera.position = SCNVector3(distance * 0.52, distance * 0.21, target.z + distance)
        camera.look(at: target)
        scene.addChildNode(camera)
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        view.scene = preparedScene
        view.pointOfView = camera
        view.defaultCameraController.automaticTarget = false
        view.defaultCameraController.target = target
        SCNTransaction.commit()
        context.coordinator.initialTransform = camera.simdWorldTransform
        context.coordinator.initialTarget = target
        context.coordinator.lastResetRequest = resetRequest
        return view
    }

    nonisolated static func solid(face: Path, box: CGRect, unit: CGFloat, thickness: CGFloat,
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
        (view as? PageSceneView)?.active = active
        let coordinator = context.coordinator
        if coordinator.revision != revision, let scene = view.scene?.rootNode {
            SCNTransaction.begin()
            SCNTransaction.disableActions = true
            surfaces.install(in: scene)
            SCNTransaction.commit()
            coordinator.revision = revision
        }
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
