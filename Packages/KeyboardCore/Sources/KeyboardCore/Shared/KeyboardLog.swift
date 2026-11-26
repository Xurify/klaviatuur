import os

/// Streams to Console.app on a Mac with the phone connected; filter by subsystem
/// `com.klaviatuur.app.keyboard`. Typed text is never logged, only lengths and outcomes.
public enum KeyboardLog {
    private static let subsystem = "com.klaviatuur.app.keyboard"
    public static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    public static let lexicon = Logger(subsystem: subsystem, category: "lexicon")
    public static let input = Logger(subsystem: subsystem, category: "input")
}
