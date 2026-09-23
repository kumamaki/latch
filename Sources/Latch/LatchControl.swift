import SwiftUI

/// Registers a catalog entry for the lifetime of this view.
///
/// Compiles in Release. The DEBUG socket is separate (`Latch.start`).
public struct LatchControl: ViewModifier {
    private let id: String
    private let role: String
    private let title: String?
    private let description: String?
    private let value: () -> String?
    private let enabled: () -> Bool
    private let actions: [String]
    private let window: String?
    private let parent: String?
    private let kind: LatchCatalog.Kind?
    private let choices: [String]?
    private let press: ((String?) throws -> Void)?
    private let set: ((String) throws -> Void)?
    #if DEBUG
        @State private var token = LatchCatalog.Token()
    #endif

    public init(
        id: String,
        role: String,
        title: String? = nil,
        description: String? = nil,
        value: @escaping () -> String? = { nil },
        enabled: @escaping () -> Bool = { true },
        actions: [String] = [],
        window: String? = nil,
        parent: String? = nil,
        kind: LatchCatalog.Kind? = nil,
        choices: [String]? = nil,
        press: ((String?) throws -> Void)? = nil,
        set: ((String) throws -> Void)? = nil
    ) {
        self.id = id
        self.role = role
        self.title = title
        self.description = description
        self.value = value
        self.enabled = enabled
        self.actions = actions
        self.window = window
        self.parent = parent
        self.kind = kind
        self.choices = choices
        self.press = press
        self.set = set
    }

    /// Registers with the DEBUG catalog. In Release the modifier is a
    /// pass-through — the catalog impl is compiled out.
    public func body(content: Content) -> some View {
        #if DEBUG
            let isEnabled = enabled()
            let currentValue = value()
            content
                .onAppear { publish() }
                .onChange(of: id) { _, _ in publish() }
                .onChange(of: role) { _, _ in publish() }
                .onChange(of: title) { _, _ in publish() }
                .onChange(of: description) { _, _ in publish() }
                .onChange(of: actions) { _, _ in publish() }
                .onChange(of: window) { _, _ in publish() }
                .onChange(of: parent) { _, _ in publish() }
                .onChange(of: isEnabled) { _, _ in publish() }
                .onChange(of: currentValue) { _, _ in publish() }
                .onDisappear {
                    LatchCatalog.unregister(id: id, token: token)
                }
        #else
            content
        #endif
    }

    #if DEBUG
        private func publish() {
            guard !Latch.isPreviewProcess else { return }
            do {
                try LatchCatalog.register(
                    id: id,
                    role: role,
                    title: title,
                    description: description,
                    value: value,
                    enabled: enabled,
                    actions: actions,
                    window: window,
                    parent: parent,
                    kind: kind,
                    choices: choices,
                    token: token,
                    press: press,
                    set: set
                )
            } catch {
                assertionFailure("Latch catalog: \(error)")
            }
        }
    #endif
}

extension View {
    /// Host / label: visible in dump, no press or set.
    public func latch(
        _ id: String,
        role: String,
        title: String? = nil,
        description: String? = nil,
        value: @escaping @autoclosure () -> String? = nil,
        enabled: @escaping @autoclosure () -> Bool = true,
        window: String? = nil,
        parent: String? = nil
    ) -> some View {
        modifier(
            LatchControl(
                id: id,
                role: role,
                title: title,
                description: description,
                value: value,
                enabled: enabled,
                window: window,
                parent: parent,
                kind: .label
            )
        )
    }

    /// Button / chrome: press with no named actions.
    public func latch(
        _ id: String,
        role: String = "button",
        title: String? = nil,
        description: String? = nil,
        value: @escaping @autoclosure () -> String? = nil,
        enabled: @escaping @autoclosure () -> Bool = true,
        window: String? = nil,
        parent: String? = nil,
        press: @escaping () -> Void
    ) -> some View {
        modifier(
            LatchControl(
                id: id,
                role: role,
                title: title,
                description: description,
                value: value,
                enabled: enabled,
                actions: ["press"],
                window: window,
                parent: parent,
                kind: .action,
                press: { _ in press() }
            )
        )
    }

