// nn::codec's VP9 decoder and the nn::syncpt events it completes through (Mario Kart World 1.0.0, SDK 19.3.3), taken over with libvpx. Its movie player is built into main (main+0x19e5748..
// main+0x19e82a0, no symbols) and drives nn::codec directly: the SDK's own reaches a decoder service the host does not have and aborts in nv::InitCheck when a race or the title's movie
// starts. 1.8.0 links the same class as movie::VideoDecoder in subsdk0 instead (hle_nx2_movie.c). The game's class runs as it is; this answers what it asks of nn::codec.
// The protocol, from the class: one image per decoder image pool (InitializeDecoderImagePool count 1), registered as an output buffer each (RegisterVp9DecoderBuffer). A frame slot
// releases its buffer and at once acquires the next (main+0x19e6e00), with a NativeSyncHandle that it turns into a SyncPointEvent (RequestSyncPointEvent) linked into its multi-wait;
// once that is signalled it reads the buffer's properties and copies the picture out as NV12 (ReadDecoderOutputImageNv12, rows packed at the pool's width). Buffers are filled in the
// order they were acquired, each with the next picture decoded; a sync handle is (decoder, acquire sequence number), complete once that many pictures are out.
// A SyncPointEventType here is a SystemEventType bound to a kernel event (the class leaves it 0x80 bytes), so the SDK's multi-wait code takes it as it is.
// Decoding runs on a worker thread per decoder, as the console's decoder runs beside the player: Submit queues a copy of the packet and returns, pictures arrive later. Decoded on the
// submitting thread instead, a movie could end before the player's other threads expected it to, and the game crashed in its player at movie changes (main+0x70fcc4, main+0x3ec1d8).
// Decoders are kept in a registry: a sync handle or an image pool that outlives its decoder must not reach freed memory.
// Open: 4:2:0 8-bit only; the colour space is reported as 0; the GPU image handle (GetDecoderImagePoolNativeImageHandle) is not provided
#include "hle.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "vpx/vpx_decoder.h"
#include "vpx/vp8dx.h"

enum { CV_BUFS = 32, CV_PICS = 16, CV_PICS_READY = 8, CV_WAITS = 128, CV_DECS = 16 };
// The one Submit result the class takes as "try again" (main+0x19e801c: its DecodeAsync then returns 0x76 and the player feeds the packet again once the submission-ready event is
// signalled); the other two it checks for abort
#define CV_RES_BUSY 0x1c266fu
typedef struct { uint8_t *nv12; uint64_t cap; uint32_t w, h; } cv_img;                       // a pool's one image, kept on the host
typedef struct { uint8_t *nv12; uint32_t w, h; int64_t pts; int eos; } cv_pic;               // a picture, before a buffer is acquired for it
typedef struct cv_pkt { struct cv_pkt *next; uint64_t n, gen; int64_t pts; int eos; uint8_t data[]; } cv_pkt;   // a submitted packet, not decoded yet
typedef struct {
    vpx_codec_ctx_t vpx; int vpx_on, bad;          // the worker's own
    pthread_t thr; pthread_cond_t cond; int stop;
    cv_pkt *qh, *qt; int nq; uint64_t gen;         // packets queued for the worker; a flush starts a new generation, so pictures of packets before it are dropped
    cv_img *buf[CV_BUFS]; struct { uint16_t w, h; int64_t pts; int eos; } props[CV_BUFS];
    int free_[CV_BUFS], nfree; uint8_t is_free[CV_BUFS];
    int acq[CV_BUFS], nacq;                         // acquired buffers still waiting for a picture, in acquire order
    uint64_t next_seq, completed;                   // sequence numbers handed out; pictures delivered (sequences below this are complete)
    cv_pic pics[CV_PICS]; int npics;
    uint32_t last_w, last_h; int flushed;
    uint64_t st_pics, st_ns, st_max_ns; int st_maxq, st_maxp;   // timing: pictures decoded, decode time (sum, worst), deepest packet queue, most pictures waiting for a buffer
    uint8_t *sub_ev;                                // the submission-ready event: never freed, as the player holds it past the decoder's finalize
} cv_dec;
static pthread_mutex_t g_cv_mu = PTHREAD_MUTEX_INITIALIZER;
static cv_dec *g_cv_decs[CV_DECS];   // live decoders
static struct { void *ev; cv_dec *d; uint64_t seq; } g_cv_wait[CV_WAITS]; static int g_ncv_wait;
#define CVD(dec) (*(cv_dec **)(dec))
#define CVI(pool) (*(cv_img **)(pool))

