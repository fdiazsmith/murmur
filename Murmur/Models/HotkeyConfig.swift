import Carbon.HIToolbox
import CoreGraphics

struct HotkeyConfig: Codable, Equatable {
    var keyCode: Int // -1 for modifier-only
    var control: Bool
    var shift: Bool
    var option: Bool
    var command: Bool
    var fn: Bool
    var keyDisplay: String

    init(keyCode: Int, control: Bool, shift: Bool, option: Bool, command: Bool, fn: Bool, keyDisplay: String) {
        self.keyCode = keyCode
        self.control = control
        self.shift = shift
        self.option = option
        self.command = command
        self.fn = fn
        self.keyDisplay = keyDisplay
    }

    static let `default` = HotkeyConfig(
        keyCode: Int(kVK_Space),
        control: true,
        shift: true,
        option: false,
        command: false,
        fn: false,
        keyDisplay: "Space"
    )

    var isModifierOnly: Bool { keyCode < 0 }

    var modifierCount: Int {
        [control, shift, option, command, fn].filter { $0 }.count
    }

    func matchesModifiers(_ flags: CGEventFlags) -> Bool {
        let base = flags.contains(.maskControl) == control
            && flags.contains(.maskShift) == shift
            && flags.contains(.maskAlternate) == option
            && flags.contains(.maskCommand) == command

        if isModifierOnly {
            // Exact match for modifier-only hotkeys
            return base && flags.contains(.maskSecondaryFn) == fn
        } else {
            // For key combos, only require fn when config expects it
            // (arrow keys etc. spuriously set maskSecondaryFn)
            return base && (!fn || flags.contains(.maskSecondaryFn))
        }
    }

    var displayString: String {
        var s = ""
        if fn { s += "fn " }
        if control { s += "⌃" }
        if option { s += "⌥" }
        if shift { s += "⇧" }
        if command { s += "⌘" }
        if !keyDisplay.isEmpty { s += keyDisplay }
        return s
    }

    // MARK: - Persistence

    private static let storageKey = "hotkeyConfig"

    static func load() -> HotkeyConfig {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let config = try? JSONDecoder().decode(HotkeyConfig.self, from: data)
        else { return .default }
        return config
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    static func clearSaved() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    // MARK: - Backwards-compatible decoding (fn field added later)

    enum CodingKeys: String, CodingKey {
        case keyCode, control, shift, option, command, fn, keyDisplay
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try c.decode(Int.self, forKey: .keyCode)
        control = try c.decode(Bool.self, forKey: .control)
        shift = try c.decode(Bool.self, forKey: .shift)
        option = try c.decode(Bool.self, forKey: .option)
        command = try c.decode(Bool.self, forKey: .command)
        fn = try c.decodeIfPresent(Bool.self, forKey: .fn) ?? false
        keyDisplay = try c.decode(String.self, forKey: .keyDisplay)
    }
}
