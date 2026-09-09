#!/bin/zsh
set -euo pipefail
workspace_dir="${0:A:h:h}"
cd "$workspace_dir"
mode="${1:-unit}"
if (( $# > 0 )); then shift; fi
# These cases exercise real codecs/GPU/media readers. The remaining publication,
# archive, queue, search, and playback-policy tests stay in the default suite.
integration_pattern='MeetingEchoCancellationTests|MeetingSpeechProcessingTests|NativeCaptureBufferTests|VisionOCRRecognitionTests|MetalScreenDifferTests|FrameVideoWriterBackpressureTests|CapturePersistenceTests|ArchivedMediaPlaybackTests|MeetingTranscriptionTests/(testNormalizedPCMExportSurvivesCancellationAndRestart|testConcurrentPCMExportsOwnDistinctIntermediatePaths|testNormalizedPCMWindowCopyHasExactBoundedFrameCount|testNormalizedPCMExplicitlyMixesEveryMeetingAudioTrack|testBundledTranscriberActuallyRunsWindowsAndReducesOverlap|testBundledTranscriberResumesAtFirstUncommittedWindow)|MeetingWaveformTests/(testDecoderAndPersistentCachePreserveActualAudioAndInvalidateChangedFile|testLegacyIndexPreservesPublishedBytesAndSurvivesRehydration|testMissingRemoteAndCorruptMediaFailWithoutCreatingCache)|CanonicalRecorderMetadataTests/(testSessionDropsCommittedMetadataAndRetainsFailedCommitForRestart|testRecoveryAcrossDimensionBoundariesUsesStableFrameIDs)|LibreReverseMeetingPublicationTests/(testCompletionTimeoutRecoveryPreservesTelemetryAndPublishesIdempotently|testCrashCheckpointRecoversReadableVideoAndPublishesIdempotently|testFinalMediaInspectorReadsBackVideoAndRejectsMissingRequestedAudio|testCrashRecoveryRequiresMatchingDimensionsAndRequestedAudio)'
run_python_tests() {
  for test_file in scripts/test_*.py(N.); do
    # Keep the real-model CLI outside normal automated test execution.
    [[ "${test_file:t}" == test_whisper_vad_clock.py ]] && continue
    python3 "$test_file"
  done
}
case "$mode" in
  unit)
    run_python_tests
    swift test --skip "$integration_pattern" "$@"
    ;;
  integration)
    swift test --filter "$integration_pattern" "$@"
    ;;
  all)
    run_python_tests
    swift test "$@"
    ;;
  *) print -u2 'Usage: scripts/test.sh [unit|integration|all] [swift test options]'; exit 2 ;;
esac