static void os_clear(void *ev) { static void (*f)(void *); if (!f) f = guest_sym("_ZN2nn2os16ClearSystemEventEPNS0_15SystemEventTypeE"); f(ev); }
static void cv_wake(cv_dec *d) {   // signal the events of sequences now complete
    for (int i = 0; i < g_ncv_wait; )
        if (g_cv_wait[i].d == d && g_cv_wait[i].seq < d->completed) { hle_signal_system_event(g_cv_wait[i].ev); g_cv_wait[i] = g_cv_wait[--g_ncv_wait]; }
        else i++;
}
static void cv_fill(cv_dec *d, int idx, cv_pic *p) {   // a picture into an acquired buffer: its pool image takes the picture's storage
    cv_img *im = d->buf[idx];
    if (im) { free(im->nv12); im->nv12 = p->nv12; im->cap = (uint64_t)p->w * p->h * 3 / 2; im->w = p->w; im->h = p->h; }
    else free(p->nv12);
    d->props[idx].w = (uint16_t)p->w; d->props[idx].h = (uint16_t)p->h; d->props[idx].pts = p->pts; d->props[idx].eos = p->eos;
    d->completed++; cv_wake(d);
}
static int cv_live(const cv_dec *d) { for (int i = 0; i < CV_DECS; i++) if (d && g_cv_decs[i] == d) return 1; return 0; }
static void cv_ready(cv_dec *d) { if (d->npics + d->nq < CV_PICS_READY) hle_signal_system_event(d->sub_ev); }
static void cv_out(cv_dec *d, cv_pic p) {   // a decoded picture (or the end of the stream): to the oldest waiting buffer, else queued
    if (d->nacq) { int idx = d->acq[0]; memmove(d->acq, d->acq + 1, (size_t)--d->nacq * sizeof *d->acq); cv_fill(d, idx, &p); return; }
    if (d->npics == CV_PICS) { static int n; if (!n++) LOG("[RED] codec: %d pictures waiting for an output buffer, the oldest dropped", CV_PICS); free(d->pics[0].nv12); memmove(d->pics, d->pics + 1, (CV_PICS - 1) * sizeof *d->pics); d->npics--; }
    d->pics[d->npics++] = p;
}
// I420 to NV12, rows packed at the picture's width
static uint8_t *cv_nv12(const vpx_image_t *im) {
    uint32_t w = im->d_w, h = im->d_h, cw = (w + 1) / 2, ch = (h + 1) / 2;
    uint8_t *o = malloc((uint64_t)w * h + (uint64_t)cw * 2 * ch); if (!o) return NULL;
    for (uint32_t r = 0; r < h; r++) memcpy(o + (uint64_t)r * w, im->planes[0] + (size_t)r * im->stride[0], w);
    uint8_t *c = o + (uint64_t)w * h;
    for (uint32_t r = 0; r < ch; r++) { const uint8_t *u = im->planes[1] + (size_t)r * im->stride[1], *v = im->planes[2] + (size_t)r * im->stride[2]; for (uint32_t x = 0; x < cw; x++) { *c++ = u[x]; *c++ = v[x]; } }
    return o;
}
static int cv_pull(cv_dec *d, int64_t pts, cv_pic *out, int max) {   // the worker: decoded pictures, outside the lock
    vpx_codec_iter_t it = NULL; vpx_image_t *im; int n = 0;
    while ((im = vpx_codec_get_frame(&d->vpx, &it))) {
        if (im->fmt != VPX_IMG_FMT_I420) { static int nr; if (!nr++) LOG("[RED] codec: a picture dropped: format %#x is not 4:2:0 8-bit", im->fmt); continue; }
        uint8_t *o = cv_nv12(im); if (!o) { LOG("[RED] codec: out of memory for a picture"); continue; }
        if (n < max) out[n++] = (cv_pic){ o, im->d_w, im->d_h, pts, 0 }; else free(o);
    }
    return n;
}
static void cv_clear_q(cv_dec *d) { for (cv_pkt *k = d->qh, *x; k; k = x) { x = k->next; free(k); } d->qh = d->qt = NULL; d->nq = 0; }
static void *cv_worker(void *arg) {
    cv_dec *d = arg; cv_pic got[8];
    pthread_mutex_lock(&g_cv_mu);
    for (;;) {
        while (!d->stop && !d->qh) pthread_cond_wait(&d->cond, &g_cv_mu);
        if (d->stop) break;
        if (d->nq > d->st_maxq) d->st_maxq = d->nq;
        if (d->npics > d->st_maxp) d->st_maxp = d->npics;
        cv_pkt *k = d->qh; d->qh = k->next; if (!d->qh) d->qt = NULL; d->nq--;
        int reset = k->gen != d->gen, restart = d->flushed; d->flushed = 0;
        pthread_mutex_unlock(&g_cv_mu);
        if (restart && d->vpx_on) { vpx_codec_destroy(&d->vpx); d->vpx_on = 0; }
        int n = 0;
        if (!reset) {
            if (!d->vpx_on) {
                vpx_codec_dec_cfg_t cfg = { .threads = 4 };
                if (vpx_codec_dec_init(&d->vpx, vpx_codec_vp9_dx(), &cfg, 0)) LOG("[RED] codec: libvpx failed to start");
                else { vpx_codec_control(&d->vpx, VP9D_SET_ROW_MT, 1); d->vpx_on = 1; }
            }
            if (d->vpx_on && k->n) {
                uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
                if (vpx_codec_decode(&d->vpx, k->data, (unsigned)k->n, NULL, 0)) { if (!d->bad++) LOG("[RED] codec: decode error (%llu bytes): %s", (unsigned long long)k->n, vpx_codec_error(&d->vpx)); }
                else n = cv_pull(d, k->pts, got, 8);
                uint64_t dt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0; d->st_ns += dt; if (dt > d->st_max_ns) d->st_max_ns = dt;
                if ((d->st_pics += (uint64_t)n) && n && d->st_pics % 120 < (uint64_t)n)
                    LOG("[codec] %ux%u: %llu pictures, decode mean %.1f ms / worst %.1f ms per packet; queue up to %d packets, up to %d pictures waiting for a buffer, %d buffers acquired now",
                        d->last_w ? d->last_w : got[0].w, d->last_h ? d->last_h : got[0].h, (unsigned long long)d->st_pics, d->st_ns / 1e6 / (double)d->st_pics, d->st_max_ns / 1e6, d->st_maxq, d->st_maxp, d->nacq);
            }
            if (d->vpx_on && k->eos && !vpx_codec_decode(&d->vpx, NULL, 0, NULL, 0)) n += cv_pull(d, k->pts, got + n, 8 - n);
        }
        pthread_mutex_lock(&g_cv_mu);
        if (k->gen == d->gen) {
            for (int i = 0; i < n; i++) { d->last_w = got[i].w; d->last_h = got[i].h; cv_out(d, got[i]); }
            if (k->eos) cv_out(d, (cv_pic){ NULL, d->last_w, d->last_h, k->pts, 1 });
        } else for (int i = 0; i < n; i++) free(got[i].nv12);
        free(k);
        cv_ready(d);
    }
    pthread_mutex_unlock(&g_cv_mu);
    return NULL;
}

