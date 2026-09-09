#include "api/audio/audio_processing.h"
#include <algorithm>
#include <cmath>
#include <memory>

// Only this narrow ABI is public. The complete APM and Abseil are linked into
// one library; no networking, device control, or playback engine is included.
struct Processor { rtc::scoped_refptr<webrtc::AudioProcessing> apm; };
#define EXPORT extern "C" __attribute__((visibility("default")))
EXPORT void* lr_speech_create_v2(int echo_cancellation) noexcept {
  try {
    webrtc::AudioProcessing::Config config;
    config.high_pass_filter.enabled = true;
    config.noise_suppression.enabled = true;
    config.noise_suppression.level = webrtc::AudioProcessing::Config::NoiseSuppression::kModerate;
    // Digital gain only: never adjust the device's gain or other applications.
    config.gain_controller1.enabled = false;
    config.gain_controller2.enabled = true;
    config.gain_controller2.input_volume_controller.enabled = false;
    config.gain_controller2.adaptive_digital.enabled = true;
    config.gain_controller2.adaptive_digital.max_gain_db = 30;
    config.gain_controller2.adaptive_digital.initial_gain_db = 10;
    // AEC3 estimates the remaining acoustic delay itself. The caller supplies
    // timestamp-aligned render frames; there is no guessed hardware delay.
    config.echo_canceller.enabled = echo_cancellation != 0;
    config.echo_canceller.mobile_mode = false;
    config.pipeline.multi_channel_render = true;
    auto p = std::make_unique<Processor>();
    p->apm = webrtc::AudioProcessingBuilder().SetConfig(config).Create();
    if (!p->apm || p->apm->Initialize() != 0) return nullptr;
    return p.release();
  } catch (...) { return nullptr; }
}
EXPORT void lr_speech_destroy(void* instance) noexcept { delete static_cast<Processor*>(instance); }
EXPORT int lr_speech_process(void* instance, float* samples, int count) noexcept {
  if (!instance || !samples || count != 480) return -1;
  for (int i = 0; i < count; ++i) if (!std::isfinite(samples[i])) return -2;
  try {
    const float* source[] = {samples}; float* destination[] = {samples};
    const webrtc::StreamConfig format(48000, 1);
    return static_cast<Processor*>(instance)->apm->ProcessStream(source, format, format, destination);
  } catch (...) { return -3; }
}

EXPORT int lr_speech_render(void* instance, float* left, float* right, int count) noexcept {
  if (!instance || !left || !right || count != 480) return -1;
  for (int i = 0; i < count; ++i)
    if (!std::isfinite(left[i]) || !std::isfinite(right[i])) return -2;
  try {
    const float* source[] = {left, right}; float* destination[] = {left, right};
    const webrtc::StreamConfig format(48000, 2);
    return static_cast<Processor*>(instance)->apm->ProcessReverseStream(source, format, format, destination);
  } catch (...) { return -3; }
}
