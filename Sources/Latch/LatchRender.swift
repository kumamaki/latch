import AppKit
import Foundation
import SwiftUI

#if DEBUG
    import CoreText
#endif

extension EnvironmentValues {
    /// True while Latch is rasterizing a SwiftUI subtree offscreen with
    /// `ImageRenderer`. Latch modifiers short-circuit when true so probes
    /// neither paint placeholders nor mutate the live catalog.
    @Entry public var isLatchRendering = false
}

/// Scrubbing sweep configuration for a multi-frame `render` contact sheet.
public struct LatchRenderSweep: Sendable, Equatable, Codable {
    public static let minimumSteps = 2
    public static let maximumSteps = 24

    public let scrub: String
    public let from: Double
    public let to: Double
    public let steps: Int

    public init(scrub: String, from: Double, to: Double, steps: Int) {
        self.scrub = scrub
        self.from = from
        self.to = to
        self.steps = steps
    }
}

/// Options for an offscreen `render` capture of a `LatchRenderable` subtree.
public struct LatchRenderOptions: Sendable, Equatable {
    public static let maximumScale = 4.0

    public let scale: Double?
    public let presentation: LatchScreenshotPresentation?
    public let sweep: LatchRenderSweep?

    public init(
        scale: Double? = nil,
        presentation: LatchScreenshotPresentation? = nil,
        sweep: LatchRenderSweep? = nil
    ) {
        self.scale = scale
        self.presentation = presentation
        self.sweep = sweep
    }
}

/// Metadata returned by `render`.
public struct LatchRenderResult: Sendable, Equatable, Encodable {
    public let path: String
    public let width: Int
    public let height: Int
    public let scale: Double
    public let frames: Int
    public let note: String

    public init(
        path: String,
        width: Int,
        height: Int,
        scale: Double,
        frames: Int,
        note: String
    ) {
        self.path = path
        self.width = width
        self.height = height
        self.scale = scale
        self.frames = frames
        self.note = note
    }
}

/// Renders `content` live while registering it as a renderable catalog node
/// for `latch render <id>`. Compiles in Release as a pass-through.
public struct LatchRenderable<Content: View>: View {
    private let id: String
    private let role: String
    private let title: String?
    private let description: String?
    private let window: String?
    private let parent: String?
    private let content: @MainActor () -> Content

    #if DEBUG
        @Environment(\.self) private var environment
        @State private var token = LatchCatalog.Token()
        @State private var state = LatchRenderState()
    #endif

    public init(
        _ id: String,
        role: String = "group",
        title: String? = nil,
        description: String? = nil,
        window: String? = nil,
        parent: String? = nil,
        @ViewBuilder content: @MainActor @escaping () -> Content
    ) {
        self.id = id
        self.role = role
        self.title = title
        self.description = description
        self.window = window
        self.parent = parent
        self.content = content
    }

    public var body: some View {
        #if DEBUG
            if environment.isLatchRendering {
                content()
            } else {
                let _ = state.update(builder: { AnyView(content()) }, environment: environment)
                content()
                    .onGeometryChange(for: CGSize.self) { proxy in
                        proxy.size
                    } action: { newSize in
                        state.measuredSize = newSize
                    }
                    .background {
                        LatchControlProbe { hostWindow, probe in
                            report(host: hostWindow, probe: probe)
                        }
                        .accessibilityHidden(true)
                    }
                    .onAppear { publish(host: nil) }
                    .onChange(of: id) { _, _ in publish(host: nil) }
                    .onChange(of: role) { _, _ in publish(host: nil) }
                    .onChange(of: title) { _, _ in publish(host: nil) }
                    .onChange(of: description) { _, _ in publish(host: nil) }
                    .onChange(of: window) { _, _ in publish(host: nil) }
                    .onChange(of: parent) { _, _ in publish(host: nil) }
                    .onDisappear { cleanup() }
            }
        #else
            content()
        #endif
    }

    #if DEBUG
        private func report(host: NSWindow?, probe: NSView?) {
            guard !Latch.isPreviewProcess else { return }
            guard let host else {
                LatchCatalog.setFrameSource(id: id, token: token, view: nil)
                state.window = nil
                state.host = nil
                return
            }
            LatchCatalog.setFrameSource(id: id, token: token, view: probe)
            state.window = host
            let identity = ObjectIdentifier(host)
            guard identity != state.host else { return }
            state.host = identity
            publish(host: host)
        }