HLE_FORCE("_ZN2nv9InitCheckEv", "the movie player's check for the console's graphics layer: the host draws with Metal", void, h_nx2_nv_initcheck, void) {}
HLE_FORCE("_ZN2nn5codec5video10InitializeEv", "nn::codec video: the host decodes VP9 with libvpx", Result, h_nx2_cv_vinit, void) { return RES_OK; }
HLE_FORCE("_ZN2nn5codec5video8FinalizeEv", "nn::codec video", Result, h_nx2_cv_vfini, void) { return RES_OK; }

// 16-bit arguments are taken as 32-bit and cut here: Apple's arm64 convention has the caller extend them, the game's (AAPCS64) does not.
// The image preference is the game's to pass back to the pool calls: width, height, format and mode, returned through x8
typedef struct { uint16_t w, h; uint32_t fmt, mode, pad; uint8_t rest[0x10]; } cv_pref;
HLE_FORCE("_ZN2nn5codec25MakeDecodeImagePreferenceEttNS0_24VideoDecoderOutputFormatENS0_9CodecModeE", "nn::codec video", cv_pref, h_nx2_cv_pref, uint32_t w, uint32_t h, uint32_t fmt, uint32_t mode) {
    return (cv_pref){ .w = (uint16_t)w, .h = (uint16_t)h, .fmt = fmt, .mode = mode };
}
HLE_FORCE("_ZN2nn5codec3sdk34MakeDecodeImagePreferenceForCompatEttNS0_24VideoDecoderOutputFormatENS0_9CodecModeE", "nn::codec video", cv_pref, h_nx2_cv_pref_c, uint32_t w, uint32_t h, uint32_t fmt, uint32_t mode) {
    return (cv_pref){ .w = (uint16_t)w, .h = (uint16_t)h, .fmt = fmt, .mode = mode };
}
// The pools' images live on the host, so the game's buffer only has to exist
HLE_FORCE("_ZN2nn5codec31CalculateDecoderImagePoolBufferEPmS1_RKNS0_27VideoDecoderImagePreferenceEj", "nn::codec video: images kept on the host", Result, h_nx2_cv_poolsz, uint64_t *size, uint64_t *align, const cv_pref *p, uint32_t n) {
    (void)p; (void)n; *size = 0x1000; *align = 0x1000; return RES_OK;
}
HLE_FORCE("_ZN2nn5codec26InitializeDecoderImagePoolEPNS0_25VideoDecoderImagePoolTypeEPvmRKNS0_27VideoDecoderImagePreferenceEjNS0_9CodecModeE", "nn::codec video", Result, h_nx2_cv_poolinit, void *pool, void *mem, uint64_t size, const cv_pref *p, uint32_t n, uint32_t mode) {
    (void)mem; (void)size; (void)mode;
    if (n != 1) LOG("[RED] codec: an image pool of %u images (one handled)", n);
    cv_img *im = calloc(1, sizeof *im); im->w = p->w; im->h = p->h; CVI(pool) = im;
    return RES_OK;
}
HLE_FORCE("_ZN2nn5codec24FinalizeDecoderImagePoolEPNS0_25VideoDecoderImagePoolTypeE", "nn::codec video", void, h_nx2_cv_poolfini, void *pool) {
    pthread_mutex_lock(&g_cv_mu);
    cv_img *im = CVI(pool); CVI(pool) = NULL;
    for (int i = 0; im && i < CV_DECS; i++) if (g_cv_decs[i]) for (int b = 0; b < CV_BUFS; b++) if (g_cv_decs[i]->buf[b] == im) g_cv_decs[i]->buf[b] = NULL;   // a decoder that still names it lets go of it
    if (im) { free(im->nv12); free(im); }
    pthread_mutex_unlock(&g_cv_mu);
}
HLE_FORCE("_ZN2nn5codec26ReadDecoderOutputImageNv12EPKNS0_25VideoDecoderImagePoolTypeEjttttPvmmS4_mm", "nn::codec video: the picture copied out of the host's image", Result, h_nx2_cv_read,
          const void *pool, uint32_t idx, uint32_t x_, uint32_t y_, uint32_t w_, uint32_t h_, uint8_t *yb, uint64_t ys, uint64_t ysz, uint8_t *uvb, uint64_t uvs, uint64_t uvsz) {
    (void)idx; uint32_t x = x_ & 0xffff, y = y_ & 0xffff, w = w_ & 0xffff, h = h_ & 0xffff;
    { static int n; if (n++ < 6) LOG("[codec] picture read out: %ux%u at (%u,%u) → Y %p stride %llu size %#llx, UV %p stride %llu size %#llx", w, h, x, y, (void *)yb, (unsigned long long)ys, (unsigned long long)ysz, (void *)uvb, (unsigned long long)uvs, (unsigned long long)uvsz); }
    pthread_mutex_lock(&g_cv_mu);
    const cv_img *im = CVI(pool);
    // what lies outside the picture (none yet, or a smaller one than the pool's) is black
    uint32_t cw = im && im->nv12 && x < im->w ? (im->w - x < w ? im->w - x : w) : 0, uvw = im ? (im->w + 1) & ~1u : 0;
    for (uint32_t r = 0; r < h && (uint64_t)r * ys + w <= ysz; r++) {
        uint32_t n = y + r < (im ? im->h : 0) ? cw : 0;
        if (n) memcpy(yb + (uint64_t)r * ys, im->nv12 + (uint64_t)(y + r) * im->w + x, n);
        memset(yb + (uint64_t)r * ys + n, 16, w - n);
    }
    for (uint32_t r = 0; r < (h + 1u) / 2 && (uint64_t)r * uvs + w <= uvsz; r++) {
        uint32_t sr = y / 2 + r, n = sr < (im ? (im->h + 1) / 2 : 0) ? (cw + 1) & ~1u : 0;
        if (n > w) n = w;
        if (n) memcpy(uvb + (uint64_t)r * uvs, im->nv12 + (uint64_t)im->w * im->h + (uint64_t)sr * uvw + (x & ~1u), n);
        memset(uvb + (uint64_t)r * uvs + n, 128, w - n);
    }
    pthread_mutex_unlock(&g_cv_mu);
    return RES_OK;
}
HLE_FORCE("_ZN2nn5codec36GetDecoderImagePoolNativeImageHandleEPKNS0_25VideoDecoderImagePoolTypeEj", "nn::codec video: no GPU image (pictures are read as NV12)", uint32_t, h_nx2_cv_handle, const void *pool, uint32_t idx) {
    (void)pool; (void)idx; static int n; if (!n++) LOG("[RED] codec: the movie player asked for a GPU image handle, which the host does not provide"); return 0;
}