    /// Field: `Binding<String>`.
    public func latch(
        _ id: String,
        title: String? = nil,
        description: String? = nil,
        enabled: @escaping @autoclosure () -> Bool = true,
        window: String? = nil,
        parent: String? = nil,
        text: Binding<String>
    ) -> some View {
        modifier(
            LatchControl(
                id: id,
                role: "textfield",
                title: title,
                description: description,
                value: { text.wrappedValue },
                enabled: enabled,
                actions: ["set"],
                window: window,
                parent: parent,
                kind: .text,
                set: { text.wrappedValue = $0 }
            )
        )
    }

    /// Field: live value + set into the view model.
    public func latch(
        _ id: String,
        role: String = "textfield",
        title: String? = nil,
        description: String? = nil,
        value: @escaping () -> String?,
        enabled: @escaping @autoclosure () -> Bool = true,
        window: String? = nil,
        parent: String? = nil,
        set: @escaping (String) throws -> Void
    ) -> some View {
        modifier(
            LatchControl(
                id: id,
                role: role,
                title: title,
                description: description,
                value: value,
                enabled: enabled,
                actions: ["set"],
                window: window,
                parent: parent,
                kind: .text,
                set: { try set($0) }
            )
        )
    }

    /// Switch / checkbox: `true` / `false`.
    public func latch(
        _ id: String,
        title: String? = nil,
        description: String? = nil,
        enabled: @escaping @autoclosure () -> Bool = true,
        window: String? = nil,
        parent: String? = nil,
        bool: Binding<Bool>
    ) -> some View {
        modifier(
            LatchControl(
                id: id,
                role: "checkbox",
                title: title,
                description: description,
                value: { LatchCatalog.formatBool(bool.wrappedValue) },
                enabled: enabled,
                actions: ["set"],
                window: window,
                parent: parent,
                kind: .bool,
                set: { bool.wrappedValue = try LatchCatalog.parseBool(id: id, $0) }
            )
        )
    }

    /// Popup / option group: enum rawValue.
    public func latch<Value: RawRepresentable>(
        _ id: String,
        title: String? = nil,
        description: String? = nil,
        enabled: @escaping @autoclosure () -> Bool = true,
        window: String? = nil,
        parent: String? = nil,
        selection: Binding<Value>
    ) -> some View where Value.RawValue == String {
        modifier(
            LatchControl(
                id: id,
                role: "popup",
                title: title,
                description: description,
                value: { selection.wrappedValue.rawValue },
                enabled: enabled,
                actions: ["set"],
                window: window,
                parent: parent,
                kind: .enum,
                set: {
                    selection.wrappedValue = try LatchCatalog.parseEnum(id: id, $0)
                }
            )
        )
    }

