import AppKit
import Testing

@testable import Latch

struct LatchCoverageTests {
    private static let button = NSRect(x: 100, y: 100, width: 40, height: 20)

    private func control(
        _ title: String, frame: NSRect = button, identifier: String? = nil
    ) -> LatchAXControl {
        LatchAXControl(role: "button", title: title, identifier: identifier, frame: frame)
    }

    @Test(
        "a control is covered by its own id or a same-size frame, not by a container",
        arguments: [
            (
                "registered at the same frame",
                [LatchCoverage.Registered(id: "save", frame: button)],
                nil as String?, true
            ),
            (
                "registered a little off",
                [LatchCoverage.Registered(id: "save", frame: button.offsetBy(dx: 4, dy: 2))],
                nil, true
            ),
            (
                "only a parent stack registered",
                [
                    LatchCoverage.Registered(
                        id: "toolbar", frame: NSRect(x: 0, y: 0, width: 400, height: 200))
                ],
                nil, false
            ),
            (
                "AppKit identifier names a registered id",
                [], "save", true
            ),
            (
                "AppKit identifier names nothing registered",
                [], "stray", false
            ),
        ])
    func coverage(
        _ name: String, registered: [LatchCoverage.Registered], identifier: String?,
        isCovered: Bool
    ) {
        let reply = LatchCoverage.classify(
            controls: [control("Save", identifier: identifier)],
            registered: registered,
            registeredIDs: ["save"])
        #expect(reply.covered == (isCovered ? 1 : 0), Comment(rawValue: name))
        #expect(reply.uncovered.isEmpty == isCovered, Comment(rawValue: name))
    }

    @Test("a gap names the smallest registered frame around it")
    func gapNamesNearestContainer() {
        let reply = LatchCoverage.classify(
            controls: [control("Stray")],
            registered: [
                .init(id: "window.body", frame: NSRect(x: 0, y: 0, width: 800, height: 600)),
                .init(id: "toolbar", frame: NSRect(x: 80, y: 80, width: 200, height: 60)),
            ],
            registeredIDs: ["window.body", "toolbar"])
        #expect(reply.uncovered.map(\.near) == ["toolbar"])
    }

    @Test("one control reached over several paths counts once")
    func duplicatesCollapse() {
        let reply = LatchCoverage.classify(
            controls: [control("Menu"), control("Menu"), control("Menu")],
            registered: [], registeredIDs: [])
        #expect(reply.uncovered.count == 1)
    }

    @Test("a registered press id with no control in the probe is reported as unprobed")
    func unprobedIDs() {
        let reply = LatchCoverage.classify(
            controls: [control("Save")],
            registered: [
                .init(id: "save", frame: Self.button, drivable: true),
                .init(
                    id: "glass.add", frame: NSRect(x: 300, y: 300, width: 40, height: 20),
                    drivable: true),
                .init(
                    id: "label", frame: NSRect(x: 500, y: 500, width: 40, height: 20),
                    drivable: false),
            ],
            registeredIDs: ["save", "glass.add", "label"])
        #expect(reply.unprobed == ["glass.add"])
    }
}
