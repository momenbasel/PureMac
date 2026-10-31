public struct Gauge {
    public var fraction: Double

    public init(fraction: Double) {
        self.fraction = fraction
    }

    public func spans(width: Int, filled filledStyle: TextStyle = .plain) -> [Span] {
        let filledCount = Term.filledCount(fraction: fraction, width: width)
        return [
            Span(String(repeating: "█", count: filledCount), filledStyle),
            Span(String(repeating: "░", count: max(0, width) - filledCount), TextStyle(dim: true))
        ].filter { !$0.text.isEmpty }
    }
}
