import Foundation

/// Maps the DEBUG scene catalog onto the `ax *` response shape.
public enum LatchCatalogDump {
    @MainActor
    public static func tree(window: String?, title: String) -> LatchAXNode {
        LatchCatalog.syncWindows()
        let nodes = LatchCatalog.snapshot(window: window)
        let windowNodes = nodes.filter { $0.role == "window" }
        let other = nodes.filter { $0.role != "window" }

        var children: [LatchAXNode] = []
        if windowNodes.isEmpty {
            children = other.map(leaf)
        } else {
            for windowNode in windowNodes {
                let name = windowNode.window ?? String(windowNode.id.dropFirst("window.".count))
                let nested = other.filter { $0.window == name }.map(leaf)
                children.append(branch(windowNode, children: nested))
            }
            let orphans = other.filter { node in
                guard let name = node.window else { return true }
                return !windowNodes.contains { $0.window == name || $0.id == "window.\(name)" }
            }
            children.append(contentsOf: orphans.map(leaf))
        }

        return LatchAXNode(
            id: nil,
            role: "application",
            title: title,
            value: nil,
            enabled: true,
            actions: [],
            frame: .zero,
            children: children
        )
    }

    @MainActor
    public static func node(id: String) throws -> LatchAXNode {
        LatchCatalog.syncWindows()
        return leaf(try LatchCatalog.find(id: id))
    }

    private static func leaf(_ node: LatchCatalog.Node) -> LatchAXNode {
        branch(node, children: [])
    }

    private static func branch(
        _ node: LatchCatalog.Node,
        children: [LatchAXNode]
    ) -> LatchAXNode {
        LatchAXNode(
            id: node.id,
            role: node.role,
            title: node.title,
            value: node.value,
            enabled: node.enabled,
            actions: node.actions,
            frame: .zero,
            children: children
        )
    }
}
