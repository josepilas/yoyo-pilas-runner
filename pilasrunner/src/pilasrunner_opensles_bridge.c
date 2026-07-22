#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdint.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#include <sound/asound.h>

#include "SLES/OpenSLES.h"
#include "SLES/OpenSLES_Android.h"
#include "SLES/OpenSLES_AndroidConfiguration.h"

#ifndef ARRAY_SIZE
#define ARRAY_SIZE(x) (sizeof(x) / sizeof((x)[0]))
#endif

#define BRIDGE_OBJECT_ENGINE 1
#define BRIDGE_OBJECT_OUTPUT_MIX 2
#define BRIDGE_OBJECT_PLAYER 3

typedef struct AudioChunk {
    struct AudioChunk *next;
    uint32_t size;
    uint8_t data[];
} AudioChunk;

typedef struct BridgeObject BridgeObject;
typedef struct BridgePlayer BridgePlayer;

struct BridgeObject {
    const struct SLObjectItf_ *object_itf;
    uint32_t kind;
    uint32_t state;
};

struct BridgePlayer {
    const struct SLObjectItf_ *object_itf;
    const struct SLPlayItf_ *play_itf;
    const struct SLAndroidSimpleBufferQueueItf_ *android_queue_itf;
    const struct SLBufferQueueItf_ *buffer_queue_itf;
    const struct SLVolumeItf_ *volume_itf;
    const struct SLAndroidConfigurationItf_ *config_itf;

    uint32_t kind;
    uint32_t state;
    uint32_t play_state;
    uint32_t sample_rate;
    uint32_t channels;
    uint32_t bits_per_sample;
    uint32_t bytes_per_frame;
    uint32_t buffer_index;
    int pcm_fd;
    int pcm_ready;
    int worker_started;
    int stop_worker;

    pthread_mutex_t lock;
    pthread_cond_t cond;
    pthread_t worker;
    AudioChunk *queue_head;
    AudioChunk *queue_tail;
    uint32_t queue_count;

    slAndroidSimpleBufferQueueCallback android_callback;
    void *android_callback_context;
    slBufferQueueCallback buffer_callback;
    void *buffer_callback_context;
};

typedef struct BridgeEngine {
    const struct SLObjectItf_ *object_itf;
    const struct SLEngineItf_ *engine_itf;
    uint32_t kind;
    uint32_t state;
} BridgeEngine;

typedef struct BridgeOutputMix {
    const struct SLObjectItf_ *object_itf;
    uint32_t kind;
    uint32_t state;
} BridgeOutputMix;

