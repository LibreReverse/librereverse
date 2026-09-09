/// Controls timeline seek ownership across interaction lifetimes.
///
/// The source is an interaction-lifetime priority lock, not a rendering mode.
/// Lower raw ordinals have higher priority. Pinning the live edge bypasses
/// priority admission; raw scrolling takes ownership after changing the offset.
public struct SeekSourceReducer: Sendable {
    public enum Admission: Equatable, Sendable {
        /// `canUpdateSeekPosition` was false or a stronger source owns control.
        case rejected
        /// The request passed source admission, but its mapped position equaled
        /// the stored position, so the reducer mutated nothing and emitted no
        /// `seekPositionDidChange` action.
        case unchanged
        /// The request passed admission, changed position, stored its source,
        /// and is eligible to emit `seekPositionDidChange`.
        case admitted
    }

    public var canUpdateSeekPosition: Bool
    public private(set) var source: SeekPositionUpdateSource?

    public init(
        canUpdateSeekPosition: Bool = true,
        source: SeekPositionUpdateSource? = nil
    ) {
        self.canUpdateSeekPosition = canUpdateSeekPosition
        self.source = source
    }

    /// Applies priority admission after the caller resolves the requested
    /// position. An unchanged position preserves the current owner and does
    /// not emit a change.
    @discardableResult
    public mutating func admit(
        _ incoming: SeekPositionUpdateSource,
        positionChanged: Bool
    ) -> Admission {
        guard canUpdateSeekPosition else { return .rejected }

        let passesPriority: Bool
        if incoming == .pinToEnd {
            passesPriority = true
        } else if let source {
            passesPriority = source.rawValue >= incoming.rawValue
        } else {
            passesPriority = true
        }

        guard passesPriority else { return .rejected }
        guard positionChanged else { return .unchanged }
        source = incoming
        return .admitted
    }

    /// A new explicit user gesture supersedes ownership from earlier input.
    /// Priority admission still governs updates within the current interaction.
    @discardableResult
    public mutating func beginInteraction(_ incoming: SeekPositionUpdateSource) -> Bool {
        guard canUpdateSeekPosition else { return false }
        source = incoming
        return true
    }

    /// Complete only this interaction; a newer owner (including live pinning)
    /// must survive an older interaction's completion.
    public mutating func endInteraction(_ completed: SeekPositionUpdateSource) {
        if source == completed { source = nil }
    }

    public mutating func playbackStarted() {
        beginInteraction(.audioPlayer)
    }

    public mutating func dragStarted() {
        beginInteraction(.drag)
    }

    public mutating func dragEnded() {
        endInteraction(.drag)
    }

    public mutating func clickEnded() {
        endInteraction(.click)
    }

    /// Release transient navigation ownership when bounds change.
    /// Drag, click, pin-to-end, audio-player, and nil are retained.
    public mutating func boundsDidChange() {
        guard let source else { return }
        let membershipMask = 0x99f
        if membershipMask & (1 << source.rawValue) != 0 {
            self.source = nil
        }
    }

    /// Scrolling takes ownership after changing or clamping the contiguous
    /// offset, without entering the shared priority gate.
    public mutating func rawScrollDidMutateOffset() {
        source = .scroll
    }
}
