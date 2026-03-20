/**
 * soluna_shm.h — POSIX Shared Memory ring buffer for Soluna virtual audio
 *
 * Used by both the CoreAudio plugin (SolunaPlugin.mm) and the daemon (solunad).
 * C-compatible header: works with ObjC++, C++17, and plain C.
 *
 * Layout:
 *   /soluna_audio  (SOLUNA_SHM_BYTES total)
 *   ┌────────────────────────────────────┐
 *   │ SolunaShmHeader (64 bytes)         │
 *   ├────────────────────────────────────┤
 *   │ float samples[SOLUNA_SHM_CAPACITY  │
 *   │              * SOLUNA_SHM_CHANNELS]│
 *   └────────────────────────────────────┘
 *
 * SPDX-License-Identifier: MIT
 */

#pragma once

#ifdef __cplusplus
#include <cstdint>
#include <cstring>
#else
#include <stdint.h>
#include <string.h>
#endif

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

/* ── Constants ────────────────────────────────────────────────────────────── */

/* We use a file in /private/var/db/soluna/ as shared memory backing.
 * This path is writable for the CoreAudio driver sandbox
 * (sandbox profile explicitly allows file-read* file-write* on /private/var/db)
 * AND is accessible to solunad (running as the login user).
 * The directory must be created with 0777 by install.sh:
 *   sudo mkdir -p /private/var/db/soluna && sudo chmod 0777 /private/var/db/soluna */
#define SOLUNA_SHM_PATH   "/private/var/db/soluna/soluna_audio.shm"
#define SOLUNA_SHM_MAGIC      0x534F4C55u  /* "SOLU" */
#define SOLUNA_SHM_VERSION    1u

#define SOLUNA_SHM_CHANNELS   2u
#define SOLUNA_SHM_CAPACITY   16384u       /* frames (~341ms @ 48kHz) */
#define SOLUNA_SHM_SAMPLE_RATE 48000u

/* Total bytes = header + ring samples */
#define SOLUNA_SHM_RING_SAMPLES  (SOLUNA_SHM_CAPACITY * SOLUNA_SHM_CHANNELS)
#define SOLUNA_SHM_BYTES  (sizeof(SolunaShmHeader) + SOLUNA_SHM_RING_SAMPLES * sizeof(float))

/* ── Header ───────────────────────────────────────────────────────────────── */

typedef struct SolunaShmHeader {
    uint32_t magic;               /* SOLUNA_SHM_MAGIC                  */
    uint32_t version;             /* SOLUNA_SHM_VERSION                */
    uint32_t capacity;            /* frames in ring                    */
    uint32_t channels;            /* interleaved channel count         */
    uint32_t sample_rate;         /* samples per second                */
    uint32_t _pad0;               /* pad to 8-byte boundary for u64    */
    /* offsets 24/32 → naturally 8-byte aligned, no packing needed */
    volatile uint64_t write_pos;  /* monotonic frame counter (writer)  */
    volatile uint64_t read_pos;   /* monotonic frame counter (reader)  */
    uint8_t  _pad1[24];           /* pad to 64 bytes total             */
} SolunaShmHeader;

/* compile-time size check */
typedef char _soluna_shm_header_size_check[sizeof(SolunaShmHeader) == 64 ? 1 : -1];

/* ── Full mapping ─────────────────────────────────────────────────────────── */

typedef struct SolunaShmMap {
    SolunaShmHeader* hdr;
    float*           ring;   /* points past hdr, SOLUNA_SHM_RING_SAMPLES floats */
} SolunaShmMap;

/* ── Inline helpers ───────────────────────────────────────────────────────── */

