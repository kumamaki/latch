import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Latch

private struct ProbeEnvKey: EnvironmentKey {
    static let defaultValue = "default"
}

extension EnvironmentValues {
    fileprivate var probeValue: String {
        get { self[ProbeEnvKey.self] }
        set { self[ProbeEnvKey.self] = newValue }
    }
}

private struct EnvShaderSpecimen: View {
    @Environment(\.probeValue) private var probeValue
    @Environment(\.colorScheme) private var colorScheme

    let onEvaluate: @MainActor (String, ColorScheme) -> Void

    var body: some View {
        let _ = onEvaluate(probeValue, colorScheme)
        ZStack {
            Rectangle()
                .fill(colorScheme == .dark ? Color.red : Color.blue)
            Circle()
                .fill(Color.yellow)
                .frame(width: 24, height: 24)
            Text(probeValue)
                .foregroundStyle(.white)
                .latch("specimen.button", press: {})
        }
        .frame(width: 120, height: 80)
    }
}

@Suite(.serialized)
@MainActor
struct LatchRenderTests {
    init() {
        LatchCatalog.reset()
        Latch.previewProcessOverride = nil
    }

    @Test("LatchRenderable captures live environment, scale, and avoids probe placeholders")
    func renderableCapturesEnvironmentAndSkipsProbes() async throws {
        var evaluations: [(value: String, scheme: ColorScheme)] = []
        let root = LatchRenderable("specimen.card", title: "Card", window: "render-test") {
            EnvShaderSpecimen { value, scheme in
                evaluations.append((value, scheme))
            }
        }
        .environment(\.probeValue, "live-env")
        .environment(\.colorScheme, .dark)

        let fixture = HostedRenderWindow(rootView: root)
        defer { fixture.close() }

        let node = try LatchCatalog.find(id: "specimen.card")
        #expect(node.role == "group")
        #expect(node.actions == ["render"])

        let beforeCount = LatchCatalog.snapshot().count
        let app = uniqueApp()
        let result = try await LatchRender.capture(id: "specimen.card", app: app)
        defer { try? FileManager.default.removeItem(atPath: result.path) }

        #expect(result.frames == 1)
        #expect(result.width == 120 * Int(result.scale))
        #expect(result.height == 80 * Int(result.scale))
        #expect(FileManager.default.fileExists(atPath: result.path))
        #expect(evaluations.last?.value == "live-env")
        #expect(evaluations.last?.scheme == .dark)
        #expect(LatchCatalog.snapshot().count == beforeCount)

        let image = try loadCGImage(at: result.path)
        let rep = NSBitmapImageRep(cgImage: image)
        let corner = try #require(rep.colorAt(x: 4, y: 4)?.usingColorSpace(.sRGB))
        #expect(corner.redComponent > 0.7)
        #expect(corner.blueComponent < 0.5)
    }

    @Test("latchRenderable modifier pairs with existing catalog id and cleans up")
    func modifierPairsWithExistingID() async throws {
        let root = Text("Live")
            .frame(width: 100, height: 60)
            .latch("paired.item", role: "group", window: "render-test")
            .latchRenderable("paired.item") {
                Rectangle()
                    .fill(Color.green)
                    .frame(width: 100, height: 60)
            }

        let fixture = HostedRenderWindow(rootView: root)
        defer { fixture.close() }

        let result = try await LatchRender.capture(
            id: "paired.item",
            options: LatchRenderOptions(scale: 1),
            app: uniqueApp()
        )
        defer { try? FileManager.default.removeItem(atPath: result.path) }
        #expect(result.width == 100)
        #expect(result.height == 60)

        let image = try loadCGImage(at: result.path)
        let rep = NSBitmapImageRep(cgImage: image)
        let center = try #require(rep.colorAt(x: 50, y: 30)?.usingColorSpace(.sRGB))
        #expect(center.greenComponent > 0.6)
    }

    @Test("render fails loud for missing or non-renderable catalog ids")
    func failLoudOnMissingOrNonRenderable() async throws {
        let token = LatchCatalog.Token()
        try LatchCatalog.register(
            id: "plain.button",
            role: "button",
            token: token,
            press: { _ in }
        )

        await #expect(throws: LatchError.self) {
            _ = try await LatchRender.capture(id: "missing.id", app: uniqueApp())
        }
        await #expect(throws: LatchError.self) {
            _ = try await LatchRender.capture(id: "plain.button", app: uniqueApp())
        }
    }

    @Test("render sweep drives scrub control and builds contact sheet")
    func sweepBuildsContactSheet() async throws {
        @MainActor
        final class ScrubStore {
            var progress = 0.0
        }

        let store = ScrubStore()
        let root = VStack {
            LatchRenderable("sweep.stage", window: "render-test") {
                Rectangle()
                    .fill(Color.blue)
                    .frame(width: 80, height: 40)
            }
            Text("Scrub")
                .latch(
                    "sweep.scrub",
                    role: "slider",
                    value: { String(format: "%.3f", store.progress) },
                    window: "render-test",
                    set: { raw in
                        store.progress = try LatchCatalog.parseDouble(id: "sweep.scrub", raw)
                    }
                )
        }
        let fixture = HostedRenderWindow(rootView: root)
        defer { fixture.close() }

        let sweep = LatchRenderSweep(scrub: "sweep.scrub", from: 0.2, to: 0.8, steps: 4)
        let result = try await LatchRender.capture(
            id: "sweep.stage",
            options: LatchRenderOptions(scale: 1, sweep: sweep),
            app: uniqueApp()
        )
        defer { try? FileManager.default.removeItem(atPath: result.path) }

        #expect(result.frames == 4)
        #expect(abs(store.progress - 0.8) < 0.001)
        #expect(result.width > 80 * 4)
        #expect(result.height > 40)
        #expect(FileManager.default.fileExists(atPath: result.path))
    }

    @Test("render rejects invalid scale, padding, and sweep steps")
    func validatesOptions() async throws {
        let root = LatchRenderable("invalid.opts", window: "render-test") {
            Color.red.frame(width: 40, height: 40)
        }
        let fixture = HostedRenderWindow(rootView: root)
        defer { fixture.close() }

        await #expect(throws: LatchError.self) {
            _ = try await LatchRender.capture(
                id: "invalid.opts",
                options: LatchRenderOptions(scale: 0),
                app: uniqueApp()
            )
        }
        await #expect(throws: LatchError.self) {
            _ = try await LatchRender.capture(
                id: "invalid.opts",
                options: LatchRenderOptions(
                    sweep: LatchRenderSweep(scrub: "s", from: 0, to: 1, steps: 1)
                ),
                app: uniqueApp()
            )
        }
    }

    private func loadCGImage(at path: String) throws -> CGImage {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let rep = try #require(NSBitmapImageRep(data: data))
        return try #require(rep.cgImage)
    }

    private func uniqueApp() -> String {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return "latch-render-\(suffix)"
    }
}

@MainActor
private final class HostedRenderWindow {
    private let window: NSWindow

    init<Content: View>(rootView: Content) {
        let app = NSApplication.shared
        if !app.isRunning {
            app.setActivationPolicy(.accessory)
            app.finishLaunching()
        }
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 240, height: 180),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: rootView)
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        self.window = window
    }

    func close() {
        window.orderOut(nil)
        window.close()
    }
}
