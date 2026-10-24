public enum Spinner {
    private static let frames = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏".map(String.init)

    public static func frame(tick: Int) -> String {
        frames[tick % frames.count]
    }
}
