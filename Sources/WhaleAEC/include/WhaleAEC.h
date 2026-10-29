#pragma once
#ifdef __cplusplus
extern "C" {
#endif
// Each instance processes chronological 10ms mono float frames at 48kHz.
void *whale_aec_create(void);
void whale_aec_destroy(void *instance);
int whale_aec_process(void *instance, const float *render, const float *capture, float *output);
#ifdef __cplusplus
}
#endif
