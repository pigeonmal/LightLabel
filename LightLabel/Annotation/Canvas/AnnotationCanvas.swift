import AppKit
import SwiftUI

struct AnnotationCanvas: NSViewRepresentable {
    @Bindable var model: AppModel

    func makeNSView(context: Context) -> AnnotationCanvasView {
        let view = AnnotationCanvasView()
        view.onSelect = { model.selectedAnnotationID = $0 }
        view.onCreate = model.createAnnotation
        view.onGeometryChange = model.updateGeometry
        view.onDelete = model.deleteSelection
        view.onToolChange = { model.tool = $0 }
        return view
    }

    func updateNSView(_ view: AnnotationCanvasView, context: Context) {
        view.configure(imageURL: model.selectedImage.flatMap(model.imageURL), imageSize: model.selectedImage?.size, annotations: model.annotationsForSelectedImage, categories: model.dataset?.categories ?? [], selectedID: model.selectedAnnotationID, tool: model.tool, viewport: model.viewport, showLabels: model.showLabels, showHandles: model.showHandles)
    }
}

@MainActor
final class AnnotationCanvasView: NSView {
    var onSelect: (UUID?) -> Void = { _ in }
    var onCreate: (AnnotationGeometry) -> Void = { _ in }
    var onGeometryChange: (UUID, AnnotationGeometry, AnnotationGeometry, String) -> Void = { _, _, _, _ in }
    var onDelete: () -> Void = {}
    var onToolChange: (AnnotationTool) -> Void = { _ in }

    private var image: CGImage?
    private var imageURL: URL?
    private var imageSize: PixelSize?
    private var annotations: [DatasetAnnotation] = []
    private var categories: [DatasetCategory] = []
    private var selectedID: UUID?
    private var tool = AnnotationTool.select
    private var zoom: CGFloat = 1
    private var pan = CGPoint.zero
    private var lastFitRequest = 0
    private var showLabels = true
    private var showHandles = true
    private var loadTask: Task<Void, Never>?
    private var tracking: NSTrackingArea?
    private var hoverID: UUID?
    private var selectedVertex: (annotationID: UUID, index: Int)?
    private var draftPoints: [NormalizedPoint] = []
    private var drag: DragState?
    private var magnificationStart: CGFloat = 1

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    func configure(imageURL: URL?, imageSize: PixelSize?, annotations: [DatasetAnnotation], categories: [DatasetCategory], selectedID: UUID?, tool: AnnotationTool, viewport: CanvasViewport, showLabels: Bool, showHandles: Bool) {
        self.imageSize = imageSize; self.annotations = annotations; self.categories = categories; self.selectedID = selectedID; self.tool = tool; self.showLabels = showLabels; self.showHandles = showHandles
        if lastFitRequest != viewport.fitRequest { lastFitRequest = viewport.fitRequest; zoom = 1; pan = .zero }
        if self.imageURL != imageURL {
            self.imageURL = imageURL; image = nil; loadTask?.cancel()
            if let imageURL {
                loadTask = Task { [weak self] in
                    let loaded = try? await ImageLoader(maximumConcurrentLoads: 1).fullImage(at: imageURL)
                    guard !Task.isCancelled else { return }
                    self?.image = loaded; self?.needsDisplay = true
                }
            }
        }
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
        super.updateTrackingAreas()
    }

    private var transform: CanvasMapping? {
        guard let imageSize else { return nil }
        let fitted = CanvasTransform(imageSize: imageSize, canvasSize: bounds.size)
        let frame = CGRect(x: bounds.midX + (fitted.imageFrame.minX - bounds.midX) * zoom + pan.x, y: bounds.midY + (fitted.imageFrame.minY - bounds.midY) * zoom + pan.y, width: fitted.imageFrame.width * zoom, height: fitted.imageFrame.height * zoom)
        return CanvasMapping(imageSize: imageSize, imageFrame: frame)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext, let transform else { return }
        context.setFillColor(NSColor.black.withAlphaComponent(0.28).cgColor); context.fill(bounds)
        if let image { context.saveGState(); context.translateBy(x: 0, y: bounds.height); context.scaleBy(x: 1, y: -1); let target = CGRect(x: transform.imageFrame.minX, y: bounds.height - transform.imageFrame.maxY, width: transform.imageFrame.width, height: transform.imageFrame.height); context.draw(image, in: target); context.restoreGState() }
        for annotation in annotations where annotation.isVisible { draw(annotation, transform: transform, context: context) }
        drawDraft(transform: transform, context: context)
    }