static const struct SLInterfaceID_ IID_ENGINE_DATA = { 0x8d97c260, 0xddd4, 0x11db, 0x958f, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const struct SLInterfaceID_ IID_PLAY_DATA = { 0xef0bd9c0, 0xddd7, 0x11db, 0xbf49, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const struct SLInterfaceID_ IID_BUFFERQUEUE_DATA = { 0x2bc99cc0, 0xddd4, 0x11db, 0x8d99, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const struct SLInterfaceID_ IID_VOLUME_DATA = { 0x09e8ede0, 0xddde, 0x11db, 0xb4f6, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const struct SLInterfaceID_ IID_OUTPUTMIX_DATA = { 0x97750f60, 0xddd7, 0x11db, 0x92b1, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const struct SLInterfaceID_ IID_ANDROIDCONFIGURATION_DATA = { 0x89f6a7e0, 0xbeac, 0x11df, 0x8b5c, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const struct SLInterfaceID_ IID_ANDROIDSIMPLEBUFFERQUEUE_DATA = { 0x198e4940, 0xc5d7, 0x11df, 0xa2a6, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };
static const struct SLInterfaceID_ IID_OBJECT_DATA = { 0x79216360, 0xddd7, 0x11db, 0xac16, { 0x00, 0x02, 0xa5, 0xd5, 0xc5, 0x1b } };

const SLInterfaceID SL_IID_ENGINE = &IID_ENGINE_DATA;
const SLInterfaceID SL_IID_PLAY = &IID_PLAY_DATA;
const SLInterfaceID SL_IID_BUFFERQUEUE = &IID_BUFFERQUEUE_DATA;
const SLInterfaceID SL_IID_VOLUME = &IID_VOLUME_DATA;
const SLInterfaceID SL_IID_OUTPUTMIX = &IID_OUTPUTMIX_DATA;
const SLInterfaceID SL_IID_ANDROIDCONFIGURATION = &IID_ANDROIDCONFIGURATION_DATA;
const SLInterfaceID SL_IID_ANDROIDSIMPLEBUFFERQUEUE = &IID_ANDROIDSIMPLEBUFFERQUEUE_DATA;
const SLInterfaceID SL_IID_OBJECT = &IID_OBJECT_DATA;

static int iid_equal(const SLInterfaceID a, const SLInterfaceID b) {
    if (!a || !b) {
        return 0;
    }
    return memcmp(a, b, sizeof(*a)) == 0;
}

static void bridge_log(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    fprintf(stderr, "[PILAS_OPENSLES] ");
    vfprintf(stderr, fmt, args);
    fprintf(stderr, "\n");
    va_end(args);
}

static void sleep_ms(unsigned int ms) {
    struct timespec ts;
    ts.tv_sec = ms / 1000U;
    ts.tv_nsec = (long)(ms % 1000U) * 1000000L;
    while (nanosleep(&ts, &ts) != 0 && errno == EINTR) {
    }
}

static unsigned int pcm_format_from_bits(uint32_t bits) {
    switch (bits) {
        case 8:
            return SNDRV_PCM_FORMAT_U8;
        case 16:
            return SNDRV_PCM_FORMAT_S16_LE;
        case 24:
            return SNDRV_PCM_FORMAT_S24_LE;
        case 32:
            return SNDRV_PCM_FORMAT_S32_LE;
        default:
            return SNDRV_PCM_FORMAT_S16_LE;
    }
}

static void pcm_param_init(struct snd_pcm_hw_params *params) {
    memset(params, 0, sizeof(*params));
    for (int i = 0; i <= SNDRV_PCM_HW_PARAM_LAST_MASK - SNDRV_PCM_HW_PARAM_FIRST_MASK; i++) {
        memset(&params->masks[i], 0xff, sizeof(params->masks[i]));
    }
    for (int i = 0; i <= SNDRV_PCM_HW_PARAM_LAST_INTERVAL - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL; i++) {
        params->intervals[i].min = 0;
        params->intervals[i].max = UINT_MAX;
    }
}

static void pcm_param_set_mask(struct snd_pcm_hw_params *params, int param, unsigned int value) {
    struct snd_mask *mask = &params->masks[param - SNDRV_PCM_HW_PARAM_FIRST_MASK];
    memset(mask, 0, sizeof(*mask));
    mask->bits[value >> 5] |= 1U << (value & 31U);
    params->rmask |= 1U << param;
    params->cmask |= 1U << param;
}

static void pcm_param_set_int(struct snd_pcm_hw_params *params, int param, unsigned int value) {
    struct snd_interval *interval = &params->intervals[param - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL];
    memset(interval, 0, sizeof(*interval));
    interval->min = value;
    interval->max = value;
    interval->integer = 1;
    params->rmask |= 1U << param;
    params->cmask |= 1U << param;
}

static int pcm_configure_fd(int fd, BridgePlayer *player) {
    struct snd_pcm_hw_params hw;
    struct snd_pcm_sw_params sw;
    uint32_t period_frames = 1024;
    uint32_t periods = 4;
    uint32_t rate = player->sample_rate ? player->sample_rate : 48000;
    uint32_t channels = player->channels ? player->channels : 2;
    uint32_t bits = player->bits_per_sample ? player->bits_per_sample : 16;

    pcm_param_init(&hw);
    pcm_param_set_mask(&hw, SNDRV_PCM_HW_PARAM_ACCESS, SNDRV_PCM_ACCESS_RW_INTERLEAVED);
    pcm_param_set_mask(&hw, SNDRV_PCM_HW_PARAM_FORMAT, pcm_format_from_bits(bits));
    pcm_param_set_mask(&hw, SNDRV_PCM_HW_PARAM_SUBFORMAT, SNDRV_PCM_SUBFORMAT_STD);
    pcm_param_set_int(&hw, SNDRV_PCM_HW_PARAM_SAMPLE_BITS, bits);
    pcm_param_set_int(&hw, SNDRV_PCM_HW_PARAM_FRAME_BITS, bits * channels);
    pcm_param_set_int(&hw, SNDRV_PCM_HW_PARAM_CHANNELS, channels);
    pcm_param_set_int(&hw, SNDRV_PCM_HW_PARAM_RATE, rate);
    pcm_param_set_int(&hw, SNDRV_PCM_HW_PARAM_PERIOD_SIZE, period_frames);
    pcm_param_set_int(&hw, SNDRV_PCM_HW_PARAM_PERIODS, periods);
    pcm_param_set_int(&hw, SNDRV_PCM_HW_PARAM_BUFFER_SIZE, period_frames * periods);

    if (ioctl(fd, SNDRV_PCM_IOCTL_HW_PARAMS, &hw) != 0) {
        bridge_log("SNDRV_PCM_IOCTL_HW_PARAMS failed: %s", strerror(errno));
        return -1;
    }

    memset(&sw, 0, sizeof(sw));
    sw.tstamp_mode = SNDRV_PCM_TSTAMP_NONE;
    sw.period_step = 1;
    sw.avail_min = period_frames;
    sw.start_threshold = period_frames;
    sw.stop_threshold = period_frames * periods;
    sw.xfer_align = 1;

    if (ioctl(fd, SNDRV_PCM_IOCTL_SW_PARAMS, &sw) != 0) {
        bridge_log("SNDRV_PCM_IOCTL_SW_PARAMS failed: %s", strerror(errno));
        return -1;
    }

    if (ioctl(fd, SNDRV_PCM_IOCTL_PREPARE) != 0) {
        bridge_log("SNDRV_PCM_IOCTL_PREPARE failed: %s", strerror(errno));
        return -1;
    }

    return 0;
}

static int open_pcm_device(BridgePlayer *player) {
    const char *override = getenv("PILASRUNNER_ALSA_PCM");
    const char *defaults[] = {
        "/dev/snd/pcmC0D0p",
        "/dev/snd/pcmC0D1p",
        "/dev/snd/pcmC1D0p",
        "/dev/snd/pcmC1D1p",
        "/dev/snd/pcmC2D0p"
    };

    if (override && *override) {
        int fd = open(override, O_RDWR);
        if (fd >= 0 && pcm_configure_fd(fd, player) == 0) {
            bridge_log("Opened ALSA PCM device from PILASRUNNER_ALSA_PCM: %s", override);
            return fd;
        }
        if (fd >= 0) {
            close(fd);
        }
        bridge_log("Could not open configured ALSA PCM device %s: %s", override, strerror(errno));
    }

    for (size_t i = 0; i < ARRAY_SIZE(defaults); i++) {
        int fd = open(defaults[i], O_RDWR);
        if (fd < 0) {
            continue;
        }
        if (pcm_configure_fd(fd, player) == 0) {
            bridge_log("Opened ALSA PCM device: %s (%u Hz, %u channel(s), %u-bit)", defaults[i], player->sample_rate, player->channels, player->bits_per_sample);
            return fd;
        }
        close(fd);
    }

    bridge_log("No ALSA PCM playback device could be opened. Audio callbacks will continue silently.");
    return -1;
}

static void pcm_write_all(BridgePlayer *player, const uint8_t *data, uint32_t size) {
    if (player->pcm_fd < 0) {
        uint32_t frames = player->bytes_per_frame ? size / player->bytes_per_frame : 0;
        uint32_t ms = player->sample_rate ? (frames * 1000U) / player->sample_rate : 10U;
        sleep_ms(ms ? ms : 1U);
        return;
    }

    uint32_t offset = 0;
    while (offset < size) {
        uint32_t frames = (size - offset) / player->bytes_per_frame;
        if (frames == 0) {
            break;
        }

        struct snd_xferi transfer;
        memset(&transfer, 0, sizeof(transfer));
        transfer.buf = (void *)(data + offset);
        transfer.frames = frames;

        if (ioctl(player->pcm_fd, SNDRV_PCM_IOCTL_WRITEI_FRAMES, &transfer) != 0 || transfer.result < 0) {
            int err = (transfer.result < 0) ? (int)-transfer.result : errno;
            if (err == EPIPE || err == ESTRPIPE) {
                ioctl(player->pcm_fd, SNDRV_PCM_IOCTL_PREPARE);
                continue;
            }
            bridge_log("PCM write failed: %s", strerror(err));
            sleep_ms(5);
            return;
        }

        if (transfer.result == 0) {
            sleep_ms(1);
            continue;
        }

        offset += (uint32_t)transfer.result * player->bytes_per_frame;
    }
}

static void *audio_worker_main(void *opaque) {
    BridgePlayer *player = (BridgePlayer *)opaque;

    pthread_mutex_lock(&player->lock);
    while (!player->stop_worker) {
        while (!player->stop_worker &&
               (player->play_state != SL_PLAYSTATE_PLAYING || player->queue_head == NULL)) {
            pthread_cond_wait(&player->cond, &player->lock);
        }

        if (player->stop_worker) {
            break;
        }

        AudioChunk *chunk = player->queue_head;
        player->queue_head = chunk->next;
        if (!player->queue_head) {
            player->queue_tail = NULL;
        }
        if (player->queue_count > 0) {
            player->queue_count--;
        }
        pthread_mutex_unlock(&player->lock);

        if (!player->pcm_ready) {
            player->pcm_fd = open_pcm_device(player);
            player->pcm_ready = 1;
        }

        pcm_write_all(player, chunk->data, chunk->size);
        free(chunk);

        pthread_mutex_lock(&player->lock);
        player->buffer_index++;
        slAndroidSimpleBufferQueueCallback android_cb = player->android_callback;
        void *android_ctx = player->android_callback_context;
        slBufferQueueCallback buffer_cb = player->buffer_callback;
        void *buffer_ctx = player->buffer_callback_context;
        pthread_mutex_unlock(&player->lock);

        if (android_cb) {
            android_cb((SLAndroidSimpleBufferQueueItf)&player->android_queue_itf, android_ctx);
        }
        if (buffer_cb) {
            buffer_cb((SLBufferQueueItf)&player->buffer_queue_itf, buffer_ctx);
        }

        pthread_mutex_lock(&player->lock);
    }
    pthread_mutex_unlock(&player->lock);
    return NULL;
}

static SLresult generic_success_object(SLObjectItf self, SLboolean async) {
    (void)self;
    (void)async;
    return SL_RESULT_SUCCESS;
}

static SLresult object_get_state(SLObjectItf self, SLuint32 *pState) {
    if (!self || !pState) {
        return SL_RESULT_PARAMETER_INVALID;
    }
    BridgeObject *obj = (BridgeObject *)self;
    *pState = obj->state;
    return SL_RESULT_SUCCESS;
}

static void player_stop(BridgePlayer *player) {
    if (!player) {
        return;
    }
    pthread_mutex_lock(&player->lock);
    player->stop_worker = 1;
    pthread_cond_signal(&player->cond);
    pthread_mutex_unlock(&player->lock);

    if (player->worker_started) {
        pthread_join(player->worker, NULL);
        player->worker_started = 0;
    }

    if (player->pcm_fd >= 0) {
        ioctl(player->pcm_fd, SNDRV_PCM_IOCTL_DROP);
        close(player->pcm_fd);
        player->pcm_fd = -1;
    }

    AudioChunk *chunk = player->queue_head;
    while (chunk) {
        AudioChunk *next = chunk->next;
        free(chunk);
        chunk = next;
    }
    player->queue_head = NULL;
    player->queue_tail = NULL;
}

static void object_destroy(SLObjectItf self) {
    if (!self) {
        return;
    }
    BridgeObject *obj = (BridgeObject *)self;
    if (obj->kind == BRIDGE_OBJECT_PLAYER) {
        BridgePlayer *player = (BridgePlayer *)self;
        player_stop(player);
        pthread_cond_destroy(&player->cond);
        pthread_mutex_destroy(&player->lock);
    }
    free(obj);
}

static SLresult player_get_interface(BridgePlayer *player, const SLInterfaceID iid, void *pInterface) {
    if (!player || !pInterface) {
        return SL_RESULT_PARAMETER_INVALID;
    }

    if (iid_equal(iid, SL_IID_PLAY)) {
        *(SLPlayItf *)pInterface = (SLPlayItf)&player->play_itf;
        return SL_RESULT_SUCCESS;
    }
    if (iid_equal(iid, SL_IID_ANDROIDSIMPLEBUFFERQUEUE)) {
        *(SLAndroidSimpleBufferQueueItf *)pInterface = (SLAndroidSimpleBufferQueueItf)&player->android_queue_itf;
        return SL_RESULT_SUCCESS;
    }
    if (iid_equal(iid, SL_IID_BUFFERQUEUE)) {
        *(SLBufferQueueItf *)pInterface = (SLBufferQueueItf)&player->buffer_queue_itf;
        return SL_RESULT_SUCCESS;
    }
    if (iid_equal(iid, SL_IID_VOLUME)) {
        *(SLVolumeItf *)pInterface = (SLVolumeItf)&player->volume_itf;
        return SL_RESULT_SUCCESS;
    }
    if (iid_equal(iid, SL_IID_ANDROIDCONFIGURATION)) {
        *(SLAndroidConfigurationItf *)pInterface = (SLAndroidConfigurationItf)&player->config_itf;
        return SL_RESULT_SUCCESS;
    }

    return SL_RESULT_FEATURE_UNSUPPORTED;
}

static SLresult object_get_interface(SLObjectItf self, const SLInterfaceID iid, void *pInterface) {
    if (!self || !iid || !pInterface) {
        return SL_RESULT_PARAMETER_INVALID;
    }

    BridgeObject *obj = (BridgeObject *)self;
    if (iid_equal(iid, SL_IID_OBJECT)) {
        *(SLObjectItf *)pInterface = self;
        return SL_RESULT_SUCCESS;
    }

    if (obj->kind == BRIDGE_OBJECT_ENGINE && iid_equal(iid, SL_IID_ENGINE)) {
        BridgeEngine *engine = (BridgeEngine *)self;
        *(SLEngineItf *)pInterface = (SLEngineItf)&engine->engine_itf;
        return SL_RESULT_SUCCESS;
    }

    if (obj->kind == BRIDGE_OBJECT_PLAYER) {
        return player_get_interface((BridgePlayer *)self, iid, pInterface);
    }

    return SL_RESULT_FEATURE_UNSUPPORTED;
}

static SLresult object_register_callback(SLObjectItf self, slObjectCallback callback, void *pContext) {
    (void)self;
    (void)callback;
    (void)pContext;
    return SL_RESULT_SUCCESS;
}

static void object_abort_async(SLObjectItf self) {
    (void)self;
}

static SLresult object_set_priority(SLObjectItf self, SLint32 priority, SLboolean preemptable) {
    (void)self;
    (void)priority;
    (void)preemptable;
    return SL_RESULT_SUCCESS;
}

static SLresult object_get_priority(SLObjectItf self, SLint32 *pPriority, SLboolean *pPreemptable) {
    (void)self;
    if (pPriority) {
        *pPriority = 0;
    }
    if (pPreemptable) {
        *pPreemptable = SL_BOOLEAN_FALSE;
    }
    return SL_RESULT_SUCCESS;
}

static SLresult object_set_loss(SLObjectItf self, SLint16 numInterfaces, SLInterfaceID *pInterfaceIDs, SLboolean enabled) {
    (void)self;
    (void)numInterfaces;
    (void)pInterfaceIDs;
    (void)enabled;
    return SL_RESULT_SUCCESS;
}

static const struct SLObjectItf_ OBJECT_ITF = {
    .Realize = generic_success_object,
    .Resume = generic_success_object,
    .GetState = object_get_state,
    .GetInterface = object_get_interface,
    .RegisterCallback = object_register_callback,
    .AbortAsyncOperation = object_abort_async,
    .Destroy = object_destroy,
    .SetPriority = object_set_priority,
    .GetPriority = object_get_priority,
    .SetLossOfControlInterfaces = object_set_loss,
};

static BridgePlayer *player_from_play(SLPlayItf self) {
    return (BridgePlayer *)((char *)self - offsetof(BridgePlayer, play_itf));
}

static BridgePlayer *player_from_android_queue(SLAndroidSimpleBufferQueueItf self) {
    return (BridgePlayer *)((char *)self - offsetof(BridgePlayer, android_queue_itf));
}

static BridgePlayer *player_from_buffer_queue(SLBufferQueueItf self) {
    return (BridgePlayer *)((char *)self - offsetof(BridgePlayer, buffer_queue_itf));
}

static BridgePlayer *player_from_volume(SLVolumeItf self) {
    return (BridgePlayer *)((char *)self - offsetof(BridgePlayer, volume_itf));
}

static BridgePlayer *player_from_config(SLAndroidConfigurationItf self) {
    return (BridgePlayer *)((char *)self - offsetof(BridgePlayer, config_itf));
}

static SLresult play_set_state(SLPlayItf self, SLuint32 state) {
    BridgePlayer *player = player_from_play(self);
    pthread_mutex_lock(&player->lock);
    player->play_state = state;
    pthread_cond_signal(&player->cond);
    pthread_mutex_unlock(&player->lock);
    return SL_RESULT_SUCCESS;
}

static SLresult play_get_state(SLPlayItf self, SLuint32 *pState) {
    if (!pState) {
        return SL_RESULT_PARAMETER_INVALID;
    }
    BridgePlayer *player = player_from_play(self);
    pthread_mutex_lock(&player->lock);
    *pState = player->play_state;
    pthread_mutex_unlock(&player->lock);
    return SL_RESULT_SUCCESS;
}

static SLresult play_get_zero_ms(SLPlayItf self, SLmillisecond *pMsec) {
    (void)self;
    if (pMsec) {
        *pMsec = 0;
    }
    return SL_RESULT_SUCCESS;
}

static SLresult play_register_callback(SLPlayItf self, slPlayCallback callback, void *pContext) {
    (void)self;
    (void)callback;
    (void)pContext;
    return SL_RESULT_SUCCESS;
}

static SLresult play_set_event_mask(SLPlayItf self, SLuint32 eventFlags) {
    (void)self;
    (void)eventFlags;
    return SL_RESULT_SUCCESS;
}

static SLresult play_get_event_mask(SLPlayItf self, SLuint32 *pEventFlags) {
    (void)self;
    if (pEventFlags) {
        *pEventFlags = 0;
    }
    return SL_RESULT_SUCCESS;
}

static SLresult play_set_ms(SLPlayItf self, SLmillisecond mSec) {
    (void)self;
    (void)mSec;
    return SL_RESULT_SUCCESS;
}

static SLresult play_clear_marker(SLPlayItf self) {
    (void)self;
    return SL_RESULT_SUCCESS;
}

static const struct SLPlayItf_ PLAY_ITF = {
    .SetPlayState = play_set_state,
    .GetPlayState = play_get_state,
    .GetDuration = play_get_zero_ms,
    .GetPosition = play_get_zero_ms,
    .RegisterCallback = play_register_callback,
    .SetCallbackEventsMask = play_set_event_mask,
    .GetCallbackEventsMask = play_get_event_mask,
    .SetMarkerPosition = play_set_ms,
    .ClearMarkerPosition = play_clear_marker,
    .GetMarkerPosition = play_get_zero_ms,
    .SetPositionUpdatePeriod = play_set_ms,
    .GetPositionUpdatePeriod = play_get_zero_ms,
};

static SLresult android_queue_enqueue(SLAndroidSimpleBufferQueueItf self, const void *pBuffer, SLuint32 size) {
    BridgePlayer *player = player_from_android_queue(self);
    if (!pBuffer || size == 0) {
        return SL_RESULT_PARAMETER_INVALID;
    }

    AudioChunk *chunk = (AudioChunk *)malloc(sizeof(*chunk) + size);
    if (!chunk) {
        return SL_RESULT_MEMORY_FAILURE;
    }
    chunk->next = NULL;
    chunk->size = size;
    memcpy(chunk->data, pBuffer, size);

    pthread_mutex_lock(&player->lock);
    if (player->queue_tail) {
        player->queue_tail->next = chunk;
    } else {
        player->queue_head = chunk;
    }
    player->queue_tail = chunk;
    player->queue_count++;
    pthread_cond_signal(&player->cond);
    pthread_mutex_unlock(&player->lock);

    return SL_RESULT_SUCCESS;
}

static SLresult android_queue_clear(SLAndroidSimpleBufferQueueItf self) {
    BridgePlayer *player = player_from_android_queue(self);
    pthread_mutex_lock(&player->lock);
    AudioChunk *chunk = player->queue_head;
    player->queue_head = NULL;
    player->queue_tail = NULL;
    player->queue_count = 0;
    pthread_mutex_unlock(&player->lock);

    while (chunk) {
        AudioChunk *next = chunk->next;
        free(chunk);
        chunk = next;
    }
    if (player->pcm_fd >= 0) {
        ioctl(player->pcm_fd, SNDRV_PCM_IOCTL_DROP);
        ioctl(player->pcm_fd, SNDRV_PCM_IOCTL_PREPARE);
    }
    return SL_RESULT_SUCCESS;
}

static SLresult android_queue_get_state(SLAndroidSimpleBufferQueueItf self, SLAndroidSimpleBufferQueueState *pState) {
    if (!pState) {
        return SL_RESULT_PARAMETER_INVALID;
    }
    BridgePlayer *player = player_from_android_queue(self);
    pthread_mutex_lock(&player->lock);
    pState->count = player->queue_count;
    pState->index = player->buffer_index;
    pthread_mutex_unlock(&player->lock);
    return SL_RESULT_SUCCESS;
}

static SLresult android_queue_register_callback(SLAndroidSimpleBufferQueueItf self, slAndroidSimpleBufferQueueCallback callback, void *pContext) {
    BridgePlayer *player = player_from_android_queue(self);
    pthread_mutex_lock(&player->lock);
    player->android_callback = callback;
    player->android_callback_context = pContext;
    pthread_mutex_unlock(&player->lock);
    return SL_RESULT_SUCCESS;
}

static const struct SLAndroidSimpleBufferQueueItf_ ANDROID_QUEUE_ITF = {
    .Enqueue = android_queue_enqueue,
    .Clear = android_queue_clear,
    .GetState = android_queue_get_state,
    .RegisterCallback = android_queue_register_callback,
};

static SLresult buffer_queue_enqueue(SLBufferQueueItf self, const void *pBuffer, SLuint32 size) {
    BridgePlayer *player = player_from_buffer_queue(self);
    return android_queue_enqueue((SLAndroidSimpleBufferQueueItf)&player->android_queue_itf, pBuffer, size);
}

static SLresult buffer_queue_clear(SLBufferQueueItf self) {
    BridgePlayer *player = player_from_buffer_queue(self);
    return android_queue_clear((SLAndroidSimpleBufferQueueItf)&player->android_queue_itf);
}

static SLresult buffer_queue_get_state(SLBufferQueueItf self, SLBufferQueueState *pState) {
    if (!pState) {
        return SL_RESULT_PARAMETER_INVALID;
    }
    BridgePlayer *player = player_from_buffer_queue(self);
    pthread_mutex_lock(&player->lock);
    pState->count = player->queue_count;
    pState->playIndex = player->buffer_index;
    pthread_mutex_unlock(&player->lock);
    return SL_RESULT_SUCCESS;
}

static SLresult buffer_queue_register_callback(SLBufferQueueItf self, slBufferQueueCallback callback, void *pContext) {
    BridgePlayer *player = player_from_buffer_queue(self);
    pthread_mutex_lock(&player->lock);
    player->buffer_callback = callback;
    player->buffer_callback_context = pContext;
    pthread_mutex_unlock(&player->lock);
    return SL_RESULT_SUCCESS;
}

static const struct SLBufferQueueItf_ BUFFER_QUEUE_ITF = {
    .Enqueue = buffer_queue_enqueue,
    .Clear = buffer_queue_clear,
    .GetState = buffer_queue_get_state,
    .RegisterCallback = buffer_queue_register_callback,
};

static SLresult volume_set_level(SLVolumeItf self, SLmillibel level) {
    (void)self;
    (void)level;
    return SL_RESULT_SUCCESS;
}

static SLresult volume_get_level(SLVolumeItf self, SLmillibel *pLevel) {
    (void)self;
    if (pLevel) {
        *pLevel = 0;
    }
    return SL_RESULT_SUCCESS;
}

static SLresult volume_get_max(SLVolumeItf self, SLmillibel *pMaxLevel) {
    (void)self;
    if (pMaxLevel) {
        *pMaxLevel = 0;
    }
    return SL_RESULT_SUCCESS;
}

static SLresult volume_set_mute(SLVolumeItf self, SLboolean mute) {
    (void)self;
    (void)mute;
    return SL_RESULT_SUCCESS;
}

static SLresult volume_get_mute(SLVolumeItf self, SLboolean *pMute) {
    (void)self;
    if (pMute) {
        *pMute = SL_BOOLEAN_FALSE;
    }
    return SL_RESULT_SUCCESS;
}

static SLresult volume_set_stereo_enable(SLVolumeItf self, SLboolean enable) {
    (void)self;
    (void)enable;
    return SL_RESULT_SUCCESS;
}

static SLresult volume_get_stereo_enable(SLVolumeItf self, SLboolean *pEnable) {
    (void)self;
    if (pEnable) {
        *pEnable = SL_BOOLEAN_FALSE;
    }
    return SL_RESULT_SUCCESS;
}

static SLresult volume_set_stereo(SLVolumeItf self, SLpermille stereoPosition) {
    (void)self;
    (void)stereoPosition;
    return SL_RESULT_SUCCESS;
}

static SLresult volume_get_stereo(SLVolumeItf self, SLpermille *pStereoPosition) {
    (void)self;
    if (pStereoPosition) {
        *pStereoPosition = 0;
    }
    return SL_RESULT_SUCCESS;
}

static const struct SLVolumeItf_ VOLUME_ITF = {
    .SetVolumeLevel = volume_set_level,
    .GetVolumeLevel = volume_get_level,
    .GetMaxVolumeLevel = volume_get_max,
    .SetMute = volume_set_mute,
    .GetMute = volume_get_mute,
    .EnableStereoPosition = volume_set_stereo_enable,
    .IsEnabledStereoPosition = volume_get_stereo_enable,
    .SetStereoPosition = volume_set_stereo,
    .GetStereoPosition = volume_get_stereo,
};

static SLresult config_set(SLAndroidConfigurationItf self, const SLchar *configKey, const void *pConfigValue, SLuint32 valueSize) {
    (void)player_from_config(self);
    (void)configKey;
    (void)pConfigValue;
    (void)valueSize;
    return SL_RESULT_SUCCESS;
}

static SLresult config_get(SLAndroidConfigurationItf self, const SLchar *configKey, SLuint32 *pValueSize, void *pConfigValue) {
    (void)player_from_config(self);
    (void)configKey;
    (void)pConfigValue;
    if (pValueSize) {
        *pValueSize = 0;
    }
    return SL_RESULT_SUCCESS;
}

static const struct SLAndroidConfigurationItf_ CONFIG_ITF = {
    .SetConfiguration = config_set,
    .GetConfiguration = config_get,
};

static SLresult engine_create_output_mix(SLEngineItf self, SLObjectItf *pMix, SLuint32 numInterfaces, const SLInterfaceID *pInterfaceIds, const SLboolean *pInterfaceRequired) {
    (void)self;
    (void)numInterfaces;
    (void)pInterfaceIds;
    (void)pInterfaceRequired;
    if (!pMix) {
        return SL_RESULT_PARAMETER_INVALID;
    }

    BridgeOutputMix *mix = (BridgeOutputMix *)calloc(1, sizeof(*mix));
    if (!mix) {
        return SL_RESULT_MEMORY_FAILURE;
    }
    mix->object_itf = &OBJECT_ITF;
    mix->kind = BRIDGE_OBJECT_OUTPUT_MIX;
    mix->state = SL_OBJECT_STATE_REALIZED;
    *pMix = (SLObjectItf)&mix->object_itf;
    return SL_RESULT_SUCCESS;
}

static void parse_player_format(BridgePlayer *player, SLDataSource *source) {
    player->sample_rate = 48000;
    player->channels = 2;
    player->bits_per_sample = 16;

    if (source && source->pFormat) {
        SLDataFormat_PCM *pcm = (SLDataFormat_PCM *)source->pFormat;
        if (pcm->formatType == SL_DATAFORMAT_PCM) {
            player->channels = pcm->numChannels ? pcm->numChannels : 2;
            player->bits_per_sample = pcm->bitsPerSample ? pcm->bitsPerSample : 16;
            if (pcm->samplesPerSec) {
                player->sample_rate = pcm->samplesPerSec >= 1000 ? pcm->samplesPerSec / 1000 : pcm->samplesPerSec;
            }
        }
    }

    if (player->channels == 0 || player->channels > 8) {
        player->channels = 2;
    }
    if (player->bits_per_sample != 8 && player->bits_per_sample != 16 && player->bits_per_sample != 24 && player->bits_per_sample != 32) {
        player->bits_per_sample = 16;
    }
    player->bytes_per_frame = (player->bits_per_sample / 8) * player->channels;
    if (!player->bytes_per_frame) {
        player->bytes_per_frame = 4;
    }
}

static SLresult engine_create_audio_player(SLEngineItf self, SLObjectItf *pPlayer, SLDataSource *pAudioSrc, SLDataSink *pAudioSnk, SLuint32 numInterfaces, const SLInterfaceID *pInterfaceIds, const SLboolean *pInterfaceRequired) {
    (void)self;
    (void)pAudioSnk;
    (void)numInterfaces;
    (void)pInterfaceIds;
    (void)pInterfaceRequired;
    if (!pPlayer) {
        return SL_RESULT_PARAMETER_INVALID;
    }

    BridgePlayer *player = (BridgePlayer *)calloc(1, sizeof(*player));
    if (!player) {
        return SL_RESULT_MEMORY_FAILURE;
    }

    player->object_itf = &OBJECT_ITF;
    player->play_itf = &PLAY_ITF;
    player->android_queue_itf = &ANDROID_QUEUE_ITF;
    player->buffer_queue_itf = &BUFFER_QUEUE_ITF;
    player->volume_itf = &VOLUME_ITF;
    player->config_itf = &CONFIG_ITF;
    player->kind = BRIDGE_OBJECT_PLAYER;
    player->state = SL_OBJECT_STATE_REALIZED;
    player->play_state = SL_PLAYSTATE_STOPPED;
    player->pcm_fd = -1;
    parse_player_format(player, pAudioSrc);
    pthread_mutex_init(&player->lock, NULL);
    pthread_cond_init(&player->cond, NULL);

    if (pthread_create(&player->worker, NULL, audio_worker_main, player) == 0) {
        player->worker_started = 1;
    } else {
        bridge_log("pthread_create failed; audio will be callback-only.");
    }

    bridge_log("Created audio player (%u Hz, %u channel(s), %u-bit)", player->sample_rate, player->channels, player->bits_per_sample);
    *pPlayer = (SLObjectItf)&player->object_itf;
    return SL_RESULT_SUCCESS;
}

static SLresult unsupported_engine_call(void) {
    return SL_RESULT_FEATURE_UNSUPPORTED;
}

static const struct SLEngineItf_ ENGINE_ITF = {
    .CreateLEDDevice = (void *)unsupported_engine_call,
    .CreateVibraDevice = (void *)unsupported_engine_call,
    .CreateAudioPlayer = engine_create_audio_player,
    .CreateAudioRecorder = (void *)unsupported_engine_call,
    .CreateMidiPlayer = (void *)unsupported_engine_call,
    .CreateListener = (void *)unsupported_engine_call,
    .Create3DGroup = (void *)unsupported_engine_call,
    .CreateOutputMix = engine_create_output_mix,
};

SLresult SLAPIENTRY slCreateEngine(SLObjectItf *pEngine, SLuint32 numOptions, const SLEngineOption *pEngineOptions, SLuint32 numInterfaces, const SLInterfaceID *pInterfaceIds, const SLboolean *pInterfaceRequired) {
    (void)numOptions;
    (void)pEngineOptions;
    (void)numInterfaces;
    (void)pInterfaceIds;
    (void)pInterfaceRequired;
    if (!pEngine) {
        return SL_RESULT_PARAMETER_INVALID;
    }

    BridgeEngine *engine = (BridgeEngine *)calloc(1, sizeof(*engine));
    if (!engine) {
        return SL_RESULT_MEMORY_FAILURE;
    }

    engine->object_itf = &OBJECT_ITF;
    engine->engine_itf = &ENGINE_ITF;
    engine->kind = BRIDGE_OBJECT_ENGINE;
    engine->state = SL_OBJECT_STATE_REALIZED;
    *pEngine = (SLObjectItf)&engine->object_itf;
    bridge_log("slCreateEngine succeeded.");
    return SL_RESULT_SUCCESS;
}

SLresult SLAPIENTRY slQueryNumSupportedEngineInterfaces(SLuint32 *pNumSupportedInterfaces) {
    if (pNumSupportedInterfaces) {
        *pNumSupportedInterfaces = 1;
    }
    return SL_RESULT_SUCCESS;
}

SLresult SLAPIENTRY slQuerySupportedEngineInterfaces(SLuint32 index, SLInterfaceID *pInterfaceId) {
    if (index != 0 || !pInterfaceId) {
        return SL_RESULT_PARAMETER_INVALID;
    }
    *pInterfaceId = SL_IID_ENGINE;
    return SL_RESULT_SUCCESS;
}
