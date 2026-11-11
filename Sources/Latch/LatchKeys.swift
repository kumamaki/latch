#if DEBUG
    import AppKit
    import Foundation

    /// Key names `keyPress` accepts, and the key codes and characters they
    /// post. A fixed table so an unknown name fails loud instead of
    /// guessing a layout.
    enum LatchKey {
        struct Stroke: Equatable {
            let keyCode: UInt16
            /// What the key types with no modifier held.
            let character: String
        }

        static let modifiers: [String: NSEvent.ModifierFlags] = [
            "command": .command,
            "shift": .shift,
            "option": .option,
            "control": .control,
        ]

        private static let named: [String: Stroke] = [
            "return": Stroke(keyCode: 36, character: "\r"),
            "tab": Stroke(keyCode: 48, character: "\t"),
            "space": Stroke(keyCode: 49, character: " "),
            "delete": Stroke(keyCode: 51, character: "\u{7f}"),
            "escape": Stroke(keyCode: 53, character: "\u{1b}"),
            "left": Stroke(keyCode: 123, character: functionKey(NSLeftArrowFunctionKey)),
            "right": Stroke(keyCode: 124, character: functionKey(NSRightArrowFunctionKey)),
            "down": Stroke(keyCode: 125, character: functionKey(NSDownArrowFunctionKey)),
            "up": Stroke(keyCode: 126, character: functionKey(NSUpArrowFunctionKey)),
        ]

        /// ANSI layout key codes for the characters a shortcut uses.
        private static let characters: [Character: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
            "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
            "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28,
            "0": 29,
        ]

        static func stroke(named name: String) throws -> Stroke {
            if let stroke = named[name] { return stroke }
            if name.count == 1, let character = name.first, let code = characters[character] {
                return Stroke(keyCode: code, character: name)
            }
            throw LatchError.invalidValue(
                id: name, value: name,
                expected:
                    "a letter, a digit, or one of \(named.keys.sorted().joined(separator: ", "))"
            )
        }

        static func flags(_ names: [String]) throws -> NSEvent.ModifierFlags {
            var flags: NSEvent.ModifierFlags = []
            for name in names {
                guard let flag = modifiers[name] else {
                    throw LatchError.invalidValue(
                        id: name, value: name,
                        expected: "one of \(modifiers.keys.sorted().joined(separator: ", "))")
                }
                flags.insert(flag)
            }
            return flags
        }

        private static func functionKey(_ code: Int) -> String {
            String(UnicodeScalar(UInt32(code)).map(Character.init) ?? " ")
        }
    }

    extension LatchAX {
        /// Posts a key down and key up to the named window's responder
        /// chain through `NSWindow.sendEvent`. It does not move focus and
        /// does not touch system key state. Text entry stays `ax set`.
        @MainActor
        public static func keyPress(window name: String, key: String, modifiers: [String]) throws {
            guard let window = preferredWindow(named: name) else {
                throw LatchError.unknownWindow(name: name)
            }
            guard window.isVisible || window.isMiniaturized else {
                throw LatchError.windowNotVisible(name: name)
            }
            let stroke = try LatchKey.stroke(named: key)
            let flags = try LatchKey.flags(modifiers)
            let typed = flags.contains(.shift) ? stroke.character.uppercased() : stroke.character
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard
                    let event = NSEvent.keyEvent(
                        with: type,
                        location: .zero,
                        modifierFlags: flags,
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber,
                        context: nil,
                        characters: typed,
                        charactersIgnoringModifiers: stroke.character,
                        isARepeat: false,
                        keyCode: stroke.keyCode
                    )
                else {
                    throw LatchError.opsUnavailable(
                        reason: "NSEvent.keyEvent could not synthesize \(type).")
                }
                window.sendEvent(event)
            }
        }
    }
#endif