    private func draw(_ annotation: DatasetAnnotation, transform: CanvasMapping, context: CGContext) {
        let selected = annotation.id == selectedID, hovered = annotation.id == hoverID
        let category = categories.first { $0.id == annotation.categoryID }
        let color = NSColor(hex: category?.colorHex ?? "#4F8EF7")
        context.saveGState(); context.setStrokeColor(color.cgColor); context.setLineWidth(selected ? 2.5 : hovered ? 2 : 1.5)
        if annotation.source == .aiSuggestion { context.setLineDash(phase: 0, lengths: [7, 4]) }
        if annotation.isLocked { context.setAlpha(0.72) }
        switch annotation.geometry {
        case let .boundingBox(box):
            let rect = transform.canvasRect(from: box); context.stroke(rect)
            if selected && showHandles { for point in handlePoints(rect) { drawHandle(point, color: color, context: context) } }
            if showLabels { drawLabel(category?.name ?? "Unknown", confidence: annotation.attributes.confidence, at: rect.origin, color: color) }
        case let .polygon(polygon):
            guard let first = polygon.points.first else { break }
            context.beginPath(); context.move(to: transform.canvasPoint(from: first)); for point in polygon.points.dropFirst() { context.addLine(to: transform.canvasPoint(from: point)) }; context.closePath(); context.setFillColor(color.withAlphaComponent(annotation.source == .aiSuggestion ? 0.12 : 0.2).cgColor); context.drawPath(using: .fillStroke)
            if selected && showHandles { for point in polygon.points { drawHandle(transform.canvasPoint(from: point), color: color, context: context) } }
            if showLabels { drawLabel(category?.name ?? "Unknown", confidence: annotation.attributes.confidence, at: transform.canvasPoint(from: first), color: color) }
        }
        context.restoreGState()
    }

