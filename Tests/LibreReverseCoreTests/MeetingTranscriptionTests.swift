#if os(macOS)
@preconcurrency import AVFoundation
import Foundation
import XCTest
@testable import LibreReverseCore

final class MeetingTranscriptionTests: XCTestCase {
    func testReplacementRunnerAloneOwnsSchedulerCompletion() {
        var state = LibreReverseMeetingTranscriptionSchedulerState()
        let predecessor = state.beginRunner()!
        XCTAssertTrue(state.owns(predecessor))

        let replacement = state.beginRunner()!
        XCTAssertFalse(state.owns(predecessor))
        XCTAssertTrue(state.owns(replacement))
    }

    func testLibraryMutationInvalidatesRunnerAndClosesAdmissionUntilOutermostResume() {
        var state = LibreReverseMeetingTranscriptionSchedulerState()
        let predecessor = state.beginRunner()!

        state.beginLibraryMutation()
        XCTAssertFalse(state.owns(predecessor))
        XCTAssertNil(state.beginRunner())
        XCTAssertEqual(state.libraryMutationDepth, 1)

        state.beginLibraryMutation()
        state.endLibraryMutation()
        XCTAssertNil(state.beginRunner())
        XCTAssertEqual(state.libraryMutationDepth, 1)

        state.endLibraryMutation()
        let replacement = state.beginRunner()!
        XCTAssertTrue(state.owns(replacement))
        XCTAssertFalse(state.owns(predecessor))
    }

    func testProductionWindowPlanBoundsTwoHourInferenceAndRetainsOverlap() throws {
        let configuration = MeetingTranscriptionWindowingConfiguration.production
        let windows = try MeetingTranscriptionWindowPlan.make(
            mediaDurationSeconds: 7_200,
            configuration: configuration
        )

        XCTAssertEqual(configuration.windowSeconds, 300)
        XCTAssertEqual(configuration.overlapSeconds, 5)
        XCTAssertEqual(windows.count, 25)
        XCTAssertEqual(windows.first?.startSeconds, 0)
        XCTAssertEqual(windows.first?.finalizeThroughSeconds, 295)
        XCTAssertEqual(windows.last?.startSeconds, 7_080)
        XCTAssertEqual(windows.last?.durationSeconds, 120)
        XCTAssertEqual(windows.last?.finalizeThroughSeconds, 7_200)
        XCTAssertTrue(windows.allSatisfy { $0.durationSeconds <= 300 })
        for (left, right) in zip(windows, windows.dropFirst()) {
            XCTAssertEqual(left.startSeconds + left.durationSeconds - right.startSeconds, 5)
            XCTAssertEqual(left.finalizeThroughSeconds, right.startSeconds)
        }
    }

    func testWindowPlanHandlesShortMediaAndRejectsInvalidOverlap() throws {
        let short = try XCTUnwrap(
            MeetingTranscriptionWindowPlan.make(
                mediaDurationSeconds: 12.5,
                configuration: .production
            ).only
        )
        XCTAssertEqual(short.durationSeconds, 12.5)
        XCTAssertEqual(short.finalizeThroughSeconds, 12.5)

        XCTAssertThrowsError(
            try MeetingTranscriptionWindowPlan.make(
                mediaDurationSeconds: 10,
                configuration: .init(windowSeconds: 5, overlapSeconds: 5)
            )
        ) {
            XCTAssertEqual(
                $0 as? MeetingTranscriptionError,
                .invalidWindowingConfiguration(windowSeconds: 5, overlapSeconds: 5)
            )
        }
    }

