import SwiftUI

/// Registers a catalog entry for the lifetime of this view.
///
/// Compiles in Release. The DEBUG socket is separate (`Latch.start`).
public struct LatchControl: ViewModifier {
    private let id: String
    private let role: String
    private let title: String?
    private let value: () -> String?
    private let enabled: Bool
    private let actions: [String]
    private let window: String?
    private let press: ((String?) throws -> Void)?
    private let set: ((String) throws -> Void)?
    @State private var token = LatchCatalog.Token()

    public init(
        id: String,
        role: String,
        title: String? = nil,
        value: @escaping () -> String? = { nil },
        enabled: Bool = true,
        actions: [String] = [],
        window: String? = nil,
        press: ((String?) throws -> Void)? = nil,
        set: ((String) throws -> Void)? = nil
    ) {
        self.id = id
        self.role = role
        self.title = title
        self.value = value
        self.enabled = enabled
        self.actions = actions
        self.window = window
        self.press = press
        self.set = set
    }

    public func body(content: Content) -> some View {
        content
            .onAppear { publish() }
            .onChange(of: id) { _, _ in publish() }
            .onChange(of: role) { _, _ in publish() }
            .onChange(of: title) { _, _ in publish() }
            .onChange(of: enabled) { _, _ in publish() }
            .onChange(of: actions) { _, _ in publish() }
            .onDisappear {
                LatchCatalog.unregister(id: id, token: token)
            }
    }

    private func publish() {
        do {
            try LatchCatalog.register(
                id: id,
                role: role,
                title: title,
                value: value,
                enabled: enabled,
                actions: actions,
                window: window,
                token: token,
                press: press,
                set: set
            )
        } catch {
            assertionFailure("Latch catalog: \(error)")
        }
    }
}

extension View {
    /// Host / label: visible in dump, no press or set.
    public func latch(
        _ id: String,
        role: String,
        title: String? = nil,
        value: @escaping @autoclosure () -> String? = nil,
        enabled: Bool = true,
        window: String? = nil
    ) -> some View {
        modifier(
            LatchControl(
                id: id,
                role: role,
                title: title,
                value: value,
                enabled: enabled,
                window: window
            )
        )
    }

    /// Button / chrome: press with no named actions.
    public func latch(
        _ id: String,
        role: String = "button",
        title: String? = nil,
        value: @escaping @autoclosure () -> String? = nil,
        enabled: Bool = true,
        window: String? = nil,
        press: @escaping () -> Void
    ) -> some View {
        modifier(
            LatchControl(
                id: id,
                role: role,
                title: title,
                value: value,
                enabled: enabled,
                actions: ["press"],
                window: window,
                press: { _ in press() }
            )
        )
    }

    /// Field: live value + set into the view model.
    public func latch(
        _ id: String,
        role: String = "textfield",
        title: String? = nil,
        value: @escaping () -> String?,
        enabled: Bool = true,
        window: String? = nil,
        set: @escaping (String) throws -> Void
    ) -> some View {
        modifier(
            LatchControl(
                id: id,
                role: role,
                title: title,
                value: value,
                enabled: enabled,
                actions: ["set"],
                window: window,
                set: { try set($0) }
            )
        )
    }

    /// Switch / checkbox: `true` / `false`.
    public func latch(
        _ id: String,
        title: String? = nil,
        enabled: Bool = true,
        window: String? = nil,
        bool: Binding<Bool>
    ) -> some View {
        modifier(
            LatchControl(
                id: id,
                role: "checkbox",
                title: title,
                value: { LatchCatalog.formatBool(bool.wrappedValue) },
                enabled: enabled,
                actions: ["set"],
                window: window,
                set: { bool.wrappedValue = try LatchCatalog.parseBool(id: id, $0) }
            )
        )
    }

    /// Popup / option group: enum rawValue.
    public func latch<Value: RawRepresentable>(
        _ id: String,
        title: String? = nil,
        enabled: Bool = true,
        window: String? = nil,
        selection: Binding<Value>
    ) -> some View where Value.RawValue == String {
        modifier(
            LatchControl(
                id: id,
                role: "popup",
                title: title,
                value: { selection.wrappedValue.rawValue },
                enabled: enabled,
                actions: ["set"],
                window: window,
                set: {
                    selection.wrappedValue = try LatchCatalog.parseEnum(id: id, $0)
                }
            )
        )
    }

    /// Number field: decimal integer.
    public func latch(
        _ id: String,
        title: String? = nil,
        enabled: Bool = true,
        window: String? = nil,
        integer: Binding<Int>
    ) -> some View {
        modifier(
            LatchControl(
                id: id,
                role: "textfield",
                title: title,
                value: { String(integer.wrappedValue) },
                enabled: enabled,
                actions: ["set"],
                window: window,
                set: { integer.wrappedValue = try LatchCatalog.parseInt(id: id, $0) }
            )
        )
    }

    /// Row / control with named actions.
    public func latch(
        _ id: String,
        role: String,
        title: String? = nil,
        value: @escaping @autoclosure () -> String? = nil,
        enabled: Bool = true,
        actions: [String],
        window: String? = nil,
        press: @escaping (String?) throws -> Void
    ) -> some View {
        modifier(
            LatchControl(
                id: id,
                role: role,
                title: title,
                value: value,
                enabled: enabled,
                actions: actions,
                window: window,
                press: press
            )
        )
    }
}