    private func drawLabel(_ name: String, confidence: Double?, at point: CGPoint, color: NSColor) {
        let text = confidence.map { "\(name)  \(Int($0 * 100))%" } ?? name
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white, .backgroundColor: color]
        NSAttributedString(string: " \(text) ", attributes: attributes).draw(at: CGPoint(x: point.x, y: max(2, point.y - 16)))
    }

    private func drawHandle(_ point: CGPoint, color: NSColor, context: CGContext) { let rect = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8); context.setFillColor(NSColor.windowBackgroundColor.cgColor); context.fill(rect); context.setStrokeColor(color.cgColor); context.stroke(rect) }

    private func drawDraft(transform: CanvasMapping, context: CGContext) {
        if case let .box(start, current) = drag { context.setStrokeColor(NSColor.controlAccentColor.cgColor); context.setLineDash(phase: 0, lengths: [5, 4]); context.stroke(CGRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x - start.x), height: abs(current.y - start.y))) }
        guard !draftPoints.isEmpty else { return }
        context.setStrokeColor(NSColor.controlAccentColor.cgColor); context.setLineWidth(2); context.beginPath(); context.move(to: transform.canvasPoint(from: draftPoints[0])); for point in draftPoints.dropFirst() { context.addLine(to: transform.canvasPoint(from: point)) }; context.strokePath()
        for point in draftPoints { drawHandle(transform.canvasPoint(from: point), color: .controlAccentColor, context: context) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self); guard let transform else { return }
        let point = convert(event.locationInWindow, from: nil)
        if tool == .pan { drag = .pan(start: point, origin: pan); return }
        if tool == .box { drag = .box(start: point, current: point); return }
        if tool == .polygon {
            let normalized = transform.normalizedPoint(from: point, clamp: true)
            if event.clickCount > 1 { finishPolygon() } else if draftPoints.count >= 3, distance(point, transform.canvasPoint(from: draftPoints[0])) < 10 { finishPolygon() } else { draftPoints.append(normalized); needsDisplay = true }
            return
        }
        if let hit = hitTestAnnotation(point, transform: transform) {
            onSelect(hit.annotation.id); selectedID = hit.annotation.id
            guard !hit.annotation.isLocked else { needsDisplay = true; return }
            drag = .edit(id: hit.annotation.id, original: hit.annotation.geometry, mode: hit.mode, start: transform.normalizedPoint(from: point, clamp: true), current: hit.annotation.geometry)
            if case let .vertex(index) = hit.mode { selectedVertex = (hit.annotation.id, index) } else { selectedVertex = nil }
        } else { onSelect(nil); selectedID = nil; selectedVertex = nil }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let transform, let drag else { return }; let point = convert(event.locationInWindow, from: nil)
        switch drag {
        case let .box(start, _): self.drag = .box(start: start, current: point)
        case let .pan(start, origin): pan = CGPoint(x: origin.x + point.x - start.x, y: origin.y + point.y - start.y)
        case let .edit(id, original, mode, start, _):
            let now = transform.normalizedPoint(from: point, clamp: true); let changed = editedGeometry(original, mode: mode, delta: (now.x - start.x, now.y - start.y), point: now); self.drag = .edit(id: id, original: original, mode: mode, start: start, current: changed); replaceLocal(id: id, geometry: changed)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let transform, let drag else { return }
        switch drag {
        case let .box(start, current):
            let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(current.x - start.x), height: abs(current.y - start.y)); let box = transform.normalizedBox(from: rect, clamp: true); if box.width > 0.002, box.height > 0.002 { onCreate(.boundingBox(box)) }
        case let .edit(id, original, _, _, current): if original != current { onGeometryChange(id, original, current, "Edit Annotation") }
        case .pan: break
        }
        self.drag = nil; needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) { guard let transform else { return }; hoverID = hitTestAnnotation(convert(event.locationInWindow, from: nil), transform: transform)?.annotation.id; needsDisplay = true }
    override func scrollWheel(with event: NSEvent) { if event.modifierFlags.contains(.command) || abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) { zoomAround(convert(event.locationInWindow, from: nil), factor: exp(-event.scrollingDeltaY * 0.012)) } else { pan.x -= event.scrollingDeltaX; pan.y -= event.scrollingDeltaY; needsDisplay = true } }
    override func magnify(with event: NSEvent) { if event.phase == .began { magnificationStart = zoom }; zoom = min(max(magnificationStart * (1 + event.magnification), 0.1), 20); needsDisplay = true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: draftPoints.removeAll(); drag = nil; onToolChange(.select); needsDisplay = true
        case 36, 76: finishPolygon()
        case 51, 117: deleteVertexOrSelection()
        case 123: nudge(dx: -1, dy: 0, large: event.modifierFlags.contains(.shift))
        case 124: nudge(dx: 1, dy: 0, large: event.modifierFlags.contains(.shift))
        case 125: nudge(dx: 0, dy: 1, large: event.modifierFlags.contains(.shift))
        case 126: nudge(dx: 0, dy: -1, large: event.modifierFlags.contains(.shift))
        default:
            if let text = event.charactersIgnoringModifiers?.lowercased() { if text == "v" { onToolChange(.select) } else if text == "b" { onToolChange(.box) } else if text == "p" { onToolChange(.polygon) } else { super.keyDown(with: event) } }
        }
    }

    private func finishPolygon() { if draftPoints.count >= 3 { onCreate(.polygon(.init(points: draftPoints))) }; draftPoints.removeAll(); needsDisplay = true }
    private func deleteVertexOrSelection() {
        guard let selectedVertex, let annotation = annotations.first(where: { $0.id == selectedVertex.annotationID }), case let .polygon(polygon) = annotation.geometry, polygon.points.indices.contains(selectedVertex.index), polygon.points.count > 3 else { onDelete(); return }
        var points = polygon.points; points.remove(at: selectedVertex.index); let changed = AnnotationGeometry.polygon(.init(points: points)); onGeometryChange(annotation.id, annotation.geometry, changed, "Delete Polygon Vertex"); self.selectedVertex = nil
    }
    private func zoomAround(_ point: CGPoint, factor: CGFloat) { let old = zoom; zoom = min(max(zoom * factor, 0.1), 20); let ratio = zoom / old; pan = CGPoint(x: point.x - bounds.midX - (point.x - bounds.midX - pan.x) * ratio, y: point.y - bounds.midY - (point.y - bounds.midY - pan.y) * ratio); needsDisplay = true }
    private func replaceLocal(id: UUID, geometry: AnnotationGeometry) { if let index = annotations.firstIndex(where: { $0.id == id }) { annotations[index].geometry = geometry } }
    private func nudge(dx: Double, dy: Double, large: Bool) { guard let imageSize, let annotation = annotations.first(where: { $0.id == selectedID }), !annotation.isLocked else { return }; let multiplier = large ? 10.0 : 1.0; let delta = (dx * multiplier / Double(imageSize.width), dy * multiplier / Double(imageSize.height)); let changed = editedGeometry(annotation.geometry, mode: .move, delta: delta, point: .init(x: 0, y: 0)); onGeometryChange(annotation.id, annotation.geometry, changed, "Nudge Annotation") }

    private func editedGeometry(_ geometry: AnnotationGeometry, mode: EditMode, delta: (Double, Double), point: NormalizedPoint) -> AnnotationGeometry {
        switch geometry {
        case let .boundingBox(box):
            var x = box.x, y = box.y, w = box.width, h = box.height
            switch mode { case .move: x = min(max(0, x + delta.0), 1 - w); y = min(max(0, y + delta.1), 1 - h); case .boxHandle(let index): if index % 3 == 0 { let right = box.maxX; x = point.x; w = right - x }; if index % 3 == 2 { w = point.x - x }; if index < 3 { let bottom = box.maxY; y = point.y; h = bottom - y }; if index > 5 { h = point.y - y }; case .vertex: break }
            return .boundingBox(BoundingBox(x: x, y: y, width: max(w, 0.001), height: max(h, 0.001)).clamped())
        case let .polygon(polygon):
            var points = polygon.points
            switch mode { case .move: let bounds = polygon.bounds; let allowedX = min(max(delta.0, -(bounds?.minX ?? 0)), 1 - (bounds?.maxX ?? 1)); let allowedY = min(max(delta.1, -(bounds?.minY ?? 0)), 1 - (bounds?.maxY ?? 1)); points = points.map { .init(x: $0.x + allowedX, y: $0.y + allowedY) }; case .vertex(let index): if points.indices.contains(index) { points[index] = point }; case .boxHandle: break }
            return .polygon(.init(points: points))
        }
    }

    private func hitTestAnnotation(_ point: CGPoint, transform: CanvasMapping) -> (annotation: DatasetAnnotation, mode: EditMode)? {
        for annotation in annotations.reversed() where annotation.isVisible {
            if annotation.id == selectedID {
                switch annotation.geometry { case let .boundingBox(box): for (index, handle) in handlePoints(transform.canvasRect(from: box)).enumerated() where index != 4 && distance(point, handle) <= 7 { return (annotation, .boxHandle(index)) }; case let .polygon(polygon): for (index, vertex) in polygon.points.enumerated() where distance(point, transform.canvasPoint(from: vertex)) <= 7 { return (annotation, .vertex(index)) } }
            }
            switch annotation.geometry { case let .boundingBox(box): if transform.canvasRect(from: box).insetBy(dx: -3, dy: -3).contains(point) { return (annotation, .move) }; case let .polygon(polygon): let path = CGMutablePath(); if let first = polygon.points.first { path.move(to: transform.canvasPoint(from: first)); for item in polygon.points.dropFirst() { path.addLine(to: transform.canvasPoint(from: item)) }; path.closeSubpath(); if path.contains(point) { return (annotation, .move) } } }
        }
        return nil
    }

    private func handlePoints(_ rect: CGRect) -> [CGPoint] { [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.midX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)] }
    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}