HLE_FORCE("_ZN2nn5codec29CalculateVp9DecoderWorkBufferEPmS1_mtt", "nn::codec VP9: libvpx keeps its own memory", Result, h_nx2_cv9_worksz, uint64_t *size, uint64_t *align, uint64_t in, uint32_t w, uint32_t h) {
    (void)in; (void)w; (void)h; *size = 0x1000; *align = 0x1000; return RES_OK;
}
static Result cv9_init(void *dec, uint32_t w, uint32_t h) {
    cv_dec *d = calloc(1, sizeof *d);
    d->sub_ev = aligned_alloc(16, 0x100); memset(d->sub_ev, 0, 0x100);
    hle_bind_system_event(d->sub_ev, 1);
    pthread_cond_init(&d->cond, NULL);
    pthread_mutex_lock(&g_cv_mu);
    int slot = -1; for (int i = 0; i < CV_DECS && slot < 0; i++) if (!g_cv_decs[i]) slot = i;
    if (slot < 0) { pthread_mutex_unlock(&g_cv_mu); LOG("[RED] codec: more than %d VP9 decoders at once", CV_DECS); free(d); return RES_FAIL; }
    g_cv_decs[slot] = d; CVD(dec) = d;
    pthread_mutex_unlock(&g_cv_mu);
    pthread_create(&d->thr, NULL, cv_worker, d);
    LOG("[codec] VP9 decoder %ux%u, on libvpx", w & 0xffff, h & 0xffff);
    return RES_OK;
}
HLE_FORCE("_ZN2nn5codec20InitializeVp9DecoderEPNS0_14Vp9DecoderTypeEPvmmttjNS0_23VideoDecoderInputFormatENS0_24VideoDecoderOutputFormatE", "nn::codec VP9: decoded with libvpx", Result, h_nx2_cv9_init,
          void *dec, void *work, uint64_t wsize, uint64_t in, uint32_t w, uint32_t h) { (void)work; (void)wsize; (void)in; return cv9_init(dec, w, h); }
