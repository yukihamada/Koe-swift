/**
 * IMA-ADPCM Encoder/Decoder — OSTP §4.9 Raw First Strategy
 * 4:1 compression ratio, zero-latency decode, valprev seeding from raw PCM.
 * SPDX-License-Identifier: MIT
 */
#pragma once
#include <cstdint>
#include <cstddef>
#include <vector>

namespace soluna { namespace codec {

// IMA step size table (89 entries)
static const int16_t kImaStepTable[89] = {
    7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,
    50,55,60,66,73,80,88,97,107,118,130,143,157,173,190,209,230,
    253,279,307,337,371,408,449,494,544,598,658,724,796,876,963,
    1060,1166,1282,1411,1552,1707,1878,2066,2272,2499,2749,3024,
    3327,3660,4026,4428,4871,5358,5894,6484,7132,7845,8630,9493,
    10442,11487,12635,13899,15289,16818,18500,20350,22385,24623,
    27086,29794,32767
};

// IMA index adjustment table
static const int8_t kImaIndexTable[16] = {
    -1,-1,-1,-1, 2, 4, 6, 8,
    -1,-1,-1,-1, 2, 4, 6, 8
};

struct AdpcmState {
    int32_t valprev = 0;   // Previous output value
    int32_t index   = 0;   // Step size index
};

/**
 * Encode one 16-bit sample to 4-bit ADPCM nibble.
 */
inline uint8_t adpcm_encode_sample(int16_t sample, AdpcmState& state) {
    int step = kImaStepTable[state.index];
    int diff = sample - state.valprev;
    uint8_t nibble = 0;
    if (diff < 0) { nibble = 8; diff = -diff; }
    if (diff >= step) { nibble |= 4; diff -= step; }
    if (diff >= (step >> 1)) { nibble |= 2; diff -= (step >> 1); }
    if (diff >= (step >> 2)) { nibble |= 1; }

    // Update predictor
    int predsample = state.valprev;
    step = kImaStepTable[state.index];
    int diffq = step >> 3;
    if (nibble & 4) diffq += step;
    if (nibble & 2) diffq += (step >> 1);
    if (nibble & 1) diffq += (step >> 2);
    if (nibble & 8) predsample -= diffq; else predsample += diffq;
    if (predsample > 32767) predsample = 32767;
    if (predsample < -32768) predsample = -32768;
    state.valprev = predsample;

    // Update index
    state.index += kImaIndexTable[nibble];
    if (state.index < 0) state.index = 0;
    if (state.index > 88) state.index = 88;

    return nibble;
}

/**
 * Decode one 4-bit ADPCM nibble to 16-bit sample.
 */
inline int16_t adpcm_decode_sample(uint8_t nibble, AdpcmState& state) {
    int step = kImaStepTable[state.index];
    int diffq = step >> 3;
    if (nibble & 4) diffq += step;
    if (nibble & 2) diffq += (step >> 1);
    if (nibble & 1) diffq += (step >> 2);
    if (nibble & 8) state.valprev -= diffq; else state.valprev += diffq;
    if (state.valprev > 32767) state.valprev = 32767;
    if (state.valprev < -32768) state.valprev = -32768;

    state.index += kImaIndexTable[nibble];
    if (state.index < 0) state.index = 0;
    if (state.index > 88) state.index = 88;

    return static_cast<int16_t>(state.valprev);
}

/**
 * Encode a block of 16-bit PCM samples to IMA-ADPCM.
 * Output: 4 bytes header (valprev:16, index:8, reserved:8) + packed nibbles.
 * Returns encoded data.
 */
inline std::vector<uint8_t> adpcm_encode(const int16_t* pcm, size_t num_samples, AdpcmState& state) {
    // Header: 4 bytes (valprev + index)
    size_t out_size = 4 + (num_samples + 1) / 2;
    std::vector<uint8_t> out(out_size);

    // Write header
    out[0] = static_cast<uint8_t>(state.valprev & 0xFF);
    out[1] = static_cast<uint8_t>((state.valprev >> 8) & 0xFF);
    out[2] = static_cast<uint8_t>(state.index);
    out[3] = 0; // reserved

    // Encode samples, 2 nibbles per byte
    for (size_t i = 0; i < num_samples; i++) {
        uint8_t nibble = adpcm_encode_sample(pcm[i], state);
        if (i & 1) {
            out[4 + i/2] |= (nibble << 4);
        } else {
            out[4 + i/2] = nibble;
        }
    }
    return out;
}

/**
 * Decode IMA-ADPCM block to 16-bit PCM.
 * Input: 4 bytes header + packed nibbles.
 */
inline std::vector<int16_t> adpcm_decode(const uint8_t* data, size_t data_size, AdpcmState& state) {
    if (data_size < 4) return {};

    // Read header (but only use if state hasn't been seeded by Raw First)
    if (state.valprev == 0 && state.index == 0) {
        state.valprev = static_cast<int16_t>(data[0] | (data[1] << 8));
        state.index = data[2];
    }

    size_t num_samples = (data_size - 4) * 2;
    std::vector<int16_t> pcm(num_samples);

    for (size_t i = 0; i < num_samples; i++) {
        uint8_t nibble;
        if (i & 1) {
            nibble = (data[4 + i/2] >> 4) & 0x0F;
        } else {
            nibble = data[4 + i/2] & 0x0F;
        }
        pcm[i] = adpcm_decode_sample(nibble, state);
    }
    return pcm;
}

/**
 * Seed ADPCM state from raw PCM (Raw First strategy §4.9).
 * Call this with the last sample of the initial raw PCM packet.
 */
inline void adpcm_seed_from_raw(AdpcmState& state, int16_t last_raw_sample) {
    state.valprev = last_raw_sample;
    state.index = 0;
}

}} // namespace soluna::codec
