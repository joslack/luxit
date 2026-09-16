#ifndef LUXIT_VOICE_ACTIVITY_H
#define LUXIT_VOICE_ACTIVITY_H
void luxit_audio_backend_lock(void);
void luxit_audio_backend_unlock(void);
void * luxit_voice_activity_create(const char * path);
void luxit_voice_activity_reset(void * context);
float luxit_voice_activity_probability(void * context, const float * samples, int count);
void luxit_voice_activity_free(void * context);
#endif