HLE_FORCE("_ZN2nn5codec20InitializeVp9DecoderEPNS0_14Vp9DecoderTypeEmmttjNS0_23VideoDecoderInputFormatENS0_24VideoDecoderOutputFormatE", "nn::codec VP9: decoded with libvpx", Result, h_nx2_cv9_init2,
          void *dec, uint64_t a, uint64_t b, uint32_t w, uint32_t h) { (void)a; (void)b; return cv9_init(dec, w, h); }
HLE_FORCE("_ZN2nn5codec24RegisterVp9DecoderBufferEPNS0_14Vp9DecoderTypeEjPNS0_25VideoDecoderImagePoolTypeEj", "nn::codec VP9", Result, h_nx2_cv9_reg, void *dec, uint32_t idx, void *pool, uint32_t img) {
    (void)img; cv_dec *d = CVD(dec);
    if (idx >= CV_BUFS) { LOG("[RED] codec: output buffer %u (at most %d)", idx, CV_BUFS); return RES_FAIL; }
    pthread_mutex_lock(&g_cv_mu);
    d->buf[idx] = CVI(pool);
    if (!d->is_free[idx]) { d->is_free[idx] = 1; d->free_[d->nfree++] = (int)idx; }
    pthread_mutex_unlock(&g_cv_mu);
    return RES_OK;
}
HLE_FORCE("_ZN2nn5codec33GetVp9DecoderSubmissionReadyEventEPPNS_2os15SystemEventTypeEPNS0_14Vp9DecoderTypeE", "nn::codec VP9", Result, h_nx2_cv9_subev, void **out, void *dec) { *out = CVD(dec)->sub_ev; return RES_OK; }
HLE_FORCE("_ZN2nn5codec15StartVp9DecoderEPNS0_14Vp9DecoderTypeE", "nn::codec VP9", Result, h_nx2_cv9_start, void *dec) { hle_signal_system_event(CVD(dec)->sub_ev); return RES_OK; }
HLE_FORCE("_ZN2nn5codec27SubmitVp9DecoderInputBufferEPmPNS0_14Vp9DecoderTypeEPKvmNS_8TimeSpanEb", "nn::codec VP9: decoded here with libvpx", Result, h_nx2_cv9_submit,
          uint64_t *out, void *dec, const uint8_t *p, uint64_t n, int64_t pts, uint32_t eos) {
    cv_dec *d = CVD(dec); if (!p) n = 0;
    pthread_mutex_lock(&g_cv_mu);
    if (d->npics + d->nq >= CV_PICS_READY) { pthread_mutex_unlock(&g_cv_mu); if (out) *out = 0; return CV_RES_BUSY; }   // the worker signals it ready again as pictures leave
    cv_pkt *k = malloc(sizeof *k + n);
    if (!k) { pthread_mutex_unlock(&g_cv_mu); LOG("[RED] codec: out of memory for a packet"); return RES_FAIL; }
    k->next = NULL; k->n = n; k->gen = d->gen; k->pts = pts; k->eos = eos & 1; if (n) memcpy(k->data, p, n);
    if (d->qt) d->qt->next = k; else d->qh = k;
    d->qt = k; d->nq++;
    if (out) *out = n;
    pthread_cond_signal(&d->cond);
    cv_ready(d);
    pthread_mutex_unlock(&g_cv_mu);
    return RES_OK;
}
HLE_FORCE("_ZN2nn5codec29AcquireVp9DecoderOutputBufferEPjPNS_2gs16NativeSyncHandleEPNS0_14Vp9DecoderTypeE", "nn::codec VP9: the next buffer to fill, completed through its sync handle", Result, h_nx2_cv9_acq,
          uint32_t *idx, uint64_t *sync, void *dec) {
    cv_dec *d = CVD(dec);
    pthread_mutex_lock(&g_cv_mu);
    if (!d->nfree) { pthread_mutex_unlock(&g_cv_mu); LOG("[RED] codec: no free output buffer to acquire"); return RES_FAIL; }
    int b = d->free_[0]; memmove(d->free_, d->free_ + 1, (size_t)--d->nfree * sizeof *d->free_); d->is_free[b] = 0;
    *idx = (uint32_t)b; sync[0] = (uint64_t)(uintptr_t)d; sync[1] = d->next_seq++;
    if (d->npics) { cv_pic p = d->pics[0]; memmove(d->pics, d->pics + 1, (size_t)--d->npics * sizeof *d->pics); cv_fill(d, b, &p); cv_ready(d); }
    else d->acq[d->nacq++] = b;
    pthread_mutex_unlock(&g_cv_mu);
    return RES_OK;
}
HLE_FORCE("_ZN2nn5codec29ReleaseVp9DecoderOutputBufferEPNS0_14Vp9DecoderTypeEjNS_2gs16NativeSyncHandleE", "nn::codec VP9", Result, h_nx2_cv9_rel, void *dec, uint32_t idx, uint64_t s0, uint64_t s1) {
    (void)s0; (void)s1; cv_dec *d = CVD(dec);
    pthread_mutex_lock(&g_cv_mu);
    int waiting = 0; for (int i = 0; i < d->nacq; i++) waiting |= d->acq[i] == (int)idx;
    if (idx < CV_BUFS && d->buf[idx] && !d->is_free[idx] && !waiting) { d->is_free[idx] = 1; d->free_[d->nfree++] = (int)idx; }
    pthread_mutex_unlock(&g_cv_mu);
    return RES_OK;
}
HLE_FORCE("_ZN2nn5codec35GetVp9DecoderOutputBufferPropertiesEPtS1_S1_S1_PNS_5movie10ColorSpaceEPNS_8TimeSpanEPbPNS0_14Vp9DecoderTypeEj", "nn::codec VP9", Result, h_nx2_cv9_props,
          uint16_t *w, uint16_t *h, uint16_t *w2, uint16_t *h2, uint32_t *cs, int64_t *pts, uint8_t *eos, void *dec, uint32_t idx) {
    cv_dec *d = CVD(dec);
    pthread_mutex_lock(&g_cv_mu);
    if (idx < CV_BUFS) { *w = *w2 = d->props[idx].w; *h = *h2 = d->props[idx].h; *pts = d->props[idx].pts; *eos = (uint8_t)d->props[idx].eos; }
    *cs = 0;
    pthread_mutex_unlock(&g_cv_mu);
    return RES_OK;
}
HLE_FORCE("_ZN2nn5codec15FlushVp9DecoderEPNS0_14Vp9DecoderTypeE", "nn::codec VP9", Result, h_nx2_cv9_flush, void *dec) {
    cv_dec *d = CVD(dec);
    pthread_mutex_lock(&g_cv_mu);
    for (int i = 0; i < d->npics; i++) free(d->pics[i].nv12);
    d->npics = 0; cv_clear_q(d); d->gen++;
    d->flushed = 1;   // the worker restarts libvpx at its next packet
    hle_signal_system_event(d->sub_ev);
    pthread_mutex_unlock(&g_cv_mu);
    return RES_OK;
}
HLE_FORCE("_ZN2nn5codec14StopVp9DecoderEPNS0_14Vp9DecoderTypeE", "nn::codec VP9", Result, h_nx2_cv9_stop, void *dec) { (void)dec; return RES_OK; }
HLE_FORCE("_ZN2nn5codec18FinalizeVp9DecoderEPNS0_14Vp9DecoderTypeE", "nn::codec VP9", Result, h_nx2_cv9_fini, void *dec) {
    pthread_mutex_lock(&g_cv_mu);
    cv_dec *d = CVD(dec); CVD(dec) = NULL;
    if (!d) { pthread_mutex_unlock(&g_cv_mu); return RES_OK; }
    for (int i = 0; i < CV_DECS; i++) if (g_cv_decs[i] == d) g_cv_decs[i] = NULL;
    for (int i = 0; i < g_ncv_wait; ) if (g_cv_wait[i].d == d) g_cv_wait[i] = g_cv_wait[--g_ncv_wait]; else i++;
    d->stop = 1; pthread_cond_signal(&d->cond);
    pthread_mutex_unlock(&g_cv_mu);
    pthread_join(d->thr, NULL);
    for (int i = 0; i < d->npics; i++) free(d->pics[i].nv12);
    cv_clear_q(d);
    if (d->vpx_on) vpx_codec_destroy(&d->vpx);
    pthread_cond_destroy(&d->cond);
    free(d);   // its submission-ready event stays, bound: the class may still hold it, and movies are few
    return RES_OK;
}