    func testNormalizedPCMWindowCopyHasExactBoundedFrameCount() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-window-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source.wav")
        let windowURL = root.appendingPathComponent("window.wav")
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
        )
        var source: AVAudioFile? = try AVAudioFile(
            forWriting: sourceURL,
            settings: format.settings
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000)
        )
        buffer.frameLength = 32_000
        try source?.write(from: buffer)
        source = nil

        try MeetingAudioPCMExporter.copyWindow(
            from: sourceURL,
            to: windowURL,
            startSeconds: 0.25,
            durationSeconds: 0.5
        )

        let window = try AVAudioFile(forReading: windowURL)
        XCTAssertEqual(window.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(window.processingFormat.channelCount, 1)
        XCTAssertEqual(window.length, 8_000)
    }

    func testNativeExportCancellationDrainsBeforeCleanupAndReplacement() async throws {
        let started = expectation(description: "native export started")
        let returnedEarly = expectation(description: "must retain native writer ownership")
        returnedEarly.isInverted = true
        let callback = ExportCompletionSlot()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("audio.m4a")
        let lifetime = MeetingAudioExportLifetime(start: { completion in
            callback.store(completion)
            started.fulfill()
        })
        let task = Task {
            defer { try? FileManager.default.removeItem(at: output) }
            do { try await lifetime.run() }
            catch {
                if !callback.completed { returnedEarly.fulfill() }
                throw error
            }
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await fulfillment(of: [returnedEarly], timeout: 0.05)
        // Cancelling the caller leaves admitted native work running. Cleanup
        // must wait for its normal completion, including late output creation.
        try Data([1, 2, 3]).write(to: output)
        callback.finish()
        do { try await task.value; XCTFail("cancelled export succeeded") }
        catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try Data([4]).write(to: output, options: .withoutOverwriting)
    }

    func testNormalizedPCMExportSurvivesCancellationAndRestart() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-export-cancellation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        let destination = root.appendingPathComponent("normalized.wav")
        try writeAudioFixture(to: source, activeRange: 0.1..<1.9, frequency: 440)
        var cancellations = 0
        // Exercise immediate cancellation and cancellation racing AVFoundation
        // setup. Each predecessor must drain before its replacement writes.
        for index in 0..<60 {
            try? FileManager.default.removeItem(at: destination)
            let task = Task {
                try await MeetingAudioPCMExporter.export16kMonoWAV(from: source, to: destination)
            }
            if index % 3 != 0 {
                try await Task.sleep(nanoseconds: index % 3 == 1 ? 100_000 : 2_000_000)
            }
            task.cancel()
            do { try await task.value }
            catch is CancellationError { cancellations += 1 }
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
                .subtracting(["source.wav", "normalized.wav"]), [],
                "A cancelled export must remove its entire private workspace")
        }
        XCTAssertGreaterThan(cancellations, 0)
        try? FileManager.default.removeItem(at: destination)
        try await MeetingAudioPCMExporter.export16kMonoWAV(from: source, to: destination)
        XCTAssertGreaterThan(try AVAudioFile(forReading: destination).length, 0)
    }

    func testConcurrentPCMExportsOwnDistinctIntermediatePaths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        let first = root.appendingPathComponent("first.wav")
        let second = root.appendingPathComponent("second.wav")
        let unrelated = root.appendingPathComponent("audio.m4a")
        let sentinel = Data("unrelated existing media".utf8)
        try sentinel.write(to: unrelated)
        try writeAudioFixture(to: source, activeRange: 0.1..<1.9, frequency: 440)
        async let firstExport: Void = MeetingAudioPCMExporter.export16kMonoWAV(from: source, to: first)
        async let secondExport: Void = MeetingAudioPCMExporter.export16kMonoWAV(from: source, to: second)
        _ = try await (firstExport, secondExport)
        XCTAssertGreaterThan(try AVAudioFile(forReading: first).length, 0)
        XCTAssertGreaterThan(try AVAudioFile(forReading: second).length, 0)
        XCTAssertEqual(try Data(contentsOf: unrelated), sentinel)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)),
                       ["source.wav", "first.wav", "second.wav", "audio.m4a"])
    }

    func testNormalizedPCMExplicitlyMixesEveryMeetingAudioTrack() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-multitrack-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let systemAudioURL = root.appendingPathComponent("system.wav")
        let microphoneURL = root.appendingPathComponent("microphone.wav")
        let mediaURL = root.appendingPathComponent("meeting.mov")
        let normalizedURL = root.appendingPathComponent("normalized.wav")
        try writeAudioFixture(
            to: systemAudioURL,
            activeRange: 0.1..<0.8,
            frequency: 440
        )
        try writeAudioFixture(
            to: microphoneURL,
            activeRange: 1.2..<1.9,
            frequency: 880
        )
        try await writeMultitrackFixture(
            sources: [systemAudioURL, microphoneURL],
            to: mediaURL
        )

        let tracks = try await AVURLAsset(url: mediaURL).loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 2)
        try await MeetingAudioPCMExporter.export16kMonoWAV(
            from: mediaURL,
            to: normalizedURL
        )

        let normalized = try AVAudioFile(forReading: normalizedURL)
        XCTAssertEqual(normalized.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(normalized.processingFormat.channelCount, 1)
        XCTAssertGreaterThan(try Self.rms(in: normalized, range: 0.2..<0.7), 0.05)
        XCTAssertGreaterThan(try Self.rms(in: normalized, range: 1.3..<1.8), 0.05)
    }

    func testBundledTranscriberActuallyRunsWindowsAndReducesOverlap() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-windowed-transcriber-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source.wav")
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
        )
        var source: AVAudioFile? = try AVAudioFile(
            forWriting: sourceURL,
            settings: format.settings
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000)
        )
        buffer.frameLength = 24_000
        try source?.write(from: buffer)
        source = nil

        let transcriber = WhisperCPPCLITranscriber(
            configuration: .init(
                executableURL: root.appendingPathComponent("unused-cli"),
                modelURL: root.appendingPathComponent("unused-model")
            ),
            windowing: .init(windowSeconds: 1, overlapSeconds: 0.25)
        ) { wavURL, outputBase in
            let window = try AVAudioFile(forReading: wavURL)
            XCTAssertLessThanOrEqual(window.length, 16_000)
            if outputBase.lastPathComponent == "window-00000" {
                return .init(
                    text: "alpha draft",
                    language: "en",
                    words: [
                        .init(
                            text: "alpha",
                            startSeconds: 0,
                            endSeconds: 0.4,
                            fullTextUTF16Offset: 0
                        ),
                        .init(
                            text: "draft",
                            startSeconds: 0.8,
                            endSeconds: 1,
                            fullTextUTF16Offset: 6
                        ),
                    ]
                )
            }
            XCTAssertEqual(outputBase.lastPathComponent, "window-00001")
            XCTAssertEqual(window.length, 12_000)
            return .init(
                text: "revised ending",
                language: "en",
                words: [
                    .init(
                        text: "revised",
                        startSeconds: 0,
                        endSeconds: 0.4,
                        fullTextUTF16Offset: 0
                    ),
                    .init(
                        text: "ending",
                        startSeconds: 0.5,
                        endSeconds: 0.75,
                        fullTextUTF16Offset: 8
                    ),
                ]
            )
        }

        let result = try await transcriber.transcribe(mediaURL: sourceURL)
        XCTAssertEqual(result.text, "alpha revised ending")
        XCTAssertEqual(result.words.map(\.startSeconds), [0, 0.75, 1.25])
        XCTAssertEqual(result.words.map(\.fullTextUTF16Offset), [0, 6, 14])
        XCTAssertEqual(result.language, "en")
    }

    func testBundledTranscriberResumesAtFirstUncommittedWindow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-transcript-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source.wav")
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
        )
        var source: AVAudioFile? = try AVAudioFile(
            forWriting: sourceURL,
            settings: format.settings
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000)
        )
        buffer.frameLength = 24_000
        try source?.write(from: buffer)
        source = nil
        let keyURL = root.appendingPathComponent("library.key")
        try Data(repeating: 0x5A, count: 32).write(to: keyURL)
        let checkpoint = MeetingTranscriptionCheckpointContext(
            identifier: "published-meeting",
            url: root.appendingPathComponent("published-meeting.checkpoint"),
            encryptionKeyURL: keyURL
        )
        let configuration = WhisperCPPCLIConfiguration(
            executableURL: root.appendingPathComponent("unused-cli"),
            modelURL: root.appendingPathComponent("unused-model")
        )
        let windowing = MeetingTranscriptionWindowingConfiguration(
            windowSeconds: 1,
            overlapSeconds: 0.25
        )
        let firstCalls = WindowCallLog()
        let first = WhisperCPPCLITranscriber(
            configuration: configuration,
            windowing: windowing
        ) { _, outputBase in
            let stem = outputBase.lastPathComponent
            await firstCalls.append(stem)
            if stem == "window-00001" {
                throw MeetingTranscriptionError.processFailed(status: 9, message: "fixture")
            }
            return Self.firstWindowResult
        }

        do {
            _ = try await first.transcribe(mediaURL: sourceURL, checkpoint: checkpoint)
            XCTFail("the second window must fail")
        } catch {
            XCTAssertEqual(
                error as? MeetingTranscriptionError,
                .processFailed(status: 9, message: "fixture")
            )
        }
        let initialWindowCalls = await firstCalls.values()
        XCTAssertEqual(initialWindowCalls, ["window-00000", "window-00001"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkpoint.url.path))
        XCTAssertNil(
            try Data(contentsOf: checkpoint.url).range(of: Data("alpha draft".utf8))
        )

        let resumedCalls = WindowCallLog()
        let resumed = WhisperCPPCLITranscriber(
            configuration: configuration,
            windowing: windowing
        ) { _, outputBase in
            await resumedCalls.append(outputBase.lastPathComponent)
            return Self.secondWindowResult
        }
        let result = try await resumed.transcribe(mediaURL: sourceURL, checkpoint: checkpoint)

        let resumedWindowCalls = await resumedCalls.values()
        XCTAssertEqual(resumedWindowCalls, ["window-00001"])
        XCTAssertEqual(result.text, "alpha revised ending")
        XCTAssertEqual(result.words.map(\.startSeconds), [0, 0.75, 1.25])
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkpoint.url.path))
    }

    func testCheckpointStoreRejectsCorruptAndStaleBindings() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-transcript-stale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mediaURL = root.appendingPathComponent("meeting.mp4")
        try Data([1, 2, 3]).write(to: mediaURL)
        let checkpointURL = root.appendingPathComponent("meeting.checkpoint")
        let keyURL = root.appendingPathComponent("library.key")
        try Data(repeating: 0xA5, count: 32).write(to: keyURL)
        let configuration = WhisperCPPCLIConfiguration(
            executableURL: root.appendingPathComponent("cli"),
            modelURL: root.appendingPathComponent("model")
        )
        let windowing = MeetingTranscriptionWindowingConfiguration(
            windowSeconds: 1,
            overlapSeconds: 0.25
        )
        let windows = try MeetingTranscriptionWindowPlan.make(
            mediaDurationSeconds: 1.5,
            configuration: windowing
        )
        let originalContext = MeetingTranscriptionCheckpointContext(
            identifier: "original",
            url: checkpointURL,
            encryptionKeyURL: keyURL
        )
        let original = try MeetingTranscriptionCheckpointStore.binding(
            context: originalContext,
            mediaURL: mediaURL,
            configuration: configuration,
            windowing: windowing
        )
        try MeetingTranscriptionCheckpointStore.save(
            .init(
                binding: original,
                nextWindowIndex: 1,
                finalizedThroughSeconds: 0.75,
                language: "en",
                words: Self.firstWindowResult.words
            ),
            context: originalContext
        )
        let wrongKeyURL = root.appendingPathComponent("wrong-library.key")
        try Data(repeating: 0x3C, count: 32).write(to: wrongKeyURL)
        let wrongKeyContext = MeetingTranscriptionCheckpointContext(
            identifier: "original",
            url: checkpointURL,
            encryptionKeyURL: wrongKeyURL
        )
        XCTAssertNil(
            try MeetingTranscriptionCheckpointStore.load(
                context: wrongKeyContext,
                binding: original,
                windows: windows
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpointURL.path))

        try MeetingTranscriptionCheckpointStore.save(
            .init(
                binding: original,
                nextWindowIndex: 1,
                finalizedThroughSeconds: 0.75,
                language: "en",
                words: Self.firstWindowResult.words
            ),
            context: originalContext
        )
        let stale = try MeetingTranscriptionCheckpointStore.binding(
            context: originalContext,
            mediaURL: mediaURL,
            configuration: configuration,
            windowing: .init(windowSeconds: 2, overlapSeconds: 0.25)
        )

        XCTAssertNil(
            try MeetingTranscriptionCheckpointStore.load(
                context: originalContext,
                binding: stale,
                windows: windows
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpointURL.path))

        try Data("truncated".utf8).write(to: checkpointURL)
        XCTAssertNil(
            try MeetingTranscriptionCheckpointStore.load(
                context: originalContext,
                binding: original,
                windows: windows
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpointURL.path))
    }

    func testLocalCLIArgumentsPreserveLanguageDeviceAndMachineReadableOutput() {
        let media = URL(fileURLWithPath: "/tmp/Meeting input.mp4")
        let output = URL(fileURLWithPath: "/tmp/Transcript output")
        let native = WhisperCPPCLIConfiguration(
            executableURL: URL(fileURLWithPath: "/opt/whisper-cli"),
            modelURL: URL(fileURLWithPath: "/Models/ggml.bin"),
            language: "fr",
            useGPU: false
        )
        XCTAssertEqual(
            native.arguments(inputURL: media, outputBaseURL: output),
            [
                "-m", "/Models/ggml.bin",
                "-f", "/tmp/Meeting input.mp4",
                "-ojf",
                "-of", "/tmp/Transcript output",
                "-np",
                "-l", "fr",
                "-ng",
            ]
        )
    }

    func testLocalCLIArgumentsAllowAutomaticLanguageAndGPUSelection() {
        let input = URL(fileURLWithPath: "/input.wav")
        let output = URL(fileURLWithPath: "/output")
        let native = WhisperCPPCLIConfiguration(
            executableURL: URL(fileURLWithPath: "/whisper-cli"),
            modelURL: URL(fileURLWithPath: "/model.bin")
        )

        let nativeArguments = native.arguments(inputURL: input, outputBaseURL: output)
        XCTAssertEqual(Array(nativeArguments.suffix(2)), ["-l", "auto"])
        XCTAssertFalse(native.arguments(inputURL: input, outputBaseURL: output).contains("-ng"))
    }

    func testWhisperCPPJSONFoldsSubwordsAndPunctuationIntoLegacyWords() throws {
        let result = try WhisperCPPJSONTranscriptDecoder.decode(Data(whisperCPPJSON.utf8))

        XCTAssertEqual(result.text, "Open Rewind records locally.")
        XCTAssertEqual(result.language, "en")
        XCTAssertEqual(result.words.map(\.text), ["Open", "Rewind", "records", "locally."])
        XCTAssertEqual(result.words.map(\.fullTextUTF16Offset), [0, 5, 12, 20])
        XCTAssertEqual(result.words.first?.startSeconds, 0)
        XCTAssertEqual(result.words.last?.endSeconds, 2.2)
        XCTAssertEqual(result.words.last!.probability!, 0.925, accuracy: 0.0001)
    }

    func testLegacyClockRequiresExplicitScaleAndPreservesOffsets() throws {
        let result = try WhisperCPPJSONTranscriptDecoder.decode(Data(whisperCPPJSON.utf8))
        let clock = try LegacyTranscriptClock(unitsPerSecond: 100)
        let words = clock.persistenceWords(
            from: result,
            speechSource: "others",
            absoluteOffsetSeconds: 10
        )

        XCTAssertEqual(words.first?.timeOffset, 1_000)
        XCTAssertEqual(words.first?.duration, 24)
        XCTAssertEqual(words.last?.timeOffset, 1_110)
        XCTAssertEqual(words.last?.duration, 110)
        XCTAssertEqual(words.map(\.fullTextOffset), [0, 5, 12, 20])
    }

    func testRecovered15607ClockStoresWholeSecondsWithTruncation() {
        let result = MeetingTranscriptionResult(
            text: "one two",
            language: "en",
            words: [
                .init(
                    text: "one",
                    startSeconds: 1.999,
                    endSeconds: 3.998,
                    fullTextUTF16Offset: 0
                ),
                .init(
                    text: "two",
                    startSeconds: 3.998,
                    endSeconds: 4.499,
                    fullTextUTF16Offset: 4
                ),
            ]
        )

        let words = LegacyTranscriptClock.rewind15607.persistenceWords(
            from: result,
            speechSource: "others"
        )

        XCTAssertEqual(words.map(\.timeOffset), [1, 3])
        XCTAssertEqual(words.map(\.duration), [1, 0])
    }

    func testTranscriptSpeechSourcePresentationPreservesLegacyAndAliasesWithoutGuessing() {
        XCTAssertEqual(
            LibreReverseMeetingSpeechSourceKind(persistedValue: "me"),
            .me
        )
        XCTAssertEqual(
            LibreReverseMeetingSpeechSourceKind(persistedValue: " microphone "),
            .me
        )
        XCTAssertEqual(
            LibreReverseMeetingSpeechSourceKind(persistedValue: "others"),
            .others
        )
        XCTAssertEqual(
            LibreReverseMeetingSpeechSourceKind(persistedValue: "SYSTEM"),
            .others
        )
        XCTAssertEqual(
            LibreReverseMeetingSpeechSourceKind(persistedValue: "unknown"),
            .unknown
        )
        XCTAssertEqual(
            LibreReverseMeetingSpeechSourceKind(persistedValue: "future-source"),
            .unknown
        )
    }

    func testTranscriptSpeechSourceLegendIsStableAndOmitsUnknownCombinedAudio() {
        let transcript = LibreReverseMeetingTranscript(
            segmentID: 7,
            title: "Sources",
            text: "hello there again",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_000_010),
            words: [
                .init(
                    id: 1, speechSource: "unknown", text: "hello",
                    startSeconds: 0, durationSeconds: 1, fullTextUTF16Offset: 0),
                .init(
                    id: 2, speechSource: "others", text: "there",
                    startSeconds: 1, durationSeconds: 1, fullTextUTF16Offset: 6),
                .init(
                    id: 3, speechSource: "me", text: "again",
                    startSeconds: 2, durationSeconds: 1, fullTextUTF16Offset: 12),
                .init(
                    id: 4, speechSource: "system", text: "again",
                    startSeconds: 3, durationSeconds: 1, fullTextUTF16Offset: 12),
            ]
        )

        XCTAssertEqual(transcript.presentedSpeechSources, [.others, .me])
        XCTAssertEqual(
            transcript.presentedSpeechSources.compactMap(\.displayName), ["Others", "You"])

        let combined = LibreReverseMeetingTranscript(
            segmentID: 8,
            title: "Combined",
            text: "neutral",
            startDate: transcript.startDate,
            endDate: transcript.endDate,
            words: [
                .init(
                    id: 5, speechSource: "unknown", text: "neutral",
                    startSeconds: 0, durationSeconds: 1, fullTextUTF16Offset: 0)
            ]
        )
        XCTAssertTrue(combined.presentedSpeechSources.isEmpty)
    }

    func testStreamingOverlapReplacesOnlyUnfinalizedTail() {
        var accumulator = MeetingTranscriptAccumulator()
        accumulator.apply(
            .init(
                text: "first draft", language: "en",
                words: [
                    word("first", 0, 0.8, 0),
                    word("draft", 0.8, 1.6, 6),
                ]),
            windowStartSeconds: 0,
            replaceFromSeconds: 0,
            finalizeThroughSeconds: 0.8
        )
        accumulator.apply(
            .init(
                text: "draft revised ending", language: "en",
                words: [
                    word("draft", 0.3, 0.8, 0),
                    word("revised", 0.8, 1.4, 6),
                    word("ending", 1.4, 2.0, 14),
                ]),
            windowStartSeconds: 0,
            replaceFromSeconds: 0.8,
            finalizeThroughSeconds: 2.0
        )

        let result = accumulator.result(language: "en")
        XCTAssertEqual(result.text, "first revised ending")
        XCTAssertEqual(result.words.map(\.fullTextUTF16Offset), [0, 6, 14])
        XCTAssertEqual(result.words.map(\.startSeconds), [0, 0.8, 1.4])
        XCTAssertEqual(accumulator.finalizedThroughSeconds, 2.0)
    }

    func testMalformedOrUnlocatableWhisperWordsAreRejected() {
        let malformed = """
            {"result":{"language":"en"},"transcription":[{"text":"hello","tokens":[
              {"text":" missing","offsets":{"from":0,"to":200},"p":0.9}
            ]}]}
            """
        XCTAssertThrowsError(try WhisperCPPJSONTranscriptDecoder.decode(Data(malformed.utf8))) {
            XCTAssertEqual(
                $0 as? MeetingTranscriptionError,
                .wordMissingFromTranscript("missing")
            )
        }
    }

    func testSilenceProducesAnExplicitEmptyNativeTranscript() throws {
        let native = try WhisperCPPJSONTranscriptDecoder.decode(
            Data(
                """
                {"result":{"language":"en"},"transcription":[]}
                """.utf8)
        )

        XCTAssertEqual(native.text, "")
        XCTAssertEqual(native.language, "en")
        XCTAssertTrue(native.words.isEmpty)
    }

    func testTwoHourOverlappingStreamConvergesToOfflineTranscript() {
        let duration = 7_200
        let offlineWords = (0..<duration).map { second in
            word(
                second.isMultiple(of: 17) ? "checkpoint." : "word\(second)",
                TimeInterval(second),
                TimeInterval(second) + 0.5,
                0
            )
        }
        var accumulator = MeetingTranscriptAccumulator()
        let windowDuration = 30
        let finalizedStride = 25

        for start in stride(from: 0, to: duration, by: finalizedStride) {
            let end = min(duration, start + windowDuration)
            let relativeWords = offlineWords[start..<end].map { value in
                word(
                    value.text,
                    value.startSeconds - TimeInterval(start),
                    value.endSeconds - TimeInterval(start),
                    0
                )
            }
            accumulator.apply(
                .init(text: "", language: "en", words: relativeWords),
                windowStartSeconds: TimeInterval(start),
                replaceFromSeconds: TimeInterval(start),
                finalizeThroughSeconds: TimeInterval(min(duration, start + finalizedStride))
            )
        }

        let streamed = accumulator.result(language: "en")
        XCTAssertEqual(streamed.words.map(\.text), offlineWords.map(\.text))
        XCTAssertEqual(streamed.words.map(\.startSeconds), offlineWords.map(\.startSeconds))
        XCTAssertEqual(streamed.words.map(\.endSeconds), offlineWords.map(\.endSeconds))
        XCTAssertEqual(streamed.words.last?.fullTextUTF16Offset, streamed.text.utf16.count - 8)
        XCTAssertEqual(accumulator.finalizedThroughSeconds, 7_200)
        XCTAssertLessThanOrEqual(accumulator.lastReplacementBoundaryComparisonCount, 13)
    }

    func testStreamingReplacementSearchHandlesOverlappingWordsWithoutScanningFinalizedPrefix() {
        var accumulator = MeetingTranscriptAccumulator()
        var finalizedPrefix = (0..<8_191).map { second in
            word("word\(second)", TimeInterval(second), TimeInterval(second) + 0.5, 0)
        }
        finalizedPrefix.append(word("crossing", 8_190.75, 8_191.25, 0))
        finalizedPrefix.append(word("draft", 8_191, 8_191.5, 0))
        accumulator.apply(
            .init(text: "", language: "en", words: finalizedPrefix),
            windowStartSeconds: 0,
            replaceFromSeconds: 0,
            finalizeThroughSeconds: 8_191
        )
        accumulator.apply(
            .init(
                text: "",
                language: "en",
                words: [
                    word("replacement", 0, 0.5, 0),
                    word("overlap", 0.25, 0.75, 0),
                ]),
            windowStartSeconds: 8_191,
            replaceFromSeconds: 8_191,
            finalizeThroughSeconds: 8_192
        )

        XCTAssertEqual(accumulator.words.count, 8_193)
        XCTAssertEqual(Array(accumulator.words.suffix(2).map(\.text)), ["replacement", "overlap"])
        XCTAssertLessThanOrEqual(accumulator.lastReplacementBoundaryComparisonCount, 14)
    }

    func testStreamingResultRebuildsUTF16OffsetsInOnePass() {
        var accumulator = MeetingTranscriptAccumulator()
        accumulator.apply(
            .init(
                text: "",
                language: "en",
                words: [word("👋", 0, 0.5, 99), word("café", 0.5, 1, 99)]),
            windowStartSeconds: 0,
            replaceFromSeconds: 0,
            finalizeThroughSeconds: 1
        )

        let result = accumulator.result(language: "en")
        XCTAssertEqual(result.text, "👋 café")
        XCTAssertEqual(result.words.map(\.fullTextUTF16Offset), [0, 3])
    }

    private func word(
        _ text: String,
        _ start: TimeInterval,
        _ end: TimeInterval,
        _ offset: Int
    ) -> MeetingTranscriptionWord {
        .init(
            text: text,
            startSeconds: start,
            endSeconds: end,
            fullTextUTF16Offset: offset
        )
    }

    private func writeAudioFixture(
        to destination: URL,
        activeRange: Range<TimeInterval>,
        frequency: Double
    ) throws {
        let sampleRate = 16_000.0
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        )
        let frameCount = AVAudioFrameCount(sampleRate * 2)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        )
        buffer.frameLength = frameCount
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<Int(frameCount) {
            let time = Double(frame) / sampleRate
            samples[frame] =
                activeRange.contains(time)
                ? Float(0.35 * sin(2 * .pi * frequency * time))
                : 0
        }
        let file = try AVAudioFile(forWriting: destination, settings: format.settings)
        try file.write(from: buffer)
    }

    private func writeMultitrackFixture(sources: [URL], to destination: URL) async throws {
        let composition = AVMutableComposition()
        for source in sources {
            let asset = AVURLAsset(url: source)
            let sourceTracks = try await asset.loadTracks(withMediaType: .audio)
            let sourceTrack = try XCTUnwrap(sourceTracks.first)
            let duration = try await asset.load(.duration)
            let track = try XCTUnwrap(
                composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                )
            )
            try track.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: sourceTrack,
                at: .zero
            )
        }
        let export = try XCTUnwrap(
            AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)
        )
        try await export.export(to: destination, as: .mov)
    }

    private static func rms(in file: AVAudioFile, range: Range<TimeInterval>) throws -> Float {
        let sampleRate = file.processingFormat.sampleRate
        let start = AVAudioFramePosition(range.lowerBound * sampleRate)
        let frameCount = AVAudioFrameCount((range.upperBound - range.lowerBound) * sampleRate)
        file.framePosition = start
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount)
        )
        try file.read(into: buffer, frameCount: frameCount)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        let sum = (0..<Int(buffer.frameLength)).reduce(0.0) { partial, frame in
            let sample = Double(samples[frame])
            return partial + sample * sample
        }
        return Float(sqrt(sum / Double(buffer.frameLength)))
    }

    private static let firstWindowResult = MeetingTranscriptionResult(
        text: "alpha draft",
        language: "en",
        words: [
            .init(text: "alpha", startSeconds: 0, endSeconds: 0.4, fullTextUTF16Offset: 0),
            .init(text: "draft", startSeconds: 0.8, endSeconds: 1, fullTextUTF16Offset: 6),
        ]
    )

    private static let secondWindowResult = MeetingTranscriptionResult(
        text: "revised ending",
        language: "en",
        words: [
            .init(text: "revised", startSeconds: 0, endSeconds: 0.4, fullTextUTF16Offset: 0),
            .init(text: "ending", startSeconds: 0.5, endSeconds: 0.75, fullTextUTF16Offset: 8),
        ]
    )

    private let whisperCPPJSON = """
        {
          "result": {"language":"en"},
          "transcription": [
            {
              "text":" Open Rewind records locally.",
              "tokens":[
                {"text":"[_BEG_]","id":50364,"p":0.8,"t_dtw":0},
                {"text":" Open","offsets":{"from":0,"to":240},"id":1,"p":0.9,"t_dtw":0},
                {"text":" Re","offsets":{"from":240,"to":480},"id":2,"p":0.8,"t_dtw":0},
                {"text":"wind","offsets":{"from":480,"to":680},"id":3,"p":0.7,"t_dtw":0},
                {"text":" records","offsets":{"from":680,"to":1100},"id":4,"p":0.95,"t_dtw":0},
                {"text":" locally","offsets":{"from":1100,"to":1900},"id":5,"p":0.9,"t_dtw":0},
                {"text":".","offsets":{"from":1900,"to":2200},"id":6,"p":0.95,"t_dtw":0}
              ]
            }
          ]
        }
        """
}

private final class ExportCompletionSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (Error?) -> Void)?
    private var didComplete = false
    var completed: Bool { lock.lock(); defer { lock.unlock() }; return didComplete }
    func store(_ callback: @escaping @Sendable (Error?) -> Void) {
        lock.lock(); self.callback = callback; lock.unlock()
    }
    func finish() {
        lock.lock()
        didComplete = true
        let completion = callback
        callback = nil
        lock.unlock()
        completion?(nil)
    }
}

private actor WindowCallLog {
    private var items: [String] = []

    func append(_ value: String) { items.append(value) }
    func values() -> [String] { items }
}

extension Collection {
    fileprivate var only: Element? {
        count == 1 ? first : nil
    }
}
#endif