private enum EditMode { case move, boxHandle(Int), vertex(Int) }
private enum DragState { case box(start: CGPoint, current: CGPoint); case pan(start: CGPoint, origin: CGPoint); case edit(id: UUID, original: AnnotationGeometry, mode: EditMode, start: NormalizedPoint, current: AnnotationGeometry) }

private struct CanvasMapping {
    let imageSize: PixelSize
    let imageFrame: CGRect

    func canvasPoint(from point: NormalizedPoint) -> CGPoint {
        CGPoint(x: imageFrame.minX + CGFloat(point.x) * imageFrame.width, y: imageFrame.minY + CGFloat(point.y) * imageFrame.height)
    }

    func normalizedPoint(from point: CGPoint, clamp: Bool) -> NormalizedPoint {
        guard imageFrame.width > 0, imageFrame.height > 0 else { return .init(x: 0, y: 0) }
        let value = NormalizedPoint(x: Double((point.x - imageFrame.minX) / imageFrame.width), y: Double((point.y - imageFrame.minY) / imageFrame.height))
        return clamp ? value.clamped() : value
    }

    func canvasRect(from box: BoundingBox) -> CGRect {
        CGRect(x: imageFrame.minX + CGFloat(box.x) * imageFrame.width, y: imageFrame.minY + CGFloat(box.y) * imageFrame.height, width: CGFloat(box.width) * imageFrame.width, height: CGFloat(box.height) * imageFrame.height)
    }

    func normalizedBox(from rect: CGRect, clamp: Bool) -> BoundingBox {
        guard imageFrame.width > 0, imageFrame.height > 0 else { return .init(x: 0, y: 0, width: 0, height: 0) }
        let box = BoundingBox(x: Double((rect.minX - imageFrame.minX) / imageFrame.width), y: Double((rect.minY - imageFrame.minY) / imageFrame.height), width: Double(rect.width / imageFrame.width), height: Double(rect.height / imageFrame.height))
        return clamp ? box.clamped() : box
    }
}

private extension NSColor {
    convenience init(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted); var number: UInt64 = 0; Scanner(string: value).scanHexInt64(&number)
        self.init(srgbRed: CGFloat(number >> 16 & 0xFF) / 255, green: CGFloat(number >> 8 & 0xFF) / 255, blue: CGFloat(number & 0xFF) / 255, alpha: 1)
    }
}
