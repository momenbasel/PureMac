import ArgumentParser
import TerminalUI

enum CleanupFlowResult {
    case nothingFound
    case cancelled
    case finished(CleanOutcome)
}

struct RemovalProgress {
    let position: Int
    let count: Int
    let path: String

    init(index: Int, count: Int, path: String) {
        position = index + 1
        self.count = count
        self.path = path
    }
}

enum CleanupFlow {
    private static let removingMaxContentWidth = 60

    struct Labels {
        let scanning: String
        let empty: String
        let reviewTitle: String
        let noun: String

        var initialStatus: ScanStatus { ScanStatus(headline: scanning) }
    }

    typealias Scan = (WorkProgress<ScanStatus>, CancelFlag) -> [CategoryScan]

    static func run(
        labels: Labels,
        ignore: IgnoreStore,
        scan: @escaping Scan
    ) throws -> CleanupFlowResult {
        let session = try TerminalSession()
        defer { session.close() }

        var scanCancelled = false
        let categories = session.runWithSpinner(
            progress: labels.initialStatus,
            render: { tick, status in
                scanningScreen(
                    status: status, tick: tick, isCancelling: scanCancelled, width: session.width, height: session.height
                )
            },
            onKey: { key, cancel in
                if cancelsScan(key) {
                    scanCancelled = true
                    cancel.cancel()
                }
            },
            work: scan
        )
        if scanCancelled { return .cancelled }
        guard !categories.isEmpty else {
            showInfo(on: session) { emptyScreen(labels: labels, width: session.width, height: session.height) }
            return .nothingFound
        }

        guard let review = InteractiveReview.select(
            categories, session: session, title: labels.reviewTitle, noun: labels.noun
        ) else { return .cancelled }

        let items = review.selectedResult().flatMap { $0.selectedItems }
        let outcome = session.runWithSpinner(
            progress: RemovalProgress(index: 0, count: items.count, path: items.first?.path ?? ""),
            render: { tick, progress in
                removingScreen(
                    review: review, labels: labels, progress: progress, tick: tick,
                    width: session.width, height: session.height
                )
            },
            work: { progress, _ in
                Cleaner.remove(items, ignore: ignore, dryRun: false) { index, count, item in
                    progress.set(RemovalProgress(index: index, count: count, path: item.path))
                }
            }
        )
        showInfo(on: session) {
            resultScreen(outcome: outcome, review: review, labels: labels, width: session.width, height: session.height)
        }
        return .finished(outcome)
    }

    static func finish(_ result: CleanupFlowResult, labels: Labels) throws {
        switch result {
        case .nothingFound:
            print(Term.green(labels.empty))
        case .cancelled:
            print(Term.dim("Cancelled. Nothing removed."))
        case .finished(let outcome):
            Render.cleanupSummary(outcome, dryRun: false)
            if outcome.hadFailures { throw ExitCode.failure }
        }
    }

    static func closesInfoDialog(_ key: TerminalKey) -> Bool {
        key == .enter || isEscapeOrQ(key)
    }

    static func showInfo(on session: TerminalSession, _ screen: () -> Buffer) {
        repeat {
            session.draw(screen())
        } while !closesInfoDialog(session.readKey())
    }

    static func cancelsScan(_ key: TerminalKey) -> Bool {
        isEscapeOrQ(key)
    }

    private static func isEscapeOrQ(_ key: TerminalKey) -> Bool {
        switch key {
        case .escape: return true
        case .character(let character): return character.lowercased() == "q"
        default: return false
        }
    }

