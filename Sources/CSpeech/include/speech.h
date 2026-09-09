#ifndef LIBREREVERSE_SPEECH_H
#define LIBREREVERSE_SPEECH_H
#ifdef __cplusplus
extern "C" {
#endif
typedef struct LRSpeech LRSpeech;
LRSpeech *lr_speech_open(const char *absolute_library_path, int echo_cancellation);
int lr_speech_frame(LRSpeech *, float *samples, int count);
int lr_speech_reference(LRSpeech *, float *left, float *right, int count);
void lr_speech_close(LRSpeech *);
#ifdef __cplusplus
}
#endif
#endif
