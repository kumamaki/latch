#if DEBUG
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
                children = nest(other, parent: nil)
            } else {
                for windowNode in windowNodes {
                    let name = windowNode.window ?? String(windowNode.id.dropFirst("window.".count))
                    let inWindow = other.filter { $0.window == name }
                    children.append(
                        branch(windowNode, children: nest(inWindow, parent: nil))
                    )
                }
                let orphans = other.filter { node in
                    guard let name = node.window else { return true }
                    return !windowNodes.contains { $0.window == name || $0.id == "window.\(name)" }
                }
                children.append(contentsOf: nest(orphans, parent: nil))
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

        /// Recursively nest nodes that name an existing sibling as `parent`.
        /// Unknown parents stay at this level so dump still shows them.
        private static func nest(
            _ nodes: [LatchCatalog.Node],
            parent: String?
        ) -> [LatchAXNode] {
            let nestedIDs = Set(nodes.map(\.id))

            return
                nodes
                .filter { node in
                    let claimed = node.parent.flatMap { nestedIDs.contains($0) ? $0 : nil }
                    return claimed == parent
                }
                .map { node in
                    branch(node, children: nest(nodes, parent: node.id))
                }
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
                children: children,
                window: node.window,
                parent: node.parent,
                kind: node.kind,
                choices: node.choices,
                description: node.description
            )
        }
    }
#endif