    static func scanningScreen(status: ScanStatus, tick: Int, isCancelling: Bool = false, width: Int, height: Int) -> Buffer {
        StatusScreen.render(
            title: "PureMac",
            rows: [
                StatusRow(Spinner.frame(tick: tick) + " " + (isCancelling ? StatusScreen.cancellingText : status.headline), truncatesInMiddle: true),
                StatusRow(status.folder.map(Render.shorten) ?? "", style: TextStyle(dim: true), truncatesInMiddle: true),
                StatusRow("Found \(Render.counted(status.foundCount, "item")) · \(ByteCount.human(status.foundBytes))")
            ],
            hint: StatusScreen.scanHint,
            width: width,
            height: height
        )
    }

    static func emptyScreen(labels: Labels, width: Int, height: Int) -> Buffer {
        infoScreen(
            title: "Nothing to clean",
            message: labels.empty,
            on: scanningScreen(status: labels.initialStatus, tick: 0, width: width, height: height)
        )
    }

    static func infoScreen(title: String, message: String, on background: Buffer) -> Buffer {
        StatusScreen.overlay(
            Dialog(title: title, message: [Span(message)], buttons: [DialogButton("OK")], focusedButton: 0),
            on: background,
            tooSmallExitHint: closeHint
        )
    }

    static func removingScreen(
        review: InteractiveReviewModel, labels: Labels, progress: RemovalProgress, tick: Int, width: Int, height: Int
    ) -> Buffer {
        let area = Rect(x: 0, y: 0, width: width, height: height)
        return StatusScreen.overlay(
            removingDialog(noun: labels.noun, progress: progress, tick: tick, area: area),
            on: selectionScreen(review, labels: labels, width: width, height: height),
            tooSmallExitHint: "Removing…"
        )
    }

    static func resultScreen(outcome: CleanOutcome, review: InteractiveReviewModel, labels: Labels, width: Int, height: Int) -> Buffer {
        StatusScreen.overlay(
            resultDialog(outcome, area: Rect(x: 0, y: 0, width: width, height: height)),
            on: selectionScreen(review, labels: labels, width: width, height: height),
            tooSmallExitHint: closeHint
        )
    }

    static func removingDialog(noun: String, progress: RemovalProgress, tick: Int, area: Rect) -> Dialog {
        let rowWidth = min(removingMaxContentWidth, Dialog.maxContentWidth(in: area))
        let current = Term.truncate(
            Spinner.frame(tick: tick) + " " + Render.shorten(progress.path), to: rowWidth, middle: true
        )
        return Dialog(
            title: "Removing \(Render.counted(progress.count, noun))…",
            titleStyle: StatusScreen.warningTitle,
            borderStyle: StatusScreen.warningBorder,
            message: [
                Span(Term.pad(current, to: rowWidth)),
                Span("\(progress.position) of \(progress.count)", TextStyle(dim: true))
            ],
            messageAlignment: .leading
        )
    }

    private static let closeHint = "Enter close"

    private static func resultDialog(_ outcome: CleanOutcome, area: Rect) -> Dialog {
        var message = [Span(ByteCount.human(outcome.freedBytes) + Render.removedDetail(outcome))]
        if !outcome.skipped.isEmpty {
            message.append(Span(Render.skippedLabel(outcome) + Render.skippedNote, TextStyle(color: .yellow)))
        }
        if !outcome.failed.isEmpty {
            let red = TextStyle(color: .red)
            message.append(Span(Render.failedLabel(outcome), red))
            let rowWidth = Dialog.maxContentWidth(in: area)
            message += outcome.failed.prefix(3).map {
                Span(Term.truncate("! " + Render.shorten($0.path), to: rowWidth, middle: true), red)
            }
        }
        return Dialog(
            title: Render.cleanupCompleteTitle,
            titleStyle: TextStyle(color: .green, bold: true),
            message: message,
            buttons: [DialogButton("Done")],
            focusedButton: 0
        )
    }

    private static func selectionScreen(_ review: InteractiveReviewModel, labels: Labels, width: Int, height: Int) -> Buffer {
        InteractiveReview.render(
            model: review,
            title: labels.reviewTitle,
            noun: labels.noun,
            width: width,
            height: height
        )
    }
}