        private func publish(host: NSWindow?) {
            guard !Latch.isPreviewProcess else { return }
            if let registeredID = state.registeredID, registeredID != id {
                LatchCatalog.unregisterRenderSource(id: registeredID, token: token)
                LatchCatalog.unregister(id: registeredID, token: token)
                state.registeredID = nil
            }
            if let host {
                state.window = host
            }
            do {
                try LatchCatalog.register(
                    id: id,
                    role: role,
                    title: title,
                    description: description,
                    actions: ["render"],
                    window: window,
                    parent: parent,
                    kind: .label,
                    token: token,
                    host: host ?? state.window
                )
                LatchCatalog.registerRenderSource(
                    id: id,
                    token: token,
                    source: state.makeSource(token: token)
                )
                state.registeredID = id
            } catch {
                assertionFailure("Latch catalog: \(error)")
            }
        }

        private func cleanup() {
            let registeredID = state.registeredID ?? id
            LatchCatalog.unregisterRenderSource(id: registeredID, token: token)
            LatchCatalog.unregister(id: registeredID, token: token)
            state.registeredID = nil
        }
    #endif
}

/// Pairs an offscreen renderable subtree with an existing catalog id.
/// Compiles in Release as a pass-through.
private struct LatchRenderableModifier<Rendered: View>: ViewModifier {
    let id: String
    let renderContent: @MainActor () -> Rendered

    #if DEBUG
        @Environment(\.self) private var environment
        @State private var token = LatchCatalog.Token()
        @State private var state = LatchRenderState()
    #endif

    func body(content: Content) -> some View {
        #if DEBUG
            if environment.isLatchRendering {
                content
            } else {
                let _ = state.update(
                    builder: { AnyView(renderContent()) },
                    environment: environment
                )
                content
                    .onGeometryChange(for: CGSize.self) { proxy in
                        proxy.size
                    } action: { newSize in
                        state.measuredSize = newSize
                    }
                    .background {
                        LatchControlProbe { hostWindow, _ in
                            state.window = hostWindow
                        }
                        .accessibilityHidden(true)
                    }
                    .onAppear { publish() }
                    .onChange(of: id) { previous, _ in
                        LatchCatalog.unregisterRenderSource(id: previous, token: token)
                        publish()
                    }
                    .onDisappear {
                        LatchCatalog.unregisterRenderSource(
                            id: state.registeredID ?? id, token: token)
                        state.registeredID = nil
                    }
            }
        #else
            content
        #endif
    }

    #if DEBUG
        private func publish() {
            guard !Latch.isPreviewProcess else { return }
            if let registeredID = state.registeredID, registeredID != id {
                LatchCatalog.unregisterRenderSource(id: registeredID, token: token)
            }
            LatchCatalog.registerRenderSource(
                id: id,
                token: token,
                source: state.makeSource(token: token)
            )
            state.registeredID = id
        }
    #endif
}

extension View {
    /// Registers a pure SwiftUI subtree to render when `latch render <id>`
    /// targets an existing catalog id. Compiles in Release as a pass-through.
    public func latchRenderable<Rendered: View>(
        _ id: String,
        @ViewBuilder content: @MainActor @escaping () -> Rendered
    ) -> some View {
        modifier(LatchRenderableModifier(id: id, renderContent: content))
    }
}

