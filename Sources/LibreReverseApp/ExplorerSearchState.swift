#if os(macOS)
import Foundation

/// Owns visibility and request lifetime together. Navigation dismisses both
/// controls and results; reopening always starts a fresh search.
struct ExplorerSearchState: Equatable {
    enum Action { case open, hide, scroll, input(LibreReverseSearchOverlayState), submit, clearResults }
    private(set) var input = LibreReverseSearchOverlayState()
    private(set) var expanded = true
    private(set) var resultsPresented = false
    private(set) var revision: UInt64 = 0

    mutating func send(_ action: Action) {
        switch action {
        case .open:
            input = .init()
            expanded = true
            resultsPresented = false
            revision &+= 1
        case .hide, .scroll:
            input = .init()
            expanded = false
            resultsPresented = false
            revision &+= 1
        case .input(let value):
            guard value != input else { return }
            input = value
            // Keep the last completed list stationary while its replacement is pending.
            // The revision still rejects all completions for the previous input.
            resultsPresented = resultsPresented && value.canSubmit
            revision &+= 1
        case .submit:
            expanded = true
            resultsPresented = true
            revision &+= 1
        case .clearResults:
            resultsPresented = false
            revision &+= 1
        }
    }
    func accepts(_ request: UInt64) -> Bool { expanded && resultsPresented && revision == request }
}
#endif
