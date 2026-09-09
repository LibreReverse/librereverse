/// Carbon registration values shared by the global shortcut controller.
public enum GlobalHotKeyContract {
    /// Carbon's Command (256) plus Shift (512) modifier mask.
    public static let commandShiftModifiers: UInt32 = 768

    /// FourCC identifying this app's Carbon hot-key events.
    public static let signature: UInt32 = 0x5353_4B53
}