    /// Popup / option group: enum rawValue plus `CaseIterable` choices.
    public func latch<Value: RawRepresentable & CaseIterable>(
        _ id: String,
        title: String? = nil,
        description: String? = nil,
        enabled: @escaping @autoclosure () -> Bool = true,
        window: String? = nil,
        parent: String? = nil,
        selection: Binding<Value>
    ) -> some View where Value.RawValue == String {
        modifier(
            LatchControl(
                id: id,
                role: "popup",
                title: title,
                description: description,
                value: { selection.wrappedValue.rawValue },
                enabled: enabled,
                actions: ["set"],
                window: window,
                parent: parent,
                kind: .enum,
                choices: LatchCatalog.enumChoices(Value.self),
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
        description: String? = nil,
        enabled: @escaping @autoclosure () -> Bool = true,
        window: String? = nil,
        parent: String? = nil,
        integer: Binding<Int>
    ) -> some View {
        modifier(
            LatchControl(
                id: id,
                role: "textfield",
                title: title,
                description: description,
                value: { String(integer.wrappedValue) },
                enabled: enabled,
                actions: ["set"],
                window: window,
                parent: parent,
                kind: .int,
                set: { integer.wrappedValue = try LatchCatalog.parseInt(id: id, $0) }
            )
        )
    }

    /// Number field: floating-point.
    public func latch(
        _ id: String,
        title: String? = nil,
        description: String? = nil,
        enabled: @escaping @autoclosure () -> Bool = true,
        window: String? = nil,
        parent: String? = nil,
        double: Binding<Double>
    ) -> some View {
        modifier(
            LatchControl(
                id: id,
                role: "textfield",
                title: title,
                description: description,
                value: { String(double.wrappedValue) },
                enabled: enabled,
                actions: ["set"],
                window: window,
                parent: parent,
                kind: .double,
                set: {
                    double.wrappedValue = try LatchCatalog.parseDouble(id: id, $0)
                }
            )
        )
    }

    /// Time field: `HH:MM` 24h.
    public func latch(
        _ id: String,
        title: String? = nil,
        description: String? = nil,
        enabled: @escaping @autoclosure () -> Bool = true,
        window: String? = nil,
        parent: String? = nil,
        time: Binding<(hour: Int, minute: Int)>
    ) -> some View {
        modifier(
            LatchControl(
                id: id,
                role: "textfield",
                title: title,
                description: description,
                value: {
                    LatchCatalog.formatTime(
                        hour: time.wrappedValue.hour,
                        minute: time.wrappedValue.minute
                    )
                },
                enabled: enabled,
                actions: ["set"],
                window: window,
                parent: parent,
                kind: .time,
                set: { time.wrappedValue = try LatchCatalog.parseTime(id: id, $0) }
            )
        )
    }

    /// Work-day field: `monday,tuesday`.
    public func latch(
        _ id: String,
        title: String? = nil,
        description: String? = nil,
        enabled: @escaping @autoclosure () -> Bool = true,
        window: String? = nil,
        parent: String? = nil,
        weekdays: Binding<Set<String>>
    ) -> some View {
        modifier(
            LatchControl(
                id: id,
                role: "textfield",
                title: title,
                description: description,
                value: {
                    LatchCatalog.formatWeekdays(Array(weekdays.wrappedValue))
                },
                enabled: enabled,
                actions: ["set"],
                window: window,
                parent: parent,
                kind: .weekdays,
                choices: LatchCatalog.weekdayNames,
                set: {
                    weekdays.wrappedValue = try LatchCatalog.parseWeekdays(id: id, $0)
                }
            )
        )
    }

    /// Number field: unsigned integer.
    public func latch(
        _ id: String,
        title: String? = nil,
        description: String? = nil,
        enabled: @escaping @autoclosure () -> Bool = true,
        window: String? = nil,
        parent: String? = nil,
        unsigned: Binding<UInt64>
    ) -> some View {
        modifier(
            LatchControl(
                id: id,
                role: "textfield",
                title: title,
                description: description,
                value: { String(unsigned.wrappedValue) },
                enabled: enabled,
                actions: ["set"],
                window: window,
                parent: parent,
                kind: .uint64,
                set: {
                    unsigned.wrappedValue = try LatchCatalog.parseUInt64(id: id, $0)
                }
            )
        )
    }

    /// Row / control with named actions.
    public func latch(
        _ id: String,
        role: String,
        title: String? = nil,
        description: String? = nil,
        value: @escaping @autoclosure () -> String? = nil,
        enabled: @escaping @autoclosure () -> Bool = true,
        actions: [String],
        window: String? = nil,
        parent: String? = nil,
        press: @escaping (String?) throws -> Void
    ) -> some View {
        modifier(
            LatchControl(
                id: id,
                role: role,
                title: title,
                description: description,
                value: value,
                enabled: enabled,
                actions: actions,
                window: window,
                parent: parent,
                kind: .action,
                press: press
            )
        )
    }
}
