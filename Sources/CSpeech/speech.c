#include "speech.h"
#include <dlfcn.h>
#include <stdlib.h>
struct LRSpeech {
    void *library, *processor;
    void (*destroy)(void *);
    int (*process)(void *, float *, int);
    int (*render)(void *, float *, float *, int);
};
LRSpeech *lr_speech_open(const char *path, int echo_cancellation) {
    if (!path || path[0] != '/') return NULL;
    void *library = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!library) return NULL;
    void *(*create)(int) = (void *(*)(int))dlsym(library, "lr_speech_create_v2");
    void (*destroy)(void *) = (void (*)(void *))dlsym(library, "lr_speech_destroy");
    int (*process)(void *, float *, int) = (int (*)(void *, float *, int))dlsym(library, "lr_speech_process");
    int (*render)(void *, float *, float *, int) = (int (*)(void *, float *, float *, int))dlsym(library, "lr_speech_render");
    if (!create || !destroy || !process || !render) { dlclose(library); return NULL; }
    LRSpeech *result = calloc(1, sizeof(LRSpeech));
    if (!result) { dlclose(library); return NULL; }
    result->library = library; result->destroy = destroy; result->process = process;
    result->render = render;
    result->processor = create(echo_cancellation);
    if (!result->processor) { free(result); dlclose(library); return NULL; }
    return result;
}
int lr_speech_frame(LRSpeech *p, float *samples, int count) {
    return p ? p->process(p->processor, samples, count) : -1;
}
int lr_speech_reference(LRSpeech *p, float *left, float *right, int count) {
    return p ? p->render(p->processor, left, right, count) : -1;
}
void lr_speech_close(LRSpeech *p) {
    if (!p) return;
    p->destroy(p->processor); dlclose(p->library); free(p);
}
