#include "WhaleAEC.h"
#include "api/audio/audio_processing.h"
#include <new>

struct Processor {
    rtc::scoped_refptr<webrtc::AudioProcessing> apm;
    webrtc::StreamConfig format{48000, 1};
};
void *whale_aec_create(void) {
    auto p = new (std::nothrow) Processor;
    if (!p) return nullptr;
    p->apm = webrtc::AudioProcessingBuilder().Create();
    if (!p->apm) { delete p; return nullptr; }
    webrtc::AudioProcessing::Config config;
    config.echo_canceller.enabled = true;
    config.echo_canceller.mobile_mode = false;
    // Do not normalize voices or apply unrelated denoising to the archive.
    config.gain_controller1.enabled = false;
    config.gain_controller2.enabled = false;
    config.noise_suppression.enabled = false;
    config.high_pass_filter.enabled = false;
    p->apm->ApplyConfig(config);
    if (p->apm->Initialize() != 0) { delete p; return nullptr; }
    return p;
}
void whale_aec_destroy(void *instance) { delete static_cast<Processor *>(instance); }
int whale_aec_process(void *instance, const float *render, const float *capture, float *output) {
    if (!instance || !render || !capture || !output) return -1;
    auto p = static_cast<Processor *>(instance);
    float scratch[480];
    const float *r[] = {render}; float *s[] = {scratch};
    int result = p->apm->ProcessReverseStream(r, p->format, p->format, s);
    if (result != 0) return result;
    // Files share the capture clock; AEC3 estimates the remaining acoustic delay.
    result = p->apm->set_stream_delay_ms(0);
    if (result != 0) return result;
    const float *c[] = {capture}; float *o[] = {output};
    return p->apm->ProcessStream(c, p->format, p->format, o);
}