// SyncPointEvents: SystemEvents bound to kernel events, signalled when the sequence their handle names is complete
HLE_FORCE("_ZN2nn6syncpt3sdk20CreateSyncPointEventEPNS1_18SyncPointEventTypeE", "nn::syncpt: a SystemEvent the decoder signals", Result, h_nx2_sp_create, void *ev) { hle_bind_system_event(ev, 0); return RES_OK; }
HLE_FORCE("_ZN2nn6syncpt3sdk25InitializeMultiWaitHolderEPNS_2os19MultiWaitHolderTypeEPNS1_18SyncPointEventTypeE", "nn::syncpt: the SystemEvent's holder", void, h_nx2_sp_holder, void *holder, void *ev) {
    static void (*f)(void *, void *); if (!f) f = guest_sym("_ZN2nn2os25InitializeMultiWaitHolderEPNS0_19MultiWaitHolderTypeEPNS0_15SystemEventTypeE");
    f(holder, ev);
}
HLE_FORCE("_ZN2nn6syncpt3sdk21RequestSyncPointEventEPNS1_18SyncPointEventTypeERKNS1_15SyncPointHandleE", "nn::syncpt: completed by the decoder", Result, h_nx2_sp_req, void *ev, const uint64_t *hd) {
    os_clear(ev);
    pthread_mutex_lock(&g_cv_mu);
    cv_dec *d = (cv_dec *)(uintptr_t)hd[0]; uint64_t seq = hd[1];
    for (int i = 0; i < g_ncv_wait; ) if (g_cv_wait[i].ev == ev) g_cv_wait[i] = g_cv_wait[--g_ncv_wait]; else i++;
    if (!cv_live(d) || seq < d->completed) hle_signal_system_event(ev);   // a finalized decoder's handle counts as complete
    else if (g_ncv_wait < CV_WAITS) { g_cv_wait[g_ncv_wait].ev = ev; g_cv_wait[g_ncv_wait].d = d; g_cv_wait[g_ncv_wait++].seq = seq; }
    else LOG("[RED] codec: too many sync point events waiting");
    pthread_mutex_unlock(&g_cv_mu);
    return RES_OK;
}
HLE_FORCE("_ZN2nn6syncpt3sdk21TryWaitSyncPointEventEPKNS1_18SyncPointEventTypeE", "nn::syncpt", uint32_t, h_nx2_sp_try, void *ev) {
    static uint32_t (*f)(void *); if (!f) f = guest_sym("_ZN2nn2os18TryWaitSystemEventEPNS0_15SystemEventTypeE");
    return f(ev) & 1;
}
HLE_FORCE("_ZN2nn6syncpt3sdk20CancelSyncPointEventEPNS1_18SyncPointEventTypeE", "nn::syncpt", void, h_nx2_sp_cancel, void *ev) {
    pthread_mutex_lock(&g_cv_mu);
    for (int i = 0; i < g_ncv_wait; ) if (g_cv_wait[i].ev == ev) g_cv_wait[i] = g_cv_wait[--g_ncv_wait]; else i++;
    pthread_mutex_unlock(&g_cv_mu);
    os_clear(ev);
}
HLE_FORCE("_ZN2nn6syncpt3sdk21DestroySyncPointEventEPNS1_18SyncPointEventTypeE", "nn::syncpt", void, h_nx2_sp_destroy, void *ev) {
    pthread_mutex_lock(&g_cv_mu);
    for (int i = 0; i < g_ncv_wait; ) if (g_cv_wait[i].ev == ev) g_cv_wait[i] = g_cv_wait[--g_ncv_wait]; else i++;
    pthread_mutex_unlock(&g_cv_mu);
    static void (*f)(void *); if (!f) f = guest_sym("_ZN2nn2os18DestroySystemEventEPNS0_15SystemEventTypeE");
    f(ev);
}