#ifdef __cplusplus
extern "C" {
#endif

/** Returns the backing-file path. */
static inline const char* soluna_shm_path(void)
{
    return SOLUNA_SHM_PATH;
}

/**
 * Open (or create) the SHM backing file and mmap it.
 * flags: O_RDWR | O_CREAT  — solunad (daemon, no sandbox) creates
 *        O_RDWR             — driver plugin opens existing file
 * Returns 0 on success, -1 on error.
 */
static inline int soluna_shm_open(SolunaShmMap* m, int flags)
{
    /* Use open() on a $TMPDIR file — shm_open is blocked by the CoreAudio
     * driver sandbox (Core-Audio-Driver-Service.helper denies ipc-posix-shm*
     * but allows file-read* / write* on TMPDIR). */
    int fd = open(soluna_shm_path(), flags, 0666);
    if (fd < 0) return -1;

    if (flags & O_CREAT) {
        /* Force 0666 regardless of umask so the driver process can open it */
        fchmod(fd, 0666);
        if (ftruncate(fd, (off_t)SOLUNA_SHM_BYTES) < 0) {
            close(fd);
            return -1;
        }
    }

    void* ptr = mmap(NULL, SOLUNA_SHM_BYTES,
                     PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (ptr == MAP_FAILED) return -1;

    m->hdr  = (SolunaShmHeader*)ptr;
    m->ring = (float*)((uint8_t*)ptr + sizeof(SolunaShmHeader));
    return 0;
}

/** Unmap the SHM segment. */
static inline void soluna_shm_close(SolunaShmMap* m)
{
    if (m->hdr) {
        munmap(m->hdr, SOLUNA_SHM_BYTES);
        m->hdr  = (SolunaShmHeader*)0;
        m->ring = (float*)0;
    }
}

/** Remove the backing file from the filesystem. */
static inline void soluna_shm_unlink(void)
{
    unlink(soluna_shm_path());
}

/** Initialise header fields (plugin calls this after O_CREAT). */
static inline void soluna_shm_init_header(SolunaShmMap* m)
{
    SolunaShmHeader* h = m->hdr;
    memset(h, 0, sizeof(*h));
    h->magic       = SOLUNA_SHM_MAGIC;
    h->version     = SOLUNA_SHM_VERSION;
    h->capacity    = SOLUNA_SHM_CAPACITY;
    h->channels    = SOLUNA_SHM_CHANNELS;
    h->sample_rate = SOLUNA_SHM_SAMPLE_RATE;
    /* write_pos / read_pos already 0 from memset */
}

/** Validate that the header looks sane (daemon calls this after open). */
static inline int soluna_shm_validate(const SolunaShmMap* m)
{
    const SolunaShmHeader* h = m->hdr;
    return (h->magic    == SOLUNA_SHM_MAGIC   &&
            h->version  == SOLUNA_SHM_VERSION  &&
            h->capacity == SOLUNA_SHM_CAPACITY &&
            h->channels == SOLUNA_SHM_CHANNELS) ? 0 : -1;
}

/** How many frames are available to read. */
static inline uint64_t soluna_shm_available_read(const SolunaShmMap* m)
{
    uint64_t wp = __atomic_load_n(&m->hdr->write_pos, __ATOMIC_ACQUIRE);
    uint64_t rp = __atomic_load_n(&m->hdr->read_pos,  __ATOMIC_RELAXED);
    return (wp >= rp) ? (wp - rp) : 0;
}

/**
 * Write `frames` interleaved float frames into the ring.
 * Overwrites oldest data on overflow (plugin is real-time — never blocks).
 */
static inline void soluna_shm_write(SolunaShmMap* m,
                                    const float*  src,
                                    uint32_t      frames)
{
    uint64_t wp  = __atomic_load_n(&m->hdr->write_pos, __ATOMIC_RELAXED);
    uint32_t cap = m->hdr->capacity;
    uint32_t ch  = m->hdr->channels;

    for (uint32_t f = 0; f < frames; f++) {
        uint32_t slot = (uint32_t)((wp + f) % cap);
        const float* s = src + f * ch;
        float*       d = m->ring + slot * ch;
        for (uint32_t c = 0; c < ch; c++) d[c] = s[c];
    }
    __atomic_store_n(&m->hdr->write_pos, wp + frames, __ATOMIC_RELEASE);
}

/**
 * Read up to `frames` interleaved float frames from the ring.
 * Returns the number of frames actually read.
 */
static inline uint32_t soluna_shm_read(SolunaShmMap* m,
                                       float*        dst,
                                       uint32_t      frames)
{
    uint64_t wp   = __atomic_load_n(&m->hdr->write_pos, __ATOMIC_ACQUIRE);
    uint64_t rp   = __atomic_load_n(&m->hdr->read_pos,  __ATOMIC_RELAXED);
    uint64_t avail = (wp >= rp) ? (wp - rp) : 0;
    if (avail < frames) frames = (uint32_t)avail;
    if (frames == 0) return 0;

    uint32_t cap = m->hdr->capacity;
    uint32_t ch  = m->hdr->channels;

    for (uint32_t f = 0; f < frames; f++) {
        uint32_t slot = (uint32_t)((rp + f) % cap);
        const float* s = m->ring + slot * ch;
        float*       d = dst + f * ch;
        for (uint32_t c = 0; c < ch; c++) d[c] = s[c];
    }
    __atomic_store_n(&m->hdr->read_pos, rp + frames, __ATOMIC_RELEASE);
    return frames;
}

#ifdef __cplusplus
} /* extern "C" */
#endif
