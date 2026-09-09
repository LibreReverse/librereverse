#if os(macOS)
import AVFoundation
import Testing
@testable import LibreReverseCore

struct HighFidelityMeetingCaptureTests {
    @Test
    func missingCallbackRequiresMediaCoveringTheCapture() {
        #expect(MeetingCaptureFinalizationPolicy.coversCapture(mediaDuration: 96, capturedDuration: 96.1))
        #expect(!MeetingCaptureFinalizationPolicy.coversCapture(mediaDuration: 40, capturedDuration: 96))
        #expect(!MeetingCaptureFinalizationPolicy.coversCapture(mediaDuration: .nan, capturedDuration: 96))
        #expect(!MeetingCaptureFinalizationPolicy.coversCapture(mediaDuration: 96, capturedDuration: 0))
    }

    private func configuration(
        frameRate: Int = 60,
        expectedSourceFrameRate: Int = 30,
        requestedDurationSeconds: Double? = 30
    ) -> HighFidelityMeetingCaptureConfiguration {
        HighFidelityMeetingCaptureConfiguration(
            outputURL: URL(fileURLWithPath: "/tmp/capture.mp4"),
            manifestURL: URL(fileURLWithPath: "/tmp/manifest.json"),
            displayID: 1,
            frameRate: frameRate,
            expectedSourceFrameRate: expectedSourceFrameRate,
            requestedDurationSeconds: requestedDurationSeconds
        )
    }

    @Test
    func recordingFinishLatchObservesCompletionBeforeWait() async {
        let latch = MeetingCaptureFinishLatch()
        latch.finish()
        let finished = await latch.wait(timeoutSeconds: 0.01)
        #expect(finished)
    }

    @Test
    func recordingFinishLatchResumesRegisteredWaiterExactlyOnce() async {
        let latch = MeetingCaptureFinishLatch()
        async let result = latch.wait(timeoutSeconds: 1)
        await Task.yield()
        latch.finish()
        #expect(await result)
    }

    @Test
    func recordingFinishLatchTimesOutAndAcceptsLateCompletion() async {
        let latch = MeetingCaptureFinishLatch()
        let timedOut = await latch.wait(timeoutSeconds: 0.01)
        #expect(!timedOut)

        latch.finish()
        let finished = await latch.wait(timeoutSeconds: 0.01)
        #expect(finished)
    }

    @Test
    func sessionRejectsUnsafeFrameRatesBeforeCaptureSetup() throws {
        for (frameRate, sourceFrameRate) in [
            (0, 30),
            (-1, 30),
            (HighFidelityMeetingCaptureSession.maximumSupportedFrameRate + 1, 30),
            (60, 0),
            (60, -1),
            (60, HighFidelityMeetingCaptureSession.maximumSupportedFrameRate + 1),
        ] {
            do {
                _ = try HighFidelityMeetingCaptureSession(
                    configuration: configuration(
                        frameRate: frameRate,
                        expectedSourceFrameRate: sourceFrameRate
                    )
                )
                Issue.record("unsafe frame-rate configuration was accepted")
            } catch HighFidelityMeetingCaptureError.invalidFrameRate(_) {
                // Expected: constructor validation performs no capture I/O.
            }
        }

        _ = try HighFidelityMeetingCaptureSession(
            configuration: configuration(
                frameRate: HighFidelityMeetingCaptureSession.maximumSupportedFrameRate,
                expectedSourceFrameRate:
                    HighFidelityMeetingCaptureSession.maximumSupportedFrameRate
            )
        )
    }

