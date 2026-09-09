import CoreGraphics
import Foundation

/// One result from `VNRecognizeTextRequest`, expressed in Vision's normalized
/// lower-left coordinate system. Keeping Vision out of this value makes the
/// app's ordering/partition/offset contract deterministic and testable.
public struct OCRObservation: Equatable, Sendable {
    public let text: String
    public let boundingBox: CGRect

    public init(text: String, boundingBox: CGRect) {
        self.text = text
        self.boundingBox = boundingBox
    }
}

/// Canonical row shape persisted in the OCR `node` table.
public struct OCRNode: Equatable, Sendable {
    public let nodeOrder: Int
    public let textOffset: Int
    public let textLength: Int
    public let leftX: Double
    public let topY: Double
    public let width: Double
    public let height: Double
    public let windowIndex: Int

    public init(
        nodeOrder: Int,
        textOffset: Int,
        textLength: Int,
        leftX: Double,
        topY: Double,
        width: Double,
        height: Double,
        windowIndex: Int
    ) {
        self.nodeOrder = nodeOrder
        self.textOffset = textOffset
        self.textLength = textLength
        self.leftX = leftX
        self.topY = topY
        self.width = width
        self.height = height
        self.windowIndex = windowIndex
    }
}

public struct OCRDocument: Equatable, Sendable {
    public let text: String
    public let otherText: String
    public let nodes: [OCRNode]

    public init(text: String, otherText: String, nodes: [OCRNode]) {
        self.text = text
        self.otherText = otherText
        self.nodes = nodes
    }
}

public enum OCRTextAssembly {
    /// Front-window text requires strictly more than half the observation area
    /// to intersect the normalized front-window rectangle.
    public static let frontWindowIntersectionThreshold = 0.5

    /// Converts WindowServer display/window bounds to normalized top-left
    /// coordinates. Observations are flipped into this space before partition.
    public static func normalizedWindowBounds(
        displayBounds: CGRect,
        frontWindowBounds: CGRect?
    ) -> CGRect? {
        guard let frontWindowBounds,
              displayBounds.width > 0,
              displayBounds.height > 0 else { return nil }
        return CGRect(
            x: (frontWindowBounds.minX - displayBounds.minX) / displayBounds.width,
            y: (frontWindowBounds.minY - displayBounds.minY) / displayBounds.height,
            width: frontWindowBounds.width / displayBounds.width,
            height: frontWindowBounds.height / displayBounds.height
        )
    }

    /// Builds searchable documents and positioned text nodes from OCR observations.
    ///
    /// Vision observations are reversed first. Front-window lines are then
    /// emitted before other-screen lines, preserving that reversed order
    /// within each partition. Lines are joined with one ASCII space. The two
    /// FTS columns have no separator between their offset domains.
    public static func assemble(
        observations: [OCRObservation],
        normalizedFrontWindowBounds: CGRect?
    ) -> OCRDocument {
        let reversed = observations.reversed()
        var front: [OCRObservation] = []
        var other: [OCRObservation] = []
        front.reserveCapacity(observations.count)
        other.reserveCapacity(observations.count)

        for observation in reversed {
            if belongsToFrontWindow(
                observation.boundingBox,
                normalizedFrontWindowBounds: normalizedFrontWindowBounds
            ) {
                front.append(observation)
            } else {
                other.append(observation)
            }
        }

        let frontText = front.map(\.text).joined(separator: " ")
        let otherText = other.map(\.text).joined(separator: " ")
        var nodes: [OCRNode] = []
        nodes.reserveCapacity(observations.count)
        appendNodes(front, windowIndex: 0, startingOffset: 0, to: &nodes)
        appendNodes(other, windowIndex: 1, startingOffset: frontText.utf16.count, to: &nodes)
        return OCRDocument(text: frontText, otherText: otherText, nodes: nodes)
    }

    private static func belongsToFrontWindow(
        _ observation: CGRect,
        normalizedFrontWindowBounds: CGRect?
    ) -> Bool {
        // With no usable front-window geometry, the app's useful search
        // column remains the full screen rather than becoming empty.
        guard let normalizedFrontWindowBounds else { return true }
        let topLeftObservation = CGRect(
            x: observation.minX,
            y: 1 - observation.maxY,
            width: observation.width,
            height: observation.height
        )
        let area = topLeftObservation.width * topLeftObservation.height
        guard area > 0 else { return false }
        let intersection = topLeftObservation.intersection(normalizedFrontWindowBounds)
        guard !intersection.isNull, !intersection.isEmpty else { return false }
        return (intersection.width * intersection.height) / area
            > frontWindowIntersectionThreshold
    }

    private static func appendNodes(
        _ observations: [OCRObservation],
        windowIndex: Int,
        startingOffset: Int,
        to nodes: inout [OCRNode]
    ) {
        var offset = startingOffset
        for (index, observation) in observations.enumerated() {
            let box = observation.boundingBox
            nodes.append(OCRNode(
                nodeOrder: nodes.count,
                textOffset: offset,
                textLength: observation.text.utf16.count,
                leftX: box.minX,
                topY: 1 - box.maxY,
                width: box.width,
                height: box.height,
                windowIndex: windowIndex
            ))
            offset += observation.text.utf16.count
            if index != observations.indices.last { offset += 1 }
        }
    }
}