#if DEBUG
    /// Non-observable state box updated during `body` without invalidating SwiftUI.
    @MainActor
    private final class LatchRenderState {
        var builder: (@MainActor () -> AnyView)?
        var environment: EnvironmentValues?
        var measuredSize: CGSize = .zero
        weak var window: NSWindow?
        var host: ObjectIdentifier?
        var registeredID: String?

        func update(builder: @escaping @MainActor () -> AnyView, environment: EnvironmentValues) {
            self.builder = builder
            self.environment = environment
        }

        func makeSource(token: LatchCatalog.Token) -> LatchCatalog.RenderSource {
            LatchCatalog.RenderSource(
                token: ObjectIdentifier(token),
                makeView: { [weak self] in self?.builder?() ?? AnyView(EmptyView()) },
                environment: { [weak self] in self?.environment },
                measuredSize: { [weak self] in self?.measuredSize ?? .zero },
                window: { [weak self] in self?.window }
            )
        }
    }

    /// In-process SwiftUI `ImageRenderer` capture for a registered renderable
    /// catalog entry, including Metal `.layerEffect` / `.colorEffect` /
    /// `.distortionEffect` shaders.
    public enum LatchRender {
        public static let renderNote =
            "Rendered offscreen with SwiftUI ImageRenderer (includes Metal "
            + "layerEffect/colorEffect/distortionEffect shaders). AppKit-backed "
            + "views (NSTextField, NSScrollView, custom NSViewRepresentable) "
            + "render blank or as placeholders; use screenshot for whole-window "
            + "AppKit chrome."

        private struct SweepFrame {
            let label: String
            let image: CGImage
        }

        @MainActor
        public static func capture(
            id: String,
            options: LatchRenderOptions = LatchRenderOptions(),
            app: String
        ) async throws -> LatchRenderResult {
            try validate(options: options, id: id)
            let initialSource = try lookupRenderSource(id: id)
            let backingScale = resolveScale(requested: options.scale, source: initialSource)

            let image: CGImage
            let frameCount: Int
            let suffix: String
            if let sweep = options.sweep {
                let frames = try await captureSweep(
                    id: id,
                    sweep: sweep,
                    scale: backingScale
                )
                image = try contactSheetImage(frames: frames, backingScale: backingScale)
                frameCount = frames.count
                suffix = "-sweep-\(sweep.steps)"
            } else {
                image = try renderImage(source: initialSource, id: id, scale: backingScale)
                frameCount = 1
                suffix = "-render"
            }

            let finalImage: CGImage
            if let presentation = options.presentation {
                finalImage = try LatchScreenshot.framedImage(
                    image,
                    presentation: presentation,
                    backingScale: CGFloat(backingScale)
                )
            } else {
                finalImage = image
            }

            let png = try LatchScreenshot.pngData(from: finalImage)
            let directory = try LatchPaths.screenshotDirectory(app: app)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let idComponent = LatchScreenshot.fileComponent(id)
            let presentationSuffix =
                options.presentation.map {
                    "-frame-\($0.frameColor.rawValue)-\(LatchScreenshot.fileComponent(String($0.padding)))pt"
                } ?? ""
            let stamp = LatchScreenshot.safeTimestamp()
            let url = directory.appendingPathComponent(
                "\(idComponent)\(suffix)\(presentationSuffix)-\(stamp).png")
            do {
                try png.write(to: url, options: .atomic)
            } catch {
                throw LatchError.renderFailed(reason: error.localizedDescription)
            }

            return LatchRenderResult(
                path: url.path,
                width: finalImage.width,
                height: finalImage.height,
                scale: backingScale,
                frames: frameCount,
                note: renderNote
            )
        }

        @MainActor
        private static func validate(options: LatchRenderOptions, id: String) throws {
            if let presentation = options.presentation {
                guard presentation.padding.isFinite,
                    (0...LatchScreenshotPresentation.maximumPadding).contains(
                        presentation.padding)
                else {
                    throw LatchError.invalidValue(
                        id: id,
                        value: String(presentation.padding),
                        expected:
                            "padding between 0 and \(Int(LatchScreenshotPresentation.maximumPadding)) points"
                    )
                }
            }
            if let scale = options.scale {
                guard scale.isFinite, scale > 0, scale <= LatchRenderOptions.maximumScale else {
                    throw LatchError.invalidValue(
                        id: id,
                        value: String(scale),
                        expected: "scale between 0 and \(Int(LatchRenderOptions.maximumScale))"
                    )
                }
            }
            if let sweep = options.sweep {
                guard !sweep.scrub.isEmpty else {
                    throw LatchError.invalidValue(
                        id: id, value: "", expected: "a non-empty scrub catalog id")
                }
                guard sweep.from.isFinite, sweep.to.isFinite else {
                    throw LatchError.invalidValue(
                        id: sweep.scrub,
                        value: "\(sweep.from)...\(sweep.to)",
                        expected: "finite sweep bounds"
                    )
                }
                guard
                    (LatchRenderSweep.minimumSteps...LatchRenderSweep.maximumSteps).contains(
                        sweep.steps)
                else {
                    throw LatchError.invalidValue(
                        id: sweep.scrub,
                        value: String(sweep.steps),
                        expected:
                            "steps between \(LatchRenderSweep.minimumSteps) and \(LatchRenderSweep.maximumSteps)"
                    )
                }
            }
        }

        @MainActor
        private static func lookupRenderSource(id: String) throws -> LatchCatalog.RenderSource {
            do {
                return try LatchCatalog.renderSource(id: id)
            } catch let error as LatchCatalog.Error {
                throw LatchError(error)
            }
        }

        @MainActor
        private static func resolveScale(
            requested: Double?,
            source: LatchCatalog.RenderSource
        ) -> Double {
            if let requested { return requested }
            if let backing = source.window()?.backingScaleFactor, backing > 0 {
                return Double(backing)
            }
            if let displayScale = source.environment()?.displayScale, displayScale > 0 {
                return Double(displayScale)
            }
            return 2.0
        }

        @MainActor
        private static func renderImage(
            source: LatchCatalog.RenderSource,
            id: String,
            scale: Double
        ) throws -> CGImage {
            let base = source.makeView()
            let capturedEnv = source.environment()
            let wrapped = base.transformEnvironment(\.self) { values in
                if let capturedEnv {
                    values = capturedEnv
                }
                values.isLatchRendering = true
            }
            let renderer = ImageRenderer(content: wrapped)
            renderer.scale = CGFloat(scale)
            let size = source.measuredSize()
            if size.width >= 1, size.height >= 1 {
                renderer.proposedSize = ProposedViewSize(size)
            } else {
                renderer.proposedSize = .unspecified
            }
            guard let image = renderer.cgImage, image.width >= 1, image.height >= 1 else {
                throw LatchError.renderFailed(
                    reason: "ImageRenderer produced an empty image for \(id).")
            }
            return image
        }

        @MainActor
        private static func captureSweep(
            id: String,
            sweep: LatchRenderSweep,
            scale: Double
        ) async throws -> [SweepFrame] {
            let scrubNode: LatchCatalog.Node
            do {
                scrubNode = try LatchCatalog.find(id: sweep.scrub)
            } catch let error as LatchCatalog.Error {
                throw LatchError(error)
            }
            guard scrubNode.enabled else {
                throw LatchError.disabled(id: sweep.scrub)
            }
            guard scrubNode.actions.contains("set") else {
                throw LatchError.actionUnavailable(id: sweep.scrub, action: "set")
            }

            var frames: [SweepFrame] = []
            frames.reserveCapacity(sweep.steps)
            for index in 0..<sweep.steps {
                let fraction = Double(index) / Double(sweep.steps - 1)
                let value = sweep.from + (sweep.to - sweep.from) * fraction
                let wireValue = String(format: "%.4f", value)
                let caption = String(format: "%.3f", value)
                do {
                    try LatchCatalog.set(id: sweep.scrub, value: wireValue)
                } catch let error as LatchCatalog.Error {
                    throw LatchError(error)
                }
                CATransaction.flush()
                try await Task.sleep(for: .milliseconds(16))
                let source = try lookupRenderSource(id: id)
                let image = try renderImage(source: source, id: id, scale: scale)
                frames.append(SweepFrame(label: caption, image: image))
            }
            return frames
        }

        private static func contactSheetImage(
            frames: [SweepFrame],
            backingScale: Double
        ) throws -> CGImage {
            guard !frames.isEmpty else {
                throw LatchError.renderFailed(reason: "Sweep produced no frames.")
            }
            let scale = CGFloat(backingScale)
            let columns = min(frames.count, 4)
            let rows = (frames.count + columns - 1) / columns
            let maxWidth = frames.map(\.image.width).max() ?? 1
            let maxHeight = frames.map(\.image.height).max() ?? 1
            let gap = max(8, Int((12 * scale).rounded(.up)))
            let labelHeight = max(18, Int((24 * scale).rounded(.up)))
            let cellWidth = maxWidth
            let cellHeight = maxHeight + labelHeight
            let totalWidth = gap + columns * (cellWidth + gap)
            let totalHeight = gap + rows * (cellHeight + gap)

            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            guard
                let context = CGContext(
                    data: nil,
                    width: totalWidth,
                    height: totalHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else {
                throw LatchError.renderFailed(reason: "Could not allocate contact sheet bitmap.")
            }

            let canvas = CGRect(x: 0, y: 0, width: totalWidth, height: totalHeight)
            context.setFillColor(CGColor(gray: 0.12, alpha: 1))
            context.fill(canvas)

            let fontSize = max(10, 12 * scale)
            let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
            let labelColor = NSColor(white: 0.92, alpha: 1)

            for (index, frame) in frames.enumerated() {
                let row = index / columns
                let col = index % columns
                let cellX = gap + col * (cellWidth + gap)
                let cellTopY = totalHeight - gap - row * (cellHeight + gap)
                let cellBottomY = cellTopY - cellHeight

                let tileRect = CGRect(
                    x: cellX, y: cellBottomY, width: cellWidth, height: cellHeight)
                context.setFillColor(CGColor(gray: 0.18, alpha: 1))
                context.fill(tileRect)

                let drawX = cellX + (cellWidth - frame.image.width) / 2
                let drawY = cellBottomY + labelHeight + (maxHeight - frame.image.height) / 2
                let imageRect = CGRect(
                    x: drawX,
                    y: drawY,
                    width: frame.image.width,
                    height: frame.image.height
                )
                context.draw(frame.image, in: imageRect)

                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: labelColor,
                ]
                let line = CTLineCreateWithAttributedString(
                    NSAttributedString(string: frame.label, attributes: attributes))
                let textBounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
                let textX = CGFloat(cellX) + (CGFloat(cellWidth) - textBounds.width) / 2
                let textY =
                    CGFloat(cellBottomY) + (CGFloat(labelHeight) - fontSize) / 2 + 2 * scale
                context.saveGState()
                context.textMatrix = .identity
                context.textPosition = CGPoint(x: textX, y: textY)
                CTLineDraw(line, context)
                context.restoreGState()
            }

            guard let sheet = context.makeImage() else {
                throw LatchError.renderFailed(reason: "Could not compose contact sheet.")
            }
            return sheet
        }
    }
#endif