    @Test
    func sessionRejectsUnsafeRequestedDurationsBeforeCaptureSetup() throws {
        let invalidDurations: [Double] = [
            0,
            -1,
            .nan,
            .infinity,
            -Double.infinity,
            HighFidelityMeetingCaptureSession.maximumSupportedRequestedDurationSeconds + 1,
        ]
        for duration in invalidDurations {
            do {
                _ = try HighFidelityMeetingCaptureSession(
                    configuration: configuration(requestedDurationSeconds: duration)
                )
                Issue.record("unsafe duration configuration was accepted")
            } catch HighFidelityMeetingCaptureError.invalidRequestedDuration(_) {
                // Expected: constructor validation performs no capture I/O.
            }
        }

        _ = try HighFidelityMeetingCaptureSession(
            configuration: configuration(requestedDurationSeconds: nil)
        )
        _ = try HighFidelityMeetingCaptureSession(
            configuration: configuration(
                requestedDurationSeconds:
                    HighFidelityMeetingCaptureSession.maximumSupportedRequestedDurationSeconds
            )
        )
    }

    @Test
    func finalizedPartialOutputRequiresIntegrityEvidence() {
        #expect(
            HighFidelityMeetingCaptureManifest.requiresOutputIntegrity(
                state: .completed,
                writerStatus: "completed"
            ))
        #expect(
            HighFidelityMeetingCaptureManifest.requiresOutputIntegrity(
                state: .failed,
                writerStatus: "completed"
            ))
        #expect(
            !HighFidelityMeetingCaptureManifest.requiresOutputIntegrity(
                state: .failed,
                writerStatus: "failed"
            ))
    }

    @Test
    func validationManifestCarriesRequestedDurationEvidence() throws {
        let output = URL(fileURLWithPath: "/tmp/capture.mp4")
        let configuration = HighFidelityMeetingCaptureConfiguration(
            outputURL: output,
            manifestURL: URL(fileURLWithPath: "/tmp/manifest.json"),
            displayID: 1,
            frameRate: 120,
            expectedSourceFrameRate: 60,
            requestedDurationSeconds: 10,
            publicationXID: "01HF7YAT00TESTPUBLICATIONXID"
        )
        #expect(configuration.requestedDurationSeconds == 10)
        #expect(configuration.publicationXID == "01HF7YAT00TESTPUBLICATIONXID")

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let manifest = HighFidelityMeetingCaptureManifest(
            schemaVersion: 5,
            state: .completed,
            finalizationReason: "configuredDurationElapsed",
            outputPath: output.path,
            displayID: 1,
            width: 1920,
            height: 1080,
            requestedFrameRate: 120,
            expectedSourceFrameRate: 60,
            capturesSystemAudio: true,
            capturesMicrophone: false,
            microphoneDeviceID: nil,
            startedAt: start,
            finishedAt: start.addingTimeInterval(10),
            hostClockStartSeconds: 1,
            writerStatus: "completed",
            writerError: nil,
            streamError: nil,
            timestamps: .init(frameRate: 60),
            requestedDurationSeconds: 10,
            outputByteCount: 42,
            outputSHA256: String(repeating: "ab", count: 32),
            publicationXID: "01HF7YAT00TESTPUBLICATIONXID"
        )
        let decoded = try JSONDecoder().decode(
            HighFidelityMeetingCaptureManifest.self,
            from: JSONEncoder().encode(manifest)
        )
        #expect(decoded == manifest)
        #expect(decoded.requestedDurationSeconds == 10)
        #expect(decoded.outputByteCount == 42)
        #expect(decoded.outputSHA256 == String(repeating: "ab", count: 32))
        #expect(decoded.publicationXID == "01HF7YAT00TESTPUBLICATIONXID")
        #expect(decoded.hasSupportedSchemaVersion)

        var legacyObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest))
                as? [String: Any]
        )
        legacyObject.removeValue(forKey: "requestedDurationSeconds")
        legacyObject.removeValue(forKey: "outputByteCount")
        legacyObject.removeValue(forKey: "outputSHA256")
        legacyObject.removeValue(forKey: "publicationXID")
        let legacyDecoded = try JSONDecoder().decode(
            HighFidelityMeetingCaptureManifest.self,
            from: JSONSerialization.data(withJSONObject: legacyObject)
        )
        #expect(legacyDecoded.requestedDurationSeconds == nil)
        #expect(legacyDecoded.outputByteCount == nil)
        #expect(legacyDecoded.outputSHA256 == nil)
        #expect(legacyDecoded.publicationXID == nil)

        var futureObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest))
                as? [String: Any]
        )
        futureObject["schemaVersion"] = 99
        let futureDecoded = try JSONDecoder().decode(
            HighFidelityMeetingCaptureManifest.self,
            from: JSONSerialization.data(withJSONObject: futureObject)
        )
        #expect(!futureDecoded.hasSupportedSchemaVersion)
    }

    @Test
    func timestampLedgerAcceptsCompleteThirtyFPSSequence() {
        var ledger = MeetingCaptureTimestampLedger(frameRate: 30)
        for frame in 0..<300 {
            ledger.recordVideo(presentationTimeSeconds: Double(frame) / 30)
        }

        #expect(ledger.video.sampleBufferCount == 300)
        #expect(ledger.video.mediaSampleCount == 300)
        #expect(ledger.video.discontinuityCount == 0)
        #expect(ledger.missingVideoFrameSlotCount == 0)
        #expect(ledger.duplicateVideoFrameSlotCount == 0)
        #expect(ledger.incompleteVideoSampleCount == 0)
        #expect(ledger.video.coveredDurationSeconds == 299.0 / 30.0)
    }

    @Test
    func timestampLedgerReportsGapAndReversal() {
        var ledger = MeetingCaptureTimestampLedger(frameRate: 30)
        ledger.recordVideo(presentationTimeSeconds: 10)
        ledger.recordVideo(presentationTimeSeconds: 10 + 1.0 / 30.0)
        ledger.recordVideo(presentationTimeSeconds: 10.2)
        ledger.recordVideo(presentationTimeSeconds: 10.1)

        #expect(ledger.video.discontinuityCount == 2)
        #expect(ledger.missingVideoFrameSlotCount == 4)
        #expect(ledger.duplicateVideoFrameSlotCount == 1)
        #expect(ledger.video.largestPresentationGapSeconds > 0.16)
    }

    @Test
    func decodedDiscontinuityCounterSaturatesInsteadOfOverflowing() throws {
        var object = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(MeetingCaptureTimestampLedger(frameRate: 30))
            ) as? [String: Any]
        )
        var video = try #require(object["video"] as? [String: Any])
        video["sampleBufferCount"] = 1
        video["mediaSampleCount"] = 1
        video["firstPresentationTimeSeconds"] = 0.0
        video["lastPresentationTimeSeconds"] = 0.0
        video["discontinuityCount"] = Int.max
        object["video"] = video
        var ledger = try JSONDecoder().decode(
            MeetingCaptureTimestampLedger.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        let accepted = ledger.recordVideo(presentationTimeSeconds: 1)
        #expect(accepted)
        #expect(ledger.video.discontinuityCount == Int.max)
        #expect(ledger.video.sampleBufferCount == 2)
    }

    @Test
    func timestampLedgerRejectsInvalidAndOverflowSizedVideoTimesWithoutTrapping() {
        var ledger = MeetingCaptureTimestampLedger(frameRate: 60)
        let acceptedNaN = ledger.recordVideo(presentationTimeSeconds: .nan)
        let acceptedInfinity = ledger.recordVideo(presentationTimeSeconds: .infinity)
        let acceptedExtreme = ledger.recordVideo(
            presentationTimeSeconds: .greatestFiniteMagnitude)
        #expect(!acceptedNaN)
        #expect(!acceptedInfinity)
        #expect(!acceptedExtreme)
        #expect(ledger.invalidTimestampCount == 3)
        #expect(ledger.video.sampleBufferCount == 0)

        let acceptedValid = ledger.recordVideo(presentationTimeSeconds: 1)
        #expect(acceptedValid)
        #expect(ledger.video.sampleBufferCount == 1)
        #expect(ledger.invalidTimestampCount == 3)
    }

    @Test
    func timestampLedgerRejectsInvalidAudioAndMicrophoneDurations() {
        var ledger = MeetingCaptureTimestampLedger(frameRate: 60)
        let acceptedAudio = ledger.recordAudio(
            presentationTimeSeconds: 1,
            durationSeconds: -.infinity,
            mediaSampleCount: 1
        )
        let acceptedMicrophone = ledger.recordMicrophone(
            presentationTimeSeconds: .nan,
            durationSeconds: 0.02,
            mediaSampleCount: 1
        )
        let acceptedZeroAudio = ledger.recordAudio(
            presentationTimeSeconds: 1,
            durationSeconds: 0,
            mediaSampleCount: 1
        )
        let acceptedZeroMicrophone = ledger.recordMicrophone(
            presentationTimeSeconds: 1,
            durationSeconds: 0,
            mediaSampleCount: 1
        )
        #expect(!acceptedAudio)
        #expect(!acceptedMicrophone)
        #expect(!acceptedZeroAudio)
        #expect(!acceptedZeroMicrophone)
        #expect(ledger.invalidTimestampCount == 4)
        #expect(ledger.audio.sampleBufferCount == 0)
        #expect(ledger.microphone.sampleBufferCount == 0)
    }

    @Test
    func timestampLedgerRejectsInvalidCountsAndPeakTelemetry() {
        var ledger = MeetingCaptureTimestampLedger(frameRate: 60)
        let acceptedEmptyVideo = ledger.recordVideo(
            presentationTimeSeconds: 1,
            mediaSampleCount: 0
        )
        let acceptedNaNPeak = ledger.recordAudio(
            presentationTimeSeconds: 1,
            durationSeconds: 0.02,
            mediaSampleCount: 960,
            peakAbsolute: .nan
        )
        let acceptedNegativePeak = ledger.recordMicrophone(
            presentationTimeSeconds: 1,
            durationSeconds: 0.02,
            mediaSampleCount: 960,
            peakAbsolute: -0.5
        )
        #expect(!acceptedEmptyVideo)
        #expect(!acceptedNaNPeak)
        #expect(!acceptedNegativePeak)
        #expect(ledger.invalidSampleMetadataCount == 3)
        #expect(ledger.invalidTimestampCount == 0)
        #expect(ledger.video.sampleBufferCount == 0)
        #expect(ledger.audio.sampleBufferCount == 0)
        #expect(ledger.microphone.sampleBufferCount == 0)
        #expect(ledger.audioPeakAbsolute == 0)
        #expect(ledger.microphonePeakAbsolute == 0)
    }

    @Test
    func timestampLedgerRejectsMediaCountOverflowWithoutTrapping() {
        var ledger = MeetingCaptureTimestampLedger(frameRate: 60)
        let acceptedMaximum = ledger.recordVideo(
            presentationTimeSeconds: 1,
            mediaSampleCount: Int.max
        )
        let acceptedOverflow = ledger.recordVideo(
            presentationTimeSeconds: 1 + 1.0 / 60.0,
            mediaSampleCount: 1
        )
        #expect(acceptedMaximum)
        #expect(!acceptedOverflow)
        #expect(ledger.video.mediaSampleCount == Int.max)
        #expect(ledger.video.sampleBufferCount == 1)
        #expect(ledger.invalidSampleMetadataCount == 1)
    }

    @Test
    func legacyTimestampLedgerWithoutInvalidCountStillDecodes() throws {
        var object = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(MeetingCaptureTimestampLedger(frameRate: 30))
            ) as? [String: Any]
        )
        object.removeValue(forKey: "invalidTimestampCount")
        object.removeValue(forKey: "invalidSampleMetadataCount")
        object.removeValue(forKey: "invalidSampleBufferCount")
        for trackName in ["video", "audio", "microphone"] {
            var track = try #require(object[trackName] as? [String: Any])
            track.removeValue(forKey: "lastExpectedIntervalSeconds")
            object[trackName] = track
        }
        let decoded = try JSONDecoder().decode(
            MeetingCaptureTimestampLedger.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.invalidTimestampCount == nil)
        #expect(decoded.invalidSampleMetadataCount == nil)
        #expect(decoded.invalidSampleBufferCount == nil)
        #expect(decoded.video.sampleBufferCount == 0)
        #expect(decoded.video.lastExpectedIntervalSeconds == nil)
        #expect(decoded.audio.lastExpectedIntervalSeconds == nil)
        #expect(decoded.microphone.lastExpectedIntervalSeconds == nil)
    }

    @Test
    func timestampLedgerToleratesDisplayRefreshJitterWithinFrameSlots() {
        var ledger = MeetingCaptureTimestampLedger(frameRate: 30)
        let times = [0.0, 0.041_667, 0.066_667, 0.108_334, 0.133_334]
        for time in times {
            ledger.recordVideo(presentationTimeSeconds: time)
        }

        #expect(ledger.missingVideoFrameSlotCount == 0)
        #expect(ledger.duplicateVideoFrameSlotCount == 0)
    }

    @Test
    func timestampLedgerSeparatesCaptureAndWriterDrops() {
        var ledger = MeetingCaptureTimestampLedger(frameRate: 60)
        ledger.recordInvalidSampleBuffer()
        ledger.recordIncompleteVideoSample(statusRawValue: 1)
        ledger.recordBackpressure(mediaType: .video)
        ledger.recordBackpressure(mediaType: .audio)
        ledger.recordAppendFailure()

        #expect(ledger.incompleteVideoSampleCount == 1)
        #expect(ledger.invalidSampleBufferCount == 1)
        #expect(ledger.nonCompleteVideoStatusCounts == ["raw-1": 1])
        #expect(ledger.videoAppendBackpressureCount == 1)
        #expect(ledger.audioAppendBackpressureCount == 1)
        #expect(ledger.appendFailureCount == 1)
    }

    @Test
    func audioPacketCadenceDoesNotUseVideoThreshold() {
        var ledger = MeetingCaptureTimestampLedger(frameRate: 30)
        let packetDuration = 1_024.0 / 48_000.0
        for packet in 0..<100 {
            ledger.recordAudio(
                presentationTimeSeconds: Double(packet) * packetDuration,
                durationSeconds: packetDuration,
                mediaSampleCount: 1_024,
                peakAbsolute: packet == 50 ? 0.75 : 0
            )
        }

        #expect(ledger.audio.sampleBufferCount == 100)
        #expect(ledger.audio.mediaSampleCount == 102_400)
        #expect(ledger.audio.discontinuityCount == 0)
        #expect(ledger.audioPeakAbsolute == 0.75)
        #expect(ledger.nonSilentAudioSampleBufferCount == 1)
    }

    @Test
    func variableAudioDurationsUsePrecedingBufferForGapClassification() {
        var ledger = MeetingCaptureTimestampLedger(frameRate: 60)
        ledger.recordAudio(
            presentationTimeSeconds: 0,
            durationSeconds: 0.02,
            mediaSampleCount: 960
        )
        ledger.recordAudio(
            presentationTimeSeconds: 0.10,
            durationSeconds: 0.20,
            mediaSampleCount: 9_600
        )
        #expect(ledger.audio.discontinuityCount == 1)
        #expect(ledger.audio.lastExpectedIntervalSeconds == 0.20)

        var overlapping = MeetingCaptureTimestampLedger(frameRate: 60)
        overlapping.recordAudio(
            presentationTimeSeconds: 0,
            durationSeconds: 0.20,
            mediaSampleCount: 9_600
        )
        overlapping.recordAudio(
            presentationTimeSeconds: 0.10,
            durationSeconds: 0.02,
            mediaSampleCount: 960
        )
        #expect(overlapping.audio.discontinuityCount == 0)
    }

    @Test
    func variableMicrophoneDurationsUsePrecedingBufferForGapClassification() {
        var ledger = MeetingCaptureTimestampLedger(frameRate: 60)
        ledger.recordMicrophone(
            presentationTimeSeconds: 0,
            durationSeconds: 0.01,
            mediaSampleCount: 480
        )
        ledger.recordMicrophone(
            presentationTimeSeconds: 0.05,
            durationSeconds: 0.10,
            mediaSampleCount: 4_800
        )
        #expect(ledger.microphone.discontinuityCount == 1)

        var continuous = MeetingCaptureTimestampLedger(frameRate: 60)
        continuous.recordMicrophone(
            presentationTimeSeconds: 0,
            durationSeconds: 0.10,
            mediaSampleCount: 4_800
        )
        continuous.recordMicrophone(
            presentationTimeSeconds: 0.05,
            durationSeconds: 0.01,
            mediaSampleCount: 480
        )
        #expect(continuous.microphone.discontinuityCount == 0)
    }

    @Test
    func microphoneStatisticsRemainIndependentFromSystemAudio() {
        var ledger = MeetingCaptureTimestampLedger(frameRate: 60)
        ledger.recordAudio(
            presentationTimeSeconds: 1,
            durationSeconds: 0.02,
            mediaSampleCount: 960,
            peakAbsolute: 0.25
        )
        ledger.recordMicrophone(
            presentationTimeSeconds: 1.005,
            durationSeconds: 0.01,
            mediaSampleCount: 480,
            peakAbsolute: 0.75
        )

        #expect(ledger.audio.sampleBufferCount == 1)
        #expect(ledger.audio.mediaSampleCount == 960)
        #expect(ledger.audioPeakAbsolute == 0.25)
        #expect(ledger.microphone.sampleBufferCount == 1)
        #expect(ledger.microphone.mediaSampleCount == 480)
        #expect(ledger.microphonePeakAbsolute == 0.75)
        #expect(ledger.nonSilentMicrophoneSampleBufferCount == 1)
    }

    @Test
    func schemaSixTerminalTelemetryRequiresEveryRequestedSourceAndZeroLoss() {
        var complete = MeetingCaptureTimestampLedger(frameRate: 30)
        let acceptedVideo = complete.recordVideo(
            presentationTimeSeconds: 0,
            mediaSampleCount: 1
        )
        let acceptedAudio = complete.recordAudio(
            presentationTimeSeconds: 0,
            durationSeconds: 0.02,
            mediaSampleCount: 960
        )
        let acceptedMicrophone = complete.recordMicrophone(
            presentationTimeSeconds: 0,
            durationSeconds: 0.02,
            mediaSampleCount: 960
        )
        #expect(acceptedVideo)
        #expect(acceptedAudio)
        #expect(acceptedMicrophone)
        #expect(
            complete.terminalValidationIssue(
                capturesSystemAudio: true,
                capturesMicrophone: true
            ) == nil
        )

        var missingMicrophone = MeetingCaptureTimestampLedger(frameRate: 30)
        let acceptedMissingMicrophoneVideo = missingMicrophone.recordVideo(
            presentationTimeSeconds: 0
        )
        let acceptedMissingMicrophoneAudio = missingMicrophone.recordAudio(
            presentationTimeSeconds: 0,
            durationSeconds: 0.02,
            mediaSampleCount: 960
        )
        #expect(acceptedMissingMicrophoneVideo)
        #expect(acceptedMissingMicrophoneAudio)
        #expect(
            missingMicrophone.terminalValidationIssue(
                capturesSystemAudio: true,
                capturesMicrophone: true
            ) == "microphone delivered no samples"
        )

        var missingFrame = complete
        let acceptedGappedFrame = missingFrame.recordVideo(
            presentationTimeSeconds: 2.0 / 30.0
        )
        #expect(acceptedGappedFrame)
        #expect(missingFrame.missingVideoFrameSlotCount == 1)
        #expect(
            missingFrame.terminalValidationIssue(
                capturesSystemAudio: true,
                capturesMicrophone: true
            ) == nil
        )
    }
}
#endif
