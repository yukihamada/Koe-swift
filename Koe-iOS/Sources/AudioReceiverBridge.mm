//
//  AudioReceiverBridge.mm
//  SolunaReceiver
//
//  Objective-C++ bridge for C++ RTP receiver and CoreAudio output
//

#import "AudioReceiverBridge.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreMotion/CMHeadphoneMotionManager.h>

#include "web_embedded.h"
#include <soluna/soluna.h>
#include <soluna/pal/audio.h>
#include <soluna/pal/net.h>
#include <soluna/transport/rtp.h>
#include <soluna/transport/ostp.h>
#include <soluna/pipeline/ring_buffer.h>
#include <soluna/pipeline/pipeline.h>
#include <soluna/transport/packet_scheduler.h>
#include <soluna/control/websocket_server.h>

#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <thread>
#include <memory>
#include <mutex>
#include <functional>
#include <cstring>
#include <cstdio>
#include <cmath>
#include <vector>
#include <string>
#include <set>
#include <map>

#ifdef _WIN32
#include <winsock2.h>
#else
#include <arpa/inet.h>
#include <sys/socket.h>
#include <netdb.h>
#include <unistd.h>
#include <ifaddrs.h>
#include <net/if.h>
#endif

using namespace soluna;

// ============================================================================
// Internal C++ Implementation
// ============================================================================

namespace {

/// Receive mode for RTP reception
enum class ReceiveMode {
    OSTP,
    AES67,
    Auto
};

/// RTP payload types (AES67 standard)
constexpr uint8_t kPayloadTypeL24_AES67 = 10;  // AES67 24-bit
constexpr uint8_t kPayloadTypeL16_AES67 = 11;  // AES67 16-bit
constexpr uint8_t kPayloadTypeL24 = 98;  // OSTP default
constexpr uint8_t kPayloadTypeL16 = 11;

/// Check if RTP packet is AES67 standard (no OSTP extension)
inline bool aes67_is_standard_packet(const transport::RtpHeader& hdr) {
    // AES67 uses PT 10 (L24) or PT 11 (L16) and no extension header
    return (hdr.pt == kPayloadTypeL24_AES67 || hdr.pt == kPayloadTypeL16_AES67) && hdr.extension == 0;
}

// ============================================================================
// Biquad Filter Primitives (for EQ)
// ============================================================================

struct BiquadCoeffs {
    float b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
};

struct BiquadState {
    float x1 = 0, x2 = 0, y1 = 0, y2 = 0;
};

/// Compute peaking EQ filter coefficients
inline BiquadCoeffs peaking_eq(float freq_hz, float gain_db, float q, float sample_rate = 48000.0f) {
    if (std::fabs(gain_db) < 0.01f) return {}; // bypass
    float A = std::pow(10.0f, gain_db / 40.0f);
    float w0 = 2.0f * M_PI * freq_hz / sample_rate;
    float alpha = std::sin(w0) / (2.0f * q);
    float a0 = 1.0f + alpha / A;
    BiquadCoeffs c;
    c.b0 = (1.0f + alpha * A) / a0;
    c.b1 = (-2.0f * std::cos(w0)) / a0;
    c.b2 = (1.0f - alpha * A) / a0;
    c.a1 = c.b1;  // same as -2*cos(w0)/a0
    c.a2 = (1.0f - alpha / A) / a0;
    return c;
}

/// Apply biquad filter to a single sample
inline float biquad_process(const BiquadCoeffs& c, BiquadState& s, float x) {
    float y = c.b0 * x + c.b1 * s.x1 + c.b2 * s.x2 - c.a1 * s.y1 - c.a2 * s.y2;
    s.x2 = s.x1; s.x1 = x;
    s.y2 = s.y1; s.y1 = y;
    return y;
}

// ============================================================================
// 3-Band Parametric EQ (200Hz / 1kHz / 5kHz)
// ============================================================================

struct EQ3Band {
    static constexpr int kBands = 3;
    static constexpr float kDefaultFreqs[3] = {200.0f, 1000.0f, 5000.0f};
    static constexpr float kDefaultQ = 1.0f;

    std::atomic<float> gains[3] = {{0}, {0}, {0}};  // dB (-12..+12)
    BiquadCoeffs coeffs[3] = {};
    // Per-channel state (max 2 channels)
    BiquadState state[3][2] = {};

    void update_coeffs() {
        for (int i = 0; i < kBands; i++) {
            coeffs[i] = peaking_eq(kDefaultFreqs[i], gains[i].load(std::memory_order_relaxed), kDefaultQ);
        }
    }

    float process(float sample, int channel) {
        float s = sample;
        for (int i = 0; i < kBands; i++) {
            if (std::fabs(gains[i].load(std::memory_order_relaxed)) > 0.01f) {
                s = biquad_process(coeffs[i], state[i][channel & 1], s);
            }
        }
        return s;
    }
};

constexpr float EQ3Band::kDefaultFreqs[3];

// ============================================================================
// Compressor / Limiter
// ============================================================================

struct Compressor {
    std::atomic<float> threshold{-20.0f};  // dB (-60..0)
    std::atomic<float> ratio{4.0f};        // 1:1 .. 20:1
    std::atomic<float> attack_ms{10.0f};   // ms (0.1-100)
    std::atomic<float> release_ms{100.0f}; // ms (10-1000)
    std::atomic<bool>  enabled{false};

    // Envelope follower state (audio-callback-only)
    float envelope_db = -96.0f;

    /// Process a single sample. Returns compressed sample.
    float process(float sample, float sample_rate = 48000.0f) {
        if (!enabled.load(std::memory_order_relaxed)) return sample;

        float thresh = threshold.load(std::memory_order_relaxed);
        float rat    = ratio.load(std::memory_order_relaxed);
        float att_ms = attack_ms.load(std::memory_order_relaxed);
        float rel_ms = release_ms.load(std::memory_order_relaxed);

        // Input level in dB
        float abs_s = std::fabs(sample);
        float input_db = (abs_s > 1e-10f) ? 20.0f * std::log10(abs_s) : -96.0f;

        // Envelope follower (peak detector with attack/release)
        float att_coeff = std::exp(-1.0f / (att_ms * sample_rate / 1000.0f));
        float rel_coeff = std::exp(-1.0f / (rel_ms * sample_rate / 1000.0f));

        if (input_db > envelope_db)
            envelope_db = att_coeff * envelope_db + (1.0f - att_coeff) * input_db;
        else
            envelope_db = rel_coeff * envelope_db + (1.0f - rel_coeff) * input_db;

        // Gain computation
        float gain_db = 0.0f;
        if (envelope_db > thresh) {
            float over = envelope_db - thresh;
            gain_db = over * (1.0f / rat - 1.0f);
        }

        float gain = std::pow(10.0f, gain_db / 20.0f);
        return sample * gain;
    }
};

// ============================================================================

/// Simple RTP receiver (embedded to avoid header dependency issues)
class SimpleRtpReceiver {
public:
    struct Config {
        uint16_t listen_port = kPortRTPBase;
        std::string multicast_group = kMulticastAudio;
        uint32_t channels = 1;
        SampleFormat format = SampleFormat::S24_LE;
        ReceiveMode mode = ReceiveMode::Auto;
    };

    struct Stats {
        uint64_t packets_received = 0;
        uint64_t packets_dropped = 0;
        uint64_t packets_concealed = 0;
        uint64_t sequence_errors = 0;
        uint64_t aes67_packets = 0;
        uint64_t ostp_packets = 0;
        int32_t last_sequence = -1;
    };

    explicit SimpleRtpReceiver(const Config& config)
        : config_(config)
        , frame_size_(sample_size(config.format) * config.channels)
        , recv_buf_(transport::kMaxPacketSize)
        , audio_buf_(transport::kMaxPayloadSize / sizeof(int32_t))
    {}

    Stats stats_snapshot() const { return stats_; }

    bool init() {
        socket_ = pal::UdpSocket::create();
        if (!socket_) return false;
        if (!socket_->bind(config_.listen_port)) return false;
        if (!socket_->join_multicast(config_.multicast_group)) return false;
        socket_->set_recv_timeout_ms(5);  // 5ms — batches WiFi bursts better than 1ms
        return true;
    }

    // Relay callback: invoked with raw bytes for every received packet
    std::function<void(const uint8_t*, size_t)> relay_callback;

    bool receive_packet(pipeline::RingBuffer& ring) {
        pal::SocketAddress src;
        int received = socket_->recv_from_nonblock(recv_buf_.data(), recv_buf_.size(), src);
        if (received <= 0) return false;

        // Forward raw bytes to nearby peers when in relay mode
        if (relay_callback) {
            relay_callback(recv_buf_.data(), static_cast<size_t>(received));
        }

        // Check if this is an AES67 packet or OSTP packet
        bool is_aes67 = false;
        if (config_.mode == ReceiveMode::Auto &&
            static_cast<size_t>(received) >= sizeof(transport::RtpHeader)) {
            const auto* rtp = reinterpret_cast<const transport::RtpHeader*>(recv_buf_.data());
            is_aes67 = aes67_is_standard_packet(*rtp);
        } else if (config_.mode == ReceiveMode::AES67) {
            is_aes67 = true;
        }

        if (is_aes67) {
            return receive_aes67_packet(recv_buf_.data(), static_cast<size_t>(received), ring);
        } else {
            return receive_ostp_packet(recv_buf_.data(), static_cast<size_t>(received), ring);
        }
    }

    const Stats& stats() const { return stats_; }

    /// Inject a raw packet from a relay peer (bypasses UDP socket)
    bool inject_raw_packet(const uint8_t* data, size_t len, pipeline::RingBuffer& ring) {
        bool is_aes67 = false;
        if (config_.mode == ReceiveMode::Auto && len >= sizeof(transport::RtpHeader)) {
            const auto* rtp = reinterpret_cast<const transport::RtpHeader*>(data);
            is_aes67 = aes67_is_standard_packet(*rtp);
        } else if (config_.mode == ReceiveMode::AES67) {
            is_aes67 = true;
        }
        if (is_aes67) return receive_aes67_packet(data, len, ring);
        else          return receive_ostp_packet(data, len, ring);
    }

private:
    bool receive_ostp_packet(const uint8_t* data, size_t len, pipeline::RingBuffer& ring) {
        transport::RtpHeader rtp;
        transport::OstpHeader ostp;
        const uint8_t* payload = nullptr;
        size_t payload_size = 0;

        if (transport::ostp_parse_packet(data, len, rtp, ostp, payload, payload_size) != 0) {
            return false;
        }

        // Multi-SSRC: route each source to its own sub-buffer for mixing
        // The main ring buffer is for the primary SSRC (radio).
        // Additional SSRCs go to mix_buffers_ and get mixed in audio_callback.
        if (rtp.ssrc != primary_ssrc_.load(std::memory_order_relaxed)) {
            if (primary_ssrc_.load(std::memory_order_relaxed) == 0) {
                // First SSRC becomes primary
                primary_ssrc_.store(rtp.ssrc, std::memory_order_relaxed);
            } else {
                // Secondary SSRC → mix buffer (decoded inline, skip sequence tracking)
                decode_to_mix_buffer(rtp, ostp, payload, payload_size);
                return true;
            }
        }

        // Sequence check — returns gap count (positive = missing packets)
        uint32_t full_seq = (static_cast<uint32_t>(ostp.sequence_ext) << 16) | rtp.sequence;
        int32_t gap = check_sequence(full_seq);

        stats_.packets_received++;
        stats_.ostp_packets++;
        last_ssrc.store(rtp.ssrc, std::memory_order_relaxed);

        // Discard duplicate packets (gap <= 0 means same or older sequence)
        if (gap < 0) return true;  // duplicate — already received

        // Store media_timestamp for sync mode (wall-clock NS, 32-bit truncated)
        if (ostp.media_timestamp != 0) {
            last_media_timestamp.store(ostp.media_timestamp, std::memory_order_relaxed);
        }

        // Auto-detect TX channel count from stream_id bits [13:10]
        // [2bit deck_id][4bit channels][10bit stream_idx]
        uint32_t deck_id = (ostp.stream_id >> 14) & 0x3;
        uint32_t tx_channels = (ostp.stream_id >> 10) & 0xF;
        if (tx_channels == 0) tx_channels = 2;  // backward compat
        detected_tx_channels_.store(tx_channels, std::memory_order_relaxed);

        const uint32_t ring_ch = config_.channels;

        // §4.9 IMA-ADPCM decode (PT=115 stereo, PT=116 mono)
        if (rtp.pt == 115 || rtp.pt == 116) {
            if (payload_size < 4) return false;
            // Always read state header from each packet (enables recovery after loss)
            adpcm_state_.valprev = static_cast<int16_t>(payload[0] | (payload[1] << 8));
            adpcm_state_.index = std::clamp(static_cast<int>(payload[2]), 0, 88);
            size_t num_samples = (payload_size - 4) * 2;
            size_t adpcm_frames = num_samples / tx_channels;
            for (size_t i = 0; i < num_samples && i < adpcm_decode_buf_.size(); i++) {
                uint8_t nib = (i & 1) ? ((payload[4 + i/2] >> 4) & 0x0F) : (payload[4 + i/2] & 0x0F);
                int step = ima_step_table_[adpcm_state_.index];
                int dq = step >> 3;
                if (nib & 4) dq += step;
                if (nib & 2) dq += (step >> 1);
                if (nib & 1) dq += (step >> 2);
                adpcm_state_.valprev += (nib & 8) ? -dq : dq;
                if (adpcm_state_.valprev > 32767) adpcm_state_.valprev = 32767;
                if (adpcm_state_.valprev < -32768) adpcm_state_.valprev = -32768;
                adpcm_state_.index += ima_index_table_[nib];
                if (adpcm_state_.index < 0) adpcm_state_.index = 0;
                if (adpcm_state_.index > 88) adpcm_state_.index = 88;
                adpcm_decode_buf_[i] = static_cast<int32_t>(adpcm_state_.valprev) << 8;
            }
            if (tx_channels == ring_ch) {
                ring.write(adpcm_decode_buf_.data(), adpcm_frames);
            } else {
                for (size_t f = 0; f < adpcm_frames; f++)
                    for (uint32_t c = 0; c < ring_ch; c++)
                        audio_buf_[f * ring_ch + c] = adpcm_decode_buf_[f * tx_channels + (c < tx_channels ? c : 0)];
                ring.write(audio_buf_.data(), adpcm_frames);
            }
            return true;
        }

        // Raw PCM: seed ADPCM from last sample (§4.9 Raw First)
        if (rtp.pt == 96 && payload_size >= sizeof(int32_t)) {
            int32_t last = reinterpret_cast<const int32_t*>(payload)[payload_size/sizeof(int32_t) - 1];
            adpcm_state_.valprev = static_cast<int16_t>(last >> 8);
            adpcm_state_.index = 0;
        }

        // OSTP payload is int32_t (4 bytes/sample, native byte order)
        size_t frames = payload_size / (sizeof(int32_t) * tx_channels);

        // Ring buffer frame_size = config_.channels * sizeof(int32_t).
        // When tx_channels < config_.channels, we must pad each frame with
        // zeros so the data matches the ring buffer's frame layout.
        // ring_ch already defined above

        // PLC: conceal gaps of ≤2 packets by repeating the last known frame
        if (gap > 0 && gap <= 2 && frames > 0 && !last_frame_.empty()) {
            size_t plc_frames = last_frame_.size() / ring_ch;
            for (int32_t i = 0; i < gap; i++) {
                ring.write(last_frame_.data(), plc_frames);
            }
            stats_.packets_concealed += static_cast<uint64_t>(gap);
        }

        if (on_decoded) {
            on_decoded(rtp.ssrc, reinterpret_cast<const int32_t*>(payload), frames, tx_channels);
        }

        // Expand tx_channels → ring_ch (zero-pad unused channels)
        const int32_t* src_samples = reinterpret_cast<const int32_t*>(payload);
        if (tx_channels == ring_ch) {
            ring.write(payload, frames);
        } else {
            // Pad each frame: copy tx_channels samples, zero the rest
            // Use audio_buf_ as scratch space (already sized for max payload)
            for (size_t f = 0; f < frames; f++) {
                for (uint32_t c = 0; c < tx_channels; c++)
                    audio_buf_[f * ring_ch + c] = src_samples[f * tx_channels + c];
                for (uint32_t c = tx_channels; c < ring_ch; c++)
                    audio_buf_[f * ring_ch + c] = 0;
            }
            ring.write(audio_buf_.data(), frames);
        }

        // Save last frame for PLC (in ring_ch-wide format)
        if (frames > 0) {
            if (tx_channels == ring_ch) {
                last_frame_.assign(src_samples, src_samples + frames * ring_ch);
            } else {
                last_frame_.resize(frames * ring_ch);
                for (size_t f = 0; f < frames; f++) {
                    for (uint32_t c = 0; c < tx_channels; c++)
                        last_frame_[f * ring_ch + c] = src_samples[f * tx_channels + c];
                    for (uint32_t c = tx_channels; c < ring_ch; c++)
                        last_frame_[f * ring_ch + c] = 0;
                }
            }
        }

        return true;
    }

    bool receive_aes67_packet(const uint8_t* data, size_t len, pipeline::RingBuffer& ring) {
        if (len < sizeof(transport::RtpHeader)) {
            return false;
        }

        transport::RtpHeader rtp;
        std::memcpy(&rtp, data, sizeof(transport::RtpHeader));

        uint16_t sequence = ntohs(rtp.sequence);

        // Sequence check (16-bit only for AES67)
        if (stats_.last_sequence >= 0) {
            int32_t last16 = stats_.last_sequence & 0xFFFF;
            int32_t diff = static_cast<int32_t>(sequence) - last16;
            if (diff < -32768) diff += 65536;
            if (diff > 32768) diff -= 65536;
            if (diff != 1) {
                stats_.sequence_errors++;
                if (diff > 0) {
                    stats_.packets_dropped += static_cast<uint64_t>(diff - 1);
                }
            }
        }
        stats_.last_sequence = sequence;
        stats_.packets_received++;
        stats_.aes67_packets++;

        // Extract payload
        const uint8_t* payload = data + sizeof(transport::RtpHeader);
        size_t payload_size = len - sizeof(transport::RtpHeader);

        // Convert payload based on payload type
        size_t samples = 0;
        if (rtp.pt == kPayloadTypeL24 || rtp.pt == kPayloadTypeL24_AES67) {
            // L24: 24-bit packed big-endian -> S24_LE
            samples = payload_size / 3;
            for (size_t i = 0; i < samples && i < audio_buf_.size(); i++) {
                int32_t sample = (static_cast<int32_t>(payload[i * 3]) << 16)
                               | (static_cast<int32_t>(payload[i * 3 + 1]) << 8)
                               | static_cast<int32_t>(payload[i * 3 + 2]);
                if (sample & 0x800000) {
                    sample |= 0xFF000000;
                }
                audio_buf_[i] = sample;
            }
        } else if (rtp.pt == kPayloadTypeL16 || rtp.pt == kPayloadTypeL16_AES67) {
            // L16: 16-bit big-endian -> S24_LE
            samples = payload_size / 2;
            const int16_t* src = reinterpret_cast<const int16_t*>(payload);
            for (size_t i = 0; i < samples && i < audio_buf_.size(); i++) {
                int16_t be_sample = src[i];
                int16_t sample_le = static_cast<int16_t>((be_sample >> 8) | (be_sample << 8));
                audio_buf_[i] = static_cast<int32_t>(sample_le) << 8;
            }
        } else {
            return false;
        }

        size_t frames = samples / config_.channels;
        ring.write(audio_buf_.data(), frames);

        return true;
    }

    // Returns the gap (missing packet count > 0) or 0 if in sequence
    int32_t check_sequence(uint32_t full_seq) {
        int32_t gap = 0;
        if (stats_.last_sequence >= 0) {
            int32_t expected = stats_.last_sequence + 1;
            if (static_cast<int32_t>(full_seq) != expected) {
                stats_.sequence_errors++;
                gap = static_cast<int32_t>(full_seq) - expected;
                if (gap > 0) {
                    stats_.packets_dropped += static_cast<uint64_t>(gap);
                }
            }
        }
        stats_.last_sequence = static_cast<int32_t>(full_seq);
        return gap;
    }

    Config config_;
    size_t frame_size_;
    std::unique_ptr<pal::UdpSocket> socket_;
    std::vector<uint8_t> recv_buf_;
    std::vector<int32_t> audio_buf_;
    std::vector<int32_t> last_frame_;  // PLC: last received frame for concealment
    // §4.9 ADPCM decode state + buffer
    struct { int32_t valprev = 0; int32_t index = 0; } adpcm_state_;
    std::vector<int32_t> adpcm_decode_buf_ = std::vector<int32_t>(2048);
    static constexpr int16_t ima_step_table_[89] = {
        7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,
        50,55,60,66,73,80,88,97,107,118,130,143,157,173,190,209,230,
        253,279,307,337,371,408,449,494,544,598,658,724,796,876,963,
        1060,1166,1282,1411,1552,1707,1878,2066,2272,2499,2749,3024,
        3327,3660,4026,4428,4871,5358,5894,6484,7132,7845,8630,9493,
        10442,11487,12635,13899,15289,16818,18500,20350,22385,24623,
        27086,29794,32767};
    static constexpr int8_t ima_index_table_[16] = {-1,-1,-1,-1,2,4,6,8,-1,-1,-1,-1,2,4,6,8};
    Stats stats_;

public:
    // NTP-based sync: pointer to ReceiverImpl's target_fill_frames_ (set externally)
    std::atomic<uint32_t>* sync_target_frames_ = nullptr;
    double sync_playout_delay_ms_ = 80.0;  // default playout delay matching RPi

    // Last received OSTP media timestamp (wall-clock NS, 32-bit truncated)
    std::atomic<uint32_t> last_media_timestamp{0};

    // Auto-detected TX channel count from OSTP stream_id upper 4 bits
    std::atomic<uint32_t> detected_tx_channels_{2};  // default stereo (most common TX)
    std::atomic<uint32_t> primary_ssrc_{0};  // First SSRC = primary (goes to main ring buffer)

    // ── Multi-SSRC mix buffers (for karaoke/talk mode) ──
    // Lock-free SPSC ring buffer per secondary SSRC.
    static constexpr size_t kMixBufSize = 48000;  // 1 second mono float
    static constexpr int kMaxMixSources = 4;      // max 4 simultaneous mics
    struct MixSource {
        uint32_t ssrc = 0;
        float ring[48000] = {};
        std::atomic<size_t> write_pos{0};
        std::atomic<size_t> read_pos{0};
        std::chrono::steady_clock::time_point last_seen;
        struct { int32_t valprev = 0; int32_t index = 0; } adpcm_state;
    };
    MixSource mix_sources_[4];
    std::atomic<int> mix_source_count_{0};

    void decode_to_mix_buffer(const transport::RtpHeader& rtp,
                               const transport::OstpHeader& ostp,
                               const uint8_t* payload, size_t payload_size) {
        // Find or create mix source for this SSRC
        MixSource* src = nullptr;
        int count = mix_source_count_.load(std::memory_order_relaxed);
        for (int i = 0; i < count; i++) {
            if (mix_sources_[i].ssrc == rtp.ssrc) { src = &mix_sources_[i]; break; }
        }
        if (!src && count < kMaxMixSources) {
            src = &mix_sources_[count];
            src->ssrc = rtp.ssrc;
            src->write_pos.store(0); src->read_pos.store(0);
            src->adpcm_state = {};
            mix_source_count_.store(count + 1, std::memory_order_relaxed);
        }
        if (!src) return;  // too many sources
        src->last_seen = std::chrono::steady_clock::now();

        // Decode based on PT
        size_t w = src->write_pos.load(std::memory_order_relaxed);
        if (rtp.pt == 116 && payload_size >= 4) {
            // ADPCM decode
            src->adpcm_state.valprev = static_cast<int16_t>(payload[0] | (payload[1] << 8));
            src->adpcm_state.index = std::clamp(static_cast<int>(payload[2]), 0, 88);
            size_t nsamples = (payload_size - 4) * 2;
            for (size_t i = 0; i < nsamples; i++) {
                uint8_t nib = (i & 1) ? ((payload[4 + i/2] >> 4) & 0x0F) : (payload[4 + i/2] & 0x0F);
                int step = ima_step_table_[src->adpcm_state.index];
                int dq = step >> 3;
                if (nib & 4) dq += step;
                if (nib & 2) dq += (step >> 1);
                if (nib & 1) dq += (step >> 2);
                src->adpcm_state.valprev += (nib & 8) ? -dq : dq;
                if (src->adpcm_state.valprev > 32767) src->adpcm_state.valprev = 32767;
                if (src->adpcm_state.valprev < -32768) src->adpcm_state.valprev = -32768;
                src->adpcm_state.index += ima_index_table_[nib];
                if (src->adpcm_state.index < 0) src->adpcm_state.index = 0;
                if (src->adpcm_state.index > 88) src->adpcm_state.index = 88;
                src->ring[(w + i) % kMixBufSize] = src->adpcm_state.valprev / 32768.0f;
            }
            src->write_pos.store(w + nsamples, std::memory_order_release);
        } else if (rtp.pt == 96 && payload_size >= 4) {
            // PCM S24 mono
            size_t nsamples = payload_size / 4;
            for (size_t i = 0; i < nsamples; i++) {
                int32_t s;
                memcpy(&s, payload + i * 4, 4);
                src->ring[(w + i) % kMixBufSize] = s / 8388608.0f;
            }
            src->write_pos.store(w + nsamples, std::memory_order_release);
        }
    }

    // Called from audio_callback to mix secondary sources into output
    void mix_secondary_sources(float* output, uint32_t frame_count, uint32_t out_channels) {
        int count = mix_source_count_.load(std::memory_order_relaxed);
        for (int s = 0; s < count; s++) {
            auto& src = mix_sources_[s];
            size_t r = src.read_pos.load(std::memory_order_relaxed);
            size_t w = src.write_pos.load(std::memory_order_acquire);
            if (w <= r) continue;
            size_t avail = w - r;
            if (avail > kMixBufSize) { src.read_pos.store(w - kMixBufSize / 2); r = w - kMixBufSize / 2; avail = w - r; }
            size_t to_mix = std::min(avail, static_cast<size_t>(frame_count));
            for (size_t i = 0; i < to_mix; i++) {
                float sample = src.ring[(r + i) % kMixBufSize] * 0.6f;
                for (uint32_t ch = 0; ch < out_channels; ch++) {
                    size_t idx = i * out_channels + ch;
                    if (idx < frame_count * out_channels) {
                        output[idx] = std::max(-1.0f, std::min(1.0f, output[idx] + sample));
                    }
                }
            }
            src.read_pos.store(r + to_mix, std::memory_order_release);
        }
    }

    // Last received RTP SSRC (for multi-source identification)
    std::atomic<uint32_t> last_ssrc{0};

    // Callback invoked with decoded PCM + SSRC for multi-source mixing
    std::function<void(uint32_t ssrc, const int32_t* data, size_t frames, uint32_t channels)> on_decoded;
};

/// WAN relay client — connects to soluna-relay server via UDP
class WanRelayClient {
public:
    enum class State { Disconnected, Connecting, Connected, Error };
    using RxCallback = std::function<void(const uint8_t*, size_t)>;
    using MetaCallback = std::function<void(const std::string&)>;
    using FileCallback = std::function<void(const std::string&)>;
    using SyncCallback = std::function<void(const std::string&)>;
    using VolumeCallback = std::function<void(float)>;

    // Try to find solunad on LAN by probing subnet:5099
    // Sends HELLO to broadcast + common IPs, returns first responder's IP
    std::string discover_lan_solunad() {
        append_debug("LAN scan start port=5099");
        send_debug_to_mac("LAN scan start");
        int sock = ::socket(AF_INET, SOCK_DGRAM, 0);
        if (sock < 0) { append_debug("LAN scan: socket() failed"); return ""; }

        int yes = 1;
        setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &yes, sizeof(yes));
        struct timeval tv{0, 500000};  // 500ms timeout per recv (was 200ms)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

        // Get our own IP — prefer en0 (WiFi) over cellular
        struct ifaddrs *ifas = nullptr;
        getifaddrs(&ifas);
        uint32_t my_ip = 0;
        uint32_t my_mask = 0;

        // First pass: prefer en0 (WiFi)
        for (struct ifaddrs *ifa = ifas; ifa; ifa = ifa->ifa_next) {
            if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET) continue;
            if (!(ifa->ifa_flags & IFF_UP) || (ifa->ifa_flags & IFF_LOOPBACK)) continue;
            std::string ifname(ifa->ifa_name);
            if (ifname != "en0") continue;
            auto *sin = (sockaddr_in*)ifa->ifa_addr;
            auto *mask = (sockaddr_in*)ifa->ifa_netmask;
            if (!mask) continue;
            my_ip = ntohl(sin->sin_addr.s_addr);
            my_mask = ntohl(mask->sin_addr.s_addr);
            char ip_str[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &sin->sin_addr, ip_str, sizeof(ip_str));
            NSLog(@"[lan-discover] My IP: %s iface=en0", ip_str);
            append_debug(std::string("MyIP=") + ip_str + " iface=en0");
            send_debug_to_mac(std::string("LAN MyIP=") + ip_str);
            break;
        }
        // Second pass: any en* interface
        if (my_ip == 0) {
            for (struct ifaddrs *ifa = ifas; ifa; ifa = ifa->ifa_next) {
                if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET) continue;
                if (!(ifa->ifa_flags & IFF_UP) || (ifa->ifa_flags & IFF_LOOPBACK)) continue;
                std::string ifname(ifa->ifa_name);
                if (ifname.find("en") != 0) continue;
                auto *sin = (sockaddr_in*)ifa->ifa_addr;
                auto *mask = (sockaddr_in*)ifa->ifa_netmask;
                if (!mask) continue;
                my_ip = ntohl(sin->sin_addr.s_addr);
                my_mask = ntohl(mask->sin_addr.s_addr);
                char ip_str[INET_ADDRSTRLEN];
                inet_ntop(AF_INET, &sin->sin_addr, ip_str, sizeof(ip_str));
                append_debug(std::string("MyIP=") + ip_str + " iface=" + ifname);
                send_debug_to_mac(std::string("LAN MyIP=") + ip_str + " " + ifname);
                break;
            }
        }
        if (ifas) freeifaddrs(ifas);

        if (my_ip == 0) {
            append_debug("LAN: no WiFi IP found");
            send_debug_to_mac("LAN: no WiFi IP");
            ::close(sock);
            return "";
        }

        uint32_t network = my_ip & my_mask;
        uint32_t bcast_ip = network | ~my_mask;

        // Send HELLO to broadcast + ALL /24 IPs for thorough scan
        sockaddr_in dest{};
        dest.sin_family = AF_INET;
        dest.sin_port = htons(5099);

        // Broadcast
        dest.sin_addr.s_addr = htonl(bcast_ip);
        ::sendto(sock, "HELLO\n", 6, 0, (sockaddr*)&dest, sizeof(dest));

        // Scan ALL IPs in /24 subnet (only 254 UDP packets, very fast)
        uint32_t host_part = my_ip & ~my_mask;
        int sent_count = 0;
        for (uint32_t h = 1; h <= 254; ++h) {
            if (h == host_part) continue;
            dest.sin_addr.s_addr = htonl(network | h);
            ::sendto(sock, "HELLO\n", 6, 0, (sockaddr*)&dest, sizeof(dest));
            sent_count++;
        }
        char scan_msg[128];
        snprintf(scan_msg, sizeof(scan_msg), "LAN sent HELLO to %d IPs + bcast", sent_count);
        append_debug(scan_msg);
        send_debug_to_mac(scan_msg);

        // Wait for response — up to 3 seconds (6 x 500ms)
        std::string found_ip;
        for (int i = 0; i < 6 && found_ip.empty(); ++i) {
            uint8_t buf[2048];
            sockaddr_in sender{};
            socklen_t slen = sizeof(sender);
            ssize_t n = ::recvfrom(sock, buf, sizeof(buf), 0, (sockaddr*)&sender, &slen);
            if (n > 0) {
                uint32_t sender_ip = ntohl(sender.sin_addr.s_addr);
                if (sender_ip != my_ip) {
                    // Check if it looks like an OSTP/RTP packet (first byte 0x80-0xBF)
                    bool is_audio = (n >= 12 && (buf[0] & 0xC0) == 0x80);
                    char ip[INET_ADDRSTRLEN];
                    inet_ntop(AF_INET, &sender.sin_addr, ip, sizeof(ip));
                    char msg[256];
                    snprintf(msg, sizeof(msg), "LAN resp from %s %zdB audio=%d", ip, n, is_audio);
                    append_debug(msg);
                    send_debug_to_mac(msg);
                    if (is_audio) {
                        NSLog(@"[lan-discover] Found solunad at %s (%zd bytes)", ip, n);
                        found_ip = ip;
                    }
                }
            }
        }
        ::close(sock);
        if (found_ip.empty()) {
            append_debug("LAN: no solunad found");
            send_debug_to_mac("LAN: no solunad found");
        }
        return found_ip;
    }

    bool connect(const std::string& host, uint16_t port,
                 const std::string& group, const std::string& password,
                 const std::string& device_name,
                 const std::string& device_id = "") {
        device_id_ = device_id;
        if (state_.load() == State::Connected) disconnect();
        state_.store(State::Connecting);
        group_ = group;
        error_.clear();

        // Use provided host/port directly — no automatic LAN discovery.
        // When the user sets a manual LAN host they pass port=5099 explicitly from Swift.
        // For WAN relay (default), always stay on WAN to receive the relay audio stream.
        // Automatic LAN fallback previously caused the iPhone to connect to the Mac solunad
        // which transmits Mac system audio (often silence) instead of relay music.
        std::string actual_host = host;
        uint16_t actual_port = port;
        NSLog(@"[wan-relay] Connecting to %s:%u group=%s", host.c_str(), port, group.c_str());
        append_debug("RELAY: " + host + ":" + std::to_string(port));

        // DNS resolve
        struct addrinfo hints{}, *res = nullptr;
        hints.ai_family = AF_INET;
        hints.ai_socktype = SOCK_DGRAM;
        char port_str[16];
        snprintf(port_str, sizeof(port_str), "%u", actual_port);
        if (getaddrinfo(actual_host.c_str(), port_str, &hints, &res) != 0 || !res) {
            error_ = "DNS resolution failed: " + actual_host;
            state_.store(State::Error);
            return false;
        }
        std::memcpy(&relay_addr_, res->ai_addr, sizeof(relay_addr_));
        freeaddrinfo(res);

        udp_sock_ = ::socket(AF_INET, SOCK_DGRAM, 0);
        if (udp_sock_ < 0) {
            error_ = "socket() failed";
            append_debug("socket() FAILED");
            state_.store(State::Error);
            return false;
        }

        // Log resolved address
        char resolved_ip[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &((sockaddr_in*)&relay_addr_)->sin_addr, resolved_ip, sizeof(resolved_ip));
        uint16_t resolved_port = ntohs(((sockaddr_in*)&relay_addr_)->sin_port);
        append_debug(std::string("CONNECT ") + resolved_ip + ":" + std::to_string(resolved_port) + " fd=" + std::to_string(udp_sock_));

        // Send HELLO to start receiving audio (Mac relay doesn't need JOIN)
        const char* hello = "HELLO\n";
        for (int i = 0; i < 3; ++i) {
            ssize_t sent = ::sendto(udp_sock_, hello, 6, 0,
                     (struct sockaddr*)&relay_addr_, sizeof(relay_addr_));
            append_debug("HELLO sent=" + std::to_string(sent));
            if (i < 2) usleep(100000);
        }
        // Also send JOIN for WAN relay compatibility
        std::string join_msg = "JOIN:" + group + ":" + password + ":" + device_name;
        if (!device_id_.empty()) join_msg += ":" + device_id_;
        join_msg += "\n";
        ::sendto(udp_sock_, join_msg.c_str(), join_msg.size(), 0,
                 (struct sockaddr*)&relay_addr_, sizeof(relay_addr_));

        nack_last_seq_ = -1;
        rx_pkt_count_  = 0;
        fec_pending_seqs_.clear();
        nack_fire_at_.clear();
        fec_rx_buf_.clear();
        external_addr_.clear();
        running_.store(true);
        state_.store(State::Connected);
        append_debug("recv_loop starting...");
        recv_thread_ = std::thread([this]() { recv_loop(); });
        return true;
    }

    void disconnect() {
        running_.store(false);
        if (recv_thread_.joinable()) recv_thread_.join();
        if (udp_sock_ >= 0) { ::close(udp_sock_); udp_sock_ = -1; }
        {
            std::lock_guard<std::mutex> lk(peers_mutex_);
            peers_.clear();
        }
        state_.store(State::Disconnected);
        group_.clear();
        error_.clear();
    }

    void send_audio(const uint8_t* data, size_t len) {
        if (udp_sock_ < 0 || state_.load() != State::Connected) return;
        // Send to all direct peers (P2P)
        {
            std::lock_guard<std::mutex> lk(peers_mutex_);
            for (const auto& peer : peers_) {
                ::sendto(udp_sock_, data, len, 0,
                         (const struct sockaddr*)&peer, sizeof(peer));
            }
        }
        // Also send via relay as fallback
        ::sendto(udp_sock_, data, len, 0,
                 (struct sockaddr*)&relay_addr_, sizeof(relay_addr_));
    }

    void set_rx_callback(RxCallback cb) {
        std::lock_guard<std::mutex> lk(cb_mutex_);
        rx_callback_ = std::move(cb);
    }

    void set_meta_callback(MetaCallback cb) {
        std::lock_guard<std::mutex> lk(cb_mutex_);
        meta_callback_ = std::move(cb);
    }

    void set_file_callback(FileCallback cb) {
        std::lock_guard<std::mutex> lk(cb_mutex_);
        file_callback_ = std::move(cb);
    }

    void set_sync_callback(SyncCallback cb) {
        std::lock_guard<std::mutex> lk(cb_mutex_);
        sync_callback_ = std::move(cb);
    }

    using MaxDelayCallback = std::function<void(uint32_t)>;
    void set_maxdelay_callback(MaxDelayCallback cb) {
        std::lock_guard<std::mutex> lk(cb_mutex_);
        maxdelay_callback_ = std::move(cb);
    }

    void set_volume_callback(VolumeCallback cb) {
        std::lock_guard<std::mutex> lk(cb_mutex_);
        volume_callback_ = std::move(cb);
    }

    /// Send VOLUME command to relay targeting a specific device
    void send_volume(const std::string& target_device_id, int level) {
        char buf[128];
        snprintf(buf, sizeof(buf), "VOLUME:%s:%d\n", target_device_id.c_str(), level);
        send_command(std::string(buf));
    }

    /// Send DELAY report to relay (for sync mode coordination)
    void send_delay(uint32_t net_delay_ms) {
        if (udp_sock_ < 0 || state_.load() != State::Connected) return;
        char buf[64];
        snprintf(buf, sizeof(buf), "DELAY:%u\n", net_delay_ms);
        ::sendto(udp_sock_, buf, strlen(buf), 0,
                 (struct sockaddr*)&relay_addr_, sizeof(relay_addr_));
    }

    /// Send READY notification to relay
    void send_ready(const std::string& filename) {
        if (udp_sock_ < 0 || state_.load() != State::Connected) return;
        std::string msg = "READY:" + filename + "\n";
        ::sendto(udp_sock_, msg.c_str(), msg.size(), 0,
                 (struct sockaddr*)&relay_addr_, sizeof(relay_addr_));
    }

    State state() const { return state_.load(); }
    const std::string& group() const { return group_; }
    const std::string& error() const { return error_; }
    const std::string& device_id() const { return device_id_; }

    /// Send MIC_ALLOW command (owner/DJ only)
    void send_mic_allow(const std::string& target_device_id) {
        send_command("MIC_ALLOW:" + target_device_id);
    }

    /// Send MIC_DENY command (owner/DJ only)
    void send_mic_deny(const std::string& target_device_id) {
        send_command("MIC_DENY:" + target_device_id);
    }

    /// Request mic list from relay
    void send_mic_list() {
        send_command("MIC_LIST");
    }

    /// Request member list from relay
    void send_members() {
        send_command("MEMBERS");
    }

private:
    void send_command(const std::string& cmd) {
        if (udp_sock_ < 0 || state_.load() != State::Connected) return;
        std::string msg = cmd + "\n";
        ::sendto(udp_sock_, msg.c_str(), msg.size(), 0,
                 (struct sockaddr*)&relay_addr_, sizeof(relay_addr_));
    }

public:

    /// Get current clock offset in nanoseconds (relay_time - local_time).
    /// Positive = local clock is behind relay, negative = local clock is ahead.
    int64_t clock_offset_ns() const { return clock_offset_ns_.load(std::memory_order_relaxed); }

    /// Thread-safe debug log for on-screen display
    std::string get_debug_log() const {
        std::lock_guard<std::mutex> lk(debug_mutex_);
        return debug_log_;
    }

    void append_debug(const std::string& msg) {
        std::lock_guard<std::mutex> lk(debug_mutex_);
        // Keep last 10 lines
        debug_log_ += msg + "\n";
        size_t lines = 0;
        for (auto c : debug_log_) if (c == '\n') lines++;
        while (lines > 10) {
            auto pos = debug_log_.find('\n');
            if (pos == std::string::npos) break;
            debug_log_.erase(0, pos + 1);
            lines--;
        }
    }

private:
    // Send debug info to Mac via UDP
    void send_debug_to_mac(const std::string& msg) {
        static int dbg_sock = -1;
        static sockaddr_in dbg_addr{};
        if (dbg_sock < 0) {
            dbg_sock = ::socket(AF_INET, SOCK_DGRAM, 0);
            dbg_addr.sin_family = AF_INET;
            dbg_addr.sin_port = htons(9999);
            inet_pton(AF_INET, "192.168.0.194", &dbg_addr.sin_addr);
        }
        if (dbg_sock >= 0) {
            ::sendto(dbg_sock, msg.c_str(), msg.size(), 0,
                     (sockaddr*)&dbg_addr, sizeof(dbg_addr));
        }
    }

    void recv_loop() {
        append_debug("recv_loop RUNNING");
        send_debug_to_mac("recv_loop RUNNING");
        struct timeval tv{1, 0};
        setsockopt(udp_sock_, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

        uint8_t buf[16384];  // Must fit OSTP packets (up to ~4KB for 480-frame stereo)
        auto last_hello = std::chrono::steady_clock::now();
        uint64_t recv_total = 0, recv_rtp = 0, recv_ctrl = 0;
        auto last_log = std::chrono::steady_clock::now();

        while (running_.load()) {
            sockaddr_in sender{};
            socklen_t sender_len = sizeof(sender);
            ssize_t n = ::recvfrom(udp_sock_, buf, sizeof(buf), 0,
                                   (struct sockaddr*)&sender, &sender_len);
            if (n > 0) {
                // PEER message: "PEER:ip:port\n"
                if (n >= 6 && memcmp(buf, "PEER:", 5) == 0) {
                    std::string msg((const char*)buf, n);
                    while (!msg.empty() && (msg.back() == '\n' || msg.back() == '\r'))
                        msg.pop_back();
                    auto colon = msg.rfind(':');
                    if (colon != std::string::npos && colon > 5) {
                        std::string ip = msg.substr(5, colon - 5);
                        uint16_t pport = (uint16_t)atoi(msg.substr(colon + 1).c_str());
                        sockaddr_in peer{};
                        peer.sin_family = AF_INET;
                        peer.sin_port = htons(pport);
                        inet_pton(AF_INET, ip.c_str(), &peer.sin_addr);
                        add_peer(peer);
                        fprintf(stderr, "[wan-p2p] Peer discovered: %s:%u\n", ip.c_str(), pport);
                        // Send a punch packet to open NAT
                        const char* punch = "PUNCH\n";
                        ::sendto(udp_sock_, punch, 6, 0,
                                 (const struct sockaddr*)&peer, sizeof(peer));
                    }
                }
                // META message: metadata broadcast from relay
                else if (n >= 5 && memcmp(buf, "META:", 5) == 0) {
                    std::string meta((const char*)buf + 5, n - 5);
                    while (!meta.empty() && (meta.back() == '\n' || meta.back() == '\r'))
                        meta.pop_back();
                    std::lock_guard<std::mutex> lk(cb_mutex_);
                    if (meta_callback_) meta_callback_(meta);
                }
                // FILE: message — file sync mode, download and prepare
                else if (n >= 5 && memcmp(buf, "FILE:", 5) == 0) {
                    std::string filename((const char*)buf + 5, n - 5);
                    while (!filename.empty() && (filename.back() == '\n' || filename.back() == '\r'))
                        filename.pop_back();
                    std::lock_guard<std::mutex> lk(cb_mutex_);
                    if (file_callback_) file_callback_(filename);
                }
                // SYNC: message — file sync mode, play/pause/seek
                else if (n >= 5 && memcmp(buf, "SYNC:", 5) == 0) {
                    std::string sync((const char*)buf + 5, n - 5);
                    while (!sync.empty() && (sync.back() == '\n' || sync.back() == '\r'))
                        sync.pop_back();
                    std::lock_guard<std::mutex> lk(cb_mutex_);
                    if (sync_callback_) sync_callback_(sync);
                }
                // MAXDELAY: message — sync mode, group-wide max delay from relay
                else if (n >= 9 && memcmp(buf, "MAXDELAY:", 9) == 0) {
                    std::string val((const char*)buf + 9, n - 9);
                    while (!val.empty() && (val.back() == '\n' || val.back() == '\r'))
                        val.pop_back();
                    try {
                        uint32_t max_ms = static_cast<uint32_t>(std::stoul(val));
                        if (max_ms > 2000) max_ms = 2000;
                        std::lock_guard<std::mutex> lk(cb_mutex_);
                        if (maxdelay_callback_) maxdelay_callback_(max_ms);
                    } catch (...) {}
                }
                // VOLUME_SET: remote volume control from another device via relay
                else if (n >= 11 && memcmp(buf, "VOLUME_SET:", 11) == 0) {
                    std::string val((const char*)buf + 11, n - 11);
                    while (!val.empty() && (val.back() == '\n' || val.back() == '\r'))
                        val.pop_back();
                    int level = std::atoi(val.c_str());
                    float vol = std::max(0.0f, std::min(1.0f, level / 100.0f));
                    std::lock_guard<std::mutex> lk(cb_mutex_);
                    if (volume_callback_) volume_callback_(vol);
                }
                // SWARM_ASSIGN: relay tells us to forward audio to child nodes (P2P mesh)
                else if (n >= 13 && memcmp(buf, "SWARM_ASSIGN:", 13) == 0) {
                    std::string payload((const char*)buf + 13, n - 13);
                    while (!payload.empty() && (payload.back() == '\n' || payload.back() == '\r'))
                        payload.pop_back();
                    auto colon = payload.rfind(':');
                    if (colon != std::string::npos && colon > 0) {
                        std::string ip = payload.substr(0, colon);
                        uint16_t cport = (uint16_t)atoi(payload.substr(colon + 1).c_str());
                        sockaddr_in child{};
                        child.sin_family = AF_INET;
                        child.sin_port = htons(cport);
                        inet_pton(AF_INET, ip.c_str(), &child.sin_addr);
                        std::lock_guard<std::mutex> lk(children_mutex_);
                        if (swarm_children_.size() < 4) {
                            swarm_children_.push_back(child);
                            NSLog(@"[swarm] Assigned child: %s:%u (total: %zu)", ip.c_str(), cport, swarm_children_.size());
                        }
                    }
                }
                // YOUR_ADDR: relay reports our external IP:port (§6.6, NAT traversal)
                else if (n >= 11 && memcmp(buf, "YOUR_ADDR:", 10) == 0) {
                    std::string addr((const char*)buf + 10, n - 10);
                    while (!addr.empty() && (addr.back() == '\n' || addr.back() == '\r'))
                        addr.pop_back();
                    external_addr_ = addr;
                    append_debug("YOUR_ADDR=" + addr);
                }
                // Clock sync pong (PT=125, 0x7D marker, 25 bytes)
                else if (n == 25 && buf[0] == 0x7D) {
                    handle_sync_pong(buf, static_cast<size_t>(n));
                }
                // RTCP APP (PT=204) "SWCH" — synchronized file switch (OSTP v0.9.3 §5.4)
                else if (n == 16 && (buf[0] & 0xC0) == 0x80 && buf[1] == 204 &&
                         buf[8] == 'S' && buf[9] == 'W' && buf[10] == 'C' && buf[11] == 'H') {
                    uint32_t switch_at_rtp;
                    std::memcpy(&switch_at_rtp, buf + 12, 4);
                    switch_at_rtp = ntohl(switch_at_rtp);
                    // Notify via SYNC: callback with "switch:<rtp_ts>" command
                    char swch_cmd[32];
                    snprintf(swch_cmd, sizeof(swch_cmd), "switch:%u", (unsigned)switch_at_rtp);
                    std::lock_guard<std::mutex> lk(cb_mutex_);
                    if (sync_callback_) sync_callback_(std::string(swch_cmd));
                }
                // RTP/OSTP packet: from relay or peer
                else if (n >= 12 && (buf[0] & 0xC0) == 0x80) {
                    recv_rtp++;
                    uint8_t pt = buf[1] & 0x7F;

                    if (n >= 28 && (buf[0] & 0x10) &&
                        buf[12] == 0x4F && buf[13] == 0x53) {

                        if (pt == 127) {
                            // PT=127: FEC parity packet — attempt XOR recovery (§8.1)
                            handle_fec_packet(buf, static_cast<size_t>(n));
                        } else if (pt != 126) {
                            // Audio packet: buffer for FEC recovery
                            uint16_t rtp_seq = (uint16_t)((buf[2] << 8) | buf[3]);
                            FecRxEntry entry;
                            entry.seq = rtp_seq;
                            entry.pkt.assign(buf, buf + n);
                            fec_rx_buf_.push_back(std::move(entry));
                            if ((int)fec_rx_buf_.size() > kFecRxBufSize)
                                fec_rx_buf_.pop_front();

                            // Mark this seq as received (remove from pending if NACK not yet sent)
                            fec_pending_seqs_.erase(rtp_seq);

                            rx_pkt_count_++;

                            // Fire expired deferred NACKs (seqs still missing after FEC window)
                            while (!nack_fire_at_.empty() &&
                                   nack_fire_at_.begin()->first <= rx_pkt_count_) {
                                for (uint16_t s : nack_fire_at_.begin()->second) {
                                    if (fec_pending_seqs_.count(s)) {
                                        send_nack_for_gap(s, 1);
                                        fec_pending_seqs_.erase(s);
                                        append_debug("NACK(deferred) seq=" + std::to_string(s));
                                    }
                                }
                                nack_fire_at_.erase(nack_fire_at_.begin());
                            }

                            // Gap detection: enqueue missing seqs for deferred NACK
                            // (gap ≤ 2 handled by PLC; gap > 2 deferred by kFecGroupSize packets)
                            if (nack_last_seq_ >= 0) {
                                int16_t gap = (int16_t)(rtp_seq - (uint16_t)(nack_last_seq_ + 1));
                                if (gap > 2 && gap <= 32) {
                                    int32_t fire_at = rx_pkt_count_ + kFecGroupSize;
                                    for (int16_t i = 0; i < gap; i++) {
                                        uint16_t missing = (uint16_t)(nack_last_seq_ + 1 + i);
                                        fec_pending_seqs_.insert(missing);
                                        nack_fire_at_[fire_at].push_back(missing);
                                    }
                                }
                            }
                            // Advance last_seq (signed 16-bit forward comparison)
                            if (nack_last_seq_ < 0 ||
                                (int16_t)(rtp_seq - (uint16_t)nack_last_seq_) > 0)
                                nack_last_seq_ = (int32_t)rtp_seq;

                            std::lock_guard<std::mutex> lk(cb_mutex_);
                            if (rx_callback_) rx_callback_(buf, static_cast<size_t>(n));
                        }
                        // PT=126 (NACK echo) — silently drop
                    } else {
                        // Non-OSTP RTP (legacy): pass through unchanged
                        std::lock_guard<std::mutex> lk(cb_mutex_);
                        if (rx_callback_) rx_callback_(buf, static_cast<size_t>(n));
                    }
                    // P2P mesh: forward audio to swarm children
                    if (!swarm_children_.empty()) {
                        std::lock_guard<std::mutex> lk(children_mutex_);
                        for (const auto& child : swarm_children_) {
                            ::sendto(udp_sock_, buf, n, 0,
                                     (const sockaddr*)&child, sizeof(child));
                        }
                    }
                }
                // OK:joined or other control
                else {
                    recv_ctrl++;
                }
                recv_total++;
            }
            // Log stats every 5s
            auto now = std::chrono::steady_clock::now();
            if (std::chrono::duration_cast<std::chrono::seconds>(now - last_log).count() >= 5) {
                NSLog(@"[wan-relay-rx] total=%llu rtp=%llu ctrl=%llu",
                        recv_total, recv_rtp, recv_ctrl);
                std::string rx_msg = "RX: tot=" + std::to_string(recv_total) +
                             " rtp=" + std::to_string(recv_rtp) +
                             " ctrl=" + std::to_string(recv_ctrl);
                append_debug(rx_msg);
                send_debug_to_mac(rx_msg);
                last_log = now;
            }
            // Heartbeat every 5s: send both HELLO and JOIN to stay registered
            if (std::chrono::duration_cast<std::chrono::seconds>(now - last_hello).count() >= 5) {
                const char* hello = "HELLO\n";
                ::sendto(udp_sock_, hello, 6, 0,
                         (struct sockaddr*)&relay_addr_, sizeof(relay_addr_));
                // Re-send JOIN to ensure relay keeps us registered
                // (handles Fly.io anycast routing changes)
                std::string join_msg = "JOIN:" + group_ + "::" + "\n";
                ::sendto(udp_sock_, join_msg.c_str(), join_msg.size(), 0,
                         (struct sockaddr*)&relay_addr_, sizeof(relay_addr_));
                // Send clock sync ping (NTP-like, PT=125)
                send_sync_ping();
                last_hello = now;
            }
        }
    }

    void add_peer(const sockaddr_in& peer) {
        std::lock_guard<std::mutex> lk(peers_mutex_);
        for (const auto& p : peers_) {
            if (p.sin_addr.s_addr == peer.sin_addr.s_addr && p.sin_port == peer.sin_port)
                return; // already known
        }
        peers_.push_back(peer);
    }

    // ── Clock sync (NTP-like, PT=125) ──────────────────────────────────────
    /// Send a clock sync ping to the relay. Called periodically from recv_loop.
    void send_sync_ping() {
        if (udp_sock_ < 0 || state_.load() != State::Connected) return;

        uint8_t pkt[25] = {};
        pkt[0] = 0x7D;  // PT=125 sync marker

        // T1 = local CLOCK_REALTIME nanoseconds (64-bit LE)
        struct timespec now_ts;
        clock_gettime(CLOCK_REALTIME, &now_ts);
        uint64_t t1_ns = (uint64_t)now_ts.tv_sec * 1000000000ULL + (uint64_t)now_ts.tv_nsec;
        memcpy(pkt + 1, &t1_ns, 8);
        // T2, T3 zeroed — relay will fill them

        ::sendto(udp_sock_, pkt, 25, 0,
                 (struct sockaddr*)&relay_addr_, sizeof(relay_addr_));
    }

    /// Process a sync pong response (called from recv_loop when 0x7D packet arrives).
    void handle_sync_pong(const uint8_t* data, size_t len) {
        if (len < 25 || data[0] != 0x7D) return;

        // Extract T1, T2, T3 (all 64-bit LE nanoseconds)
        uint64_t t1_ns, t2_ns, t3_ns;
        memcpy(&t1_ns, data + 1, 8);
        memcpy(&t2_ns, data + 9, 8);
        memcpy(&t3_ns, data + 17, 8);

        // T4 = local receive time
        struct timespec now_ts;
        clock_gettime(CLOCK_REALTIME, &now_ts);
        uint64_t t4_ns = (uint64_t)now_ts.tv_sec * 1000000000ULL + (uint64_t)now_ts.tv_nsec;

        // Validate: T2 and T3 must be non-zero (relay filled them)
        if (t2_ns == 0 || t3_ns == 0) return;

        // NTP offset = ((T2-T1) + (T3-T4)) / 2
        int64_t offset = ((int64_t)(t2_ns - t1_ns) + (int64_t)(t3_ns - t4_ns)) / 2;
        int64_t rtt = (int64_t)(t4_ns - t1_ns) - (int64_t)(t3_ns - t2_ns);

        // Reject outliers: RTT > 500ms is unreliable
        if (rtt < 0 || rtt > 500'000'000LL) return;

        // EMA smoothing (α=0.3 for first 5 samples, then 0.1)
        int64_t prev = clock_offset_ns_.load(std::memory_order_relaxed);
        if (sync_ping_count_ < 5) {
            sync_ping_count_++;
            double alpha = 0.3;
            int64_t smoothed = (int64_t)(prev * (1.0 - alpha) + offset * alpha);
            clock_offset_ns_.store(smoothed, std::memory_order_relaxed);
        } else {
            double alpha = 0.1;
            int64_t smoothed = (int64_t)(prev * (1.0 - alpha) + offset * alpha);
            clock_offset_ns_.store(smoothed, std::memory_order_relaxed);
        }

        // First measurement: jump directly
        if (sync_ping_count_ == 1) {
            clock_offset_ns_.store(offset, std::memory_order_relaxed);
        }

        if (sync_ping_count_ <= 3) {
            NSLog(@"[clock-sync] offset=%.2fms rtt=%.2fms (#%u)",
                  offset / 1e6, rtt / 1e6, sync_ping_count_);
        }
    }

    // ── NACK: send retransmit request for missing OSTP sequences (§8.2) ─────
    // Builds PT=126 OSTP packet listing missing 16-bit seq numbers and sends
    // to relay. Relay looks up replay buffer and retransmits matching packets.
    void send_nack_for_gap(int32_t first_missing, int32_t count) {
        if (udp_sock_ < 0) return;
        int32_t n = std::min(count, (int32_t)32);
        // packet layout: RTP(12) + OSTP_ext_hdr(4) + OSTP_ext_data(8) + payload(n*2) + CRC32(4)
        const size_t body_len = 12 + 4 + 8 + (size_t)n * 2;
        uint8_t pkt[12 + 4 + 8 + 64 + 4] = {};

        // RTP header: V=2, X=1 (extension present), PT=126 (NACK)
        pkt[0] = (2 << 6) | (1 << 4);   // V=2, X=1
        pkt[1] = 126;                     // PT=NACK
        pkt[2] = 0; pkt[3] = 1;          // sequence=1
        // timestamp(4B)=0, SSRC(4B)=0 already zeroed

        // OSTP extension header: profile=0x4F53, length=2 (2×32-bit words = 8 bytes)
        pkt[12] = 0x4F; pkt[13] = 0x53;
        pkt[14] = 0x00; pkt[15] = 0x02;
        // extension data: stream_id(2B)=0, seq_ext(2B)=0, media_ts(4B)=0 already zeroed

        // Payload: missing sequence numbers (big-endian u16)
        for (int32_t i = 0; i < n; i++) {
            uint16_t seq = (uint16_t)((first_missing + i) & 0xFFFF);
            pkt[24 + i * 2]     = (seq >> 8) & 0xFF;
            pkt[24 + i * 2 + 1] = seq & 0xFF;
        }

        // CRC-32 (IEEE 802.3, little-endian) over entire packet body
        uint32_t crc = 0xFFFFFFFF;
        for (size_t i = 0; i < body_len; i++) {
            crc ^= pkt[i];
            for (int b = 0; b < 8; b++)
                crc = (crc >> 1) ^ (0xEDB88320u & -(crc & 1u));
        }
        crc = ~crc;
        std::memcpy(pkt + body_len, &crc, 4);

        ::sendto(udp_sock_, pkt, body_len + 4, 0,
                 (struct sockaddr*)&relay_addr_, sizeof(relay_addr_));
    }

    // ── FEC recovery (§8.1): XOR parity over kFecGroupSize data packets ──────
    // Called when a PT=127 FEC packet arrives. Looks up recent audio packets
    // for the group [base_seq, base_seq+kFecGroupSize-1]. If exactly one is
    // missing, reconstructs it via XOR and injects it as a synthetic packet.
    void handle_fec_packet(const uint8_t* fec_pkt, size_t fec_len) {
        if (fec_len < 29) return;  // need RTP(12) + OSTP_ext(12) + ≥1 payload byte + CRC(4)

        uint16_t base_seq = (uint16_t)((fec_pkt[2] << 8) | fec_pkt[3]);

        // Locate which seq in the group is missing and collect present payloads
        // Audio payload in OSTP starts at offset 24 (after 12 RTP + 4 ext_hdr + 8 ext_data)
        const size_t kHdrLen = 24;
        const size_t kCrcLen = 4;
        if (fec_len < kHdrLen + kCrcLen + 1) return;
        size_t fec_payload_len = fec_len - kHdrLen - kCrcLen;

        const uint8_t* fec_payload = fec_pkt + kHdrLen;

        int missing_idx = -1;
        std::vector<const uint8_t*> present_payloads;
        std::vector<size_t> present_lens;
        const uint8_t* missing_ref_pkt = nullptr;  // copy headers from this packet

        for (int i = 0; i < kFecGroupSize; i++) {
            uint16_t seq = (uint16_t)(base_seq + i);
            bool found = false;
            for (const auto& e : fec_rx_buf_) {
                if (e.seq == seq && e.pkt.size() > kHdrLen + kCrcLen) {
                    present_payloads.push_back(e.pkt.data() + kHdrLen);
                    present_lens.push_back(e.pkt.size() - kHdrLen - kCrcLen);
                    if (!missing_ref_pkt) missing_ref_pkt = e.pkt.data();
                    found = true;
                    break;
                }
            }
            if (!found) {
                if (missing_idx >= 0) return;  // more than one missing, can't recover
                missing_idx = i;
            }
        }

        if (missing_idx < 0 || !missing_ref_pkt) return;  // nothing to recover

        // Recover payload: recovered = FEC_payload XOR all_present_payloads
        std::vector<uint8_t> recovered(fec_payload_len, 0);
        for (size_t i = 0; i < fec_payload_len; i++) recovered[i] = fec_payload[i];
        for (size_t p = 0; p < present_payloads.size(); p++) {
            size_t len = std::min(present_lens[p], fec_payload_len);
            for (size_t i = 0; i < len; i++) recovered[i] ^= present_payloads[p][i];
        }

        // Build synthetic OSTP packet for the missing sequence
        uint16_t missing_seq = (uint16_t)(base_seq + missing_idx);
        std::vector<uint8_t> syn_pkt(kHdrLen + recovered.size() + kCrcLen);
        std::memcpy(syn_pkt.data(), missing_ref_pkt, kHdrLen);  // copy headers
        syn_pkt[2] = (uint8_t)(missing_seq >> 8);               // fix seq number
        syn_pkt[3] = (uint8_t)(missing_seq & 0xFF);
        std::memcpy(syn_pkt.data() + kHdrLen, recovered.data(), recovered.size());

        // CRC-32 over body (excluding CRC itself)
        uint32_t crc = 0xFFFFFFFF;
        for (size_t i = 0; i < kHdrLen + recovered.size(); i++) {
            crc ^= syn_pkt[i];
            for (int b = 0; b < 8; b++) crc = (crc >> 1) ^ (0xEDB88320u & -(crc & 1u));
        }
        crc = ~crc;
        std::memcpy(syn_pkt.data() + kHdrLen + recovered.size(), &crc, 4);

        // FEC recovery succeeded: remove from deferred NACK queue
        fec_pending_seqs_.erase(missing_seq);

        // Inject recovered packet into audio pipeline
        {
            std::lock_guard<std::mutex> lk(cb_mutex_);
            if (rx_callback_) rx_callback_(syn_pkt.data(), syn_pkt.size());
        }
        append_debug("FEC recovered seq=" + std::to_string(missing_seq));
    }

public:
    /// External IP:port as seen by relay (YOUR_ADDR response to JOIN, §6.6).
    /// Empty until the relay responds. Useful for P2P hole-punching.
    std::string external_addr() const { return external_addr_; }

private:

    std::atomic<State> state_{State::Disconnected};
    std::atomic<bool> running_{false};
    int udp_sock_ = -1;
    sockaddr_in relay_addr_{};
    std::string group_, error_, device_id_;
    std::thread recv_thread_;
    std::mutex cb_mutex_;
    RxCallback rx_callback_;
    MetaCallback meta_callback_;
    FileCallback file_callback_;
    SyncCallback sync_callback_;
    MaxDelayCallback maxdelay_callback_;
    VolumeCallback volume_callback_;
    std::mutex peers_mutex_;
    std::vector<sockaddr_in> peers_;
    std::mutex children_mutex_;
    std::vector<sockaddr_in> swarm_children_;  // P2P mesh: forward audio to these nodes
    mutable std::mutex debug_mutex_;
    std::string debug_log_;
    // Clock sync state:
    std::atomic<int64_t> clock_offset_ns_{0};  // relay_time - local_time
    uint32_t sync_ping_count_{0};
    // NACK / FEC state:
    int32_t nack_last_seq_ = -1;  // last received OSTP sequence (-1 = uninitialized)
    int32_t rx_pkt_count_  = 0;   // total audio packets received (for FEC countdown)

    // Deferred NACK: instead of NACKing immediately on gap detection, wait
    // kFecGroupSize more packets to give the FEC parity packet time to arrive.
    // fec_pending_seqs_ = seqs that are missing and awaiting FEC/NACK decision.
    // nack_fire_at_     = maps (rx_pkt_count threshold) → seqs to NACK at that point.
    std::set<uint16_t> fec_pending_seqs_;
    std::map<int32_t, std::vector<uint16_t>> nack_fire_at_;

    // YOUR_ADDR: external IP:port as seen by relay (for P2P hole-punching)
    std::string external_addr_;   // "ip:port" string, empty until first JOIN response
    // FEC receive buffer: store recent audio packets for XOR recovery (§8.1)
    static constexpr int kFecGroupSize = 5;
    static constexpr int kFecRxBufSize = 16;
    struct FecRxEntry { uint16_t seq; std::vector<uint8_t> pkt; };
    std::deque<FecRxEntry> fec_rx_buf_;  // last kFecRxBufSize data packets
};

/// Internal microphone transmitter implementation
class TransmitterImpl {
public:
    TransmitterImpl(const std::string& dest_ip, uint16_t dest_port, uint32_t channels)
        : dest_ip_(dest_ip)
        , dest_port_(dest_port)
        , channels_(channels)
        , running_(false)
        , packets_sent_(0)
        // Ring buffer: 1 second capacity, stereo int32_t
        , ring_buffer_(kDefaultSampleRate, channels * sizeof(int32_t))
        , ssrc_(arc4random())
    {}

    ~TransmitterImpl() { stop(); }

    bool start() {
        if (running_.load()) return false;

        // Open mic input
        audio_device_ = pal::AudioDevice::create();
        if (!audio_device_) return false;

        pal::AudioStreamConfig audio_cfg;
        audio_cfg.sample_rate = kDefaultSampleRate;
        audio_cfg.channels = 1;  // Mono mic
        audio_cfg.frames_per_buffer = 240;
        audio_cfg.format = SampleFormat::S24_LE;

        if (!audio_device_->open_input("", audio_cfg)) {
            fprintf(stderr, "[SolunaTx] Failed to open mic input\n");
            audio_device_.reset();
            return false;
        }

        // Create UDP socket for multicast TX
        socket_ = pal::UdpSocket::create();
        if (!socket_) {
            audio_device_.reset();
            return false;
        }

        running_.store(true);
        ring_buffer_.reset();
        packets_sent_.store(0);

        // Conversion buffer: mono float → stereo int32_t (S24)
        // Oversized to handle iOS delivering more frames than requested
        // (IOBufferDuration is just a preference; actual may be 480+ frames)
        conv_buf_.resize(4096 * channels_);

        // Start audio capture callback
        audio_device_->start([this](float* buffer, uint32_t frame_count) {
            mic_callback(buffer, frame_count);
        });

        // Start TX packet thread
        tx_thread_ = std::thread([this]() { tx_loop(); });

        return true;
    }

    void stop() {
        if (!running_.load()) return;
        running_.store(false);

        if (audio_device_) {
            audio_device_->stop();
            audio_device_->close();
            audio_device_.reset();
        }

        if (tx_thread_.joinable()) {
            tx_thread_.join();
        }

        socket_.reset();
        ring_buffer_.reset();
    }

    bool is_running() const { return running_.load(); }
    uint64_t packets_sent() const { return packets_sent_.load(); }
    float peak_level() const { return peak_level_.load(std::memory_order_relaxed); }

    /// Callback to forward TX packets to WAN relay
    std::function<void(const uint8_t*, size_t)> tx_relay_callback;

private:
    void mic_callback(float* buffer, uint32_t frame_count) {
        // Track peak level for UI meter
        float peak = 0.0f;
        for (uint32_t i = 0; i < frame_count; i++) {
            float abs_val = std::fabs(buffer[i]);
            if (abs_val > peak) peak = abs_val;
        }
        // Exponential decay: fast attack, slow release
        float prev = peak_level_.load(std::memory_order_relaxed);
        if (peak > prev) {
            peak_level_.store(peak, std::memory_order_relaxed);
        } else {
            peak_level_.store(prev * 0.85f, std::memory_order_relaxed);
        }

        // Convert mono float → stereo S24 int32_t
        size_t out_idx = 0;
        for (uint32_t i = 0; i < frame_count; i++) {
            int32_t sample = static_cast<int32_t>(buffer[i] * 8388607.0f);
            // Duplicate mono to stereo
            for (uint32_t ch = 0; ch < channels_; ch++) {
                conv_buf_[out_idx++] = sample;
            }
        }
        ring_buffer_.write(conv_buf_.data(), frame_count);
    }

    void tx_loop() {
        constexpr uint32_t kFramesPerPacket = 240;  // LAN tier: 5ms @ 48kHz
        const size_t frame_size = channels_ * sizeof(int32_t);

        transport::PacketScheduler scheduler(PacketTier::LAN, kDefaultSampleRate);
        scheduler.reset();

        std::vector<int32_t> audio_buf(kFramesPerPacket * channels_);
        std::vector<uint8_t> packet_buf(transport::kMaxPacketSize);

        pal::SocketAddress dest;
        dest.ip = dest_ip_;
        dest.port = dest_port_;

        // Send JOIN to relay so it knows about us (required for WAN relay mode)
        {
            NSString* ch = [[NSUserDefaults standardUserDefaults] stringForKey:@"channel"];
            if (!ch) ch = @"soluna";
            std::string join_msg = std::string("JOIN:") + [ch UTF8String] + "\n";
            socket_->send_to(join_msg.data(), join_msg.size(), dest);
            fprintf(stderr, "[SolunaTx] Sent JOIN:%s to %s:%u\n",
                    [ch UTF8String], dest_ip_.c_str(), dest_port_);
        }

        uint32_t sequence = 0;
        uint32_t rtp_timestamp = 0;

        while (running_.load()) {
            scheduler.wait_next();

            if (ring_buffer_.available_read() < kFramesPerPacket) {
                // Underrun: send silence
                std::memset(audio_buf.data(), 0, kFramesPerPacket * channels_ * sizeof(int32_t));
            } else {
                ring_buffer_.read(audio_buf.data(), kFramesPerPacket);
            }

            uint16_t seq_lo = static_cast<uint16_t>(sequence & 0xFFFF);
            uint16_t seq_hi = static_cast<uint16_t>((sequence >> 16) & 0xFFFF);

            size_t pkt_size = transport::ostp_build_packet(
                packet_buf.data(), packet_buf.size(),
                ssrc_, seq_lo, rtp_timestamp,
                96,  // kPayloadTypePCM24
                1,   // stream_id
                seq_hi,
                0,   // media_timestamp
                audio_buf.data(),
                kFramesPerPacket * frame_size
            );

            if (pkt_size > 0) {
                socket_->send_to(packet_buf.data(), pkt_size, dest);
                if (tx_relay_callback) {
                    tx_relay_callback(packet_buf.data(), pkt_size);
                }
                packets_sent_.fetch_add(1);
            }

            sequence++;
            rtp_timestamp += kFramesPerPacket;
        }
    }

    std::string dest_ip_;
    uint16_t dest_port_;
    uint32_t channels_;
    std::atomic<bool> running_;
    std::atomic<uint64_t> packets_sent_;
    std::atomic<float> peak_level_{0.0f};

    pipeline::RingBuffer ring_buffer_;
    uint32_t ssrc_;

    std::unique_ptr<pal::AudioDevice> audio_device_;
    std::unique_ptr<pal::UdpSocket> socket_;
    std::vector<int32_t> conv_buf_;
    std::thread tx_thread_;
};

// ============================================================================
// DJ Broadcaster — decode audio file and stream via OSTP to relay
// ============================================================================

class DJBroadcaster {
public:
    explicit DJBroadcaster(WanRelayClient* relay)
        : relay_(relay)
        , running_(false)
        , skip_flag_(false)
        , progress_(0.0f)
        , ssrc_(arc4random())
    {}

    ~DJBroadcaster() { stop_mic_capture(); stop(); }

    // ── Mic mixing ──────────────────────────────────────────────────────
    std::atomic<bool> mic_mix_enabled_{false};
    std::atomic<float> mic_gain_{1.0f};
    std::atomic<float> music_gain_{0.7f};

    void set_mic_mix(bool enabled) {
        if (enabled && !mic_queue_) {
            start_mic_capture();
        } else if (!enabled && mic_queue_) {
            stop_mic_capture();
        }
        mic_mix_enabled_ = enabled;
    }

    bool start(const std::string& filepath) {
        if (running_.load()) return false;

        filepath_ = filepath;
        skip_flag_.store(false);
        progress_.store(0.0f);

        // Extract filename from path
        auto slash = filepath_.rfind('/');
        track_name_ = (slash != std::string::npos) ? filepath_.substr(slash + 1) : filepath_;

        running_.store(true);
        broadcast_thread_ = std::thread([this]() { broadcast_loop(); });

        fprintf(stderr, "[SolunaDJ] Started broadcast: %s\n", track_name_.c_str());
        return true;
    }

    void stop() {
        if (!running_.load()) return;
        running_.store(false);
        if (broadcast_thread_.joinable()) broadcast_thread_.join();
        track_name_.clear();
        progress_.store(0.0f);
        fprintf(stderr, "[SolunaDJ] Stopped\n");
    }

    void skip() {
        skip_flag_.store(true);
    }

    bool is_running() const { return running_.load(); }
    float progress() const { return progress_.load(std::memory_order_relaxed); }
    std::string track_name() const { return track_name_; }

private:
    // ── Mic capture internals ───────────────────────────────────────────
    AudioQueueRef mic_queue_ = nullptr;
    std::vector<float> mic_ring_;  // stereo ring buffer
    std::atomic<size_t> mic_write_pos_{0};
    size_t mic_read_pos_ = 0;
    static constexpr size_t kMicRingSize = 48000;  // 1 second @ 48kHz

    void start_mic_capture() {
        @autoreleasepool {
            // Configure AVAudioSession for play+record (mic needs .playAndRecord)
            AVAudioSession* session = [AVAudioSession sharedInstance];
            NSError* err = nil;
            [session setCategory:AVAudioSessionCategoryPlayAndRecord
                     withOptions:AVAudioSessionCategoryOptionDefaultToSpeaker |
                                 AVAudioSessionCategoryOptionAllowBluetooth |
                                 AVAudioSessionCategoryOptionMixWithOthers
                           error:&err];
            if (err) {
                fprintf(stderr, "[DJ-Mic] AVAudioSession setCategory failed: %s\n",
                        err.localizedDescription.UTF8String);
            }
            [session setActive:YES error:&err];
        }

        mic_ring_.assign(kMicRingSize * 2, 0.0f);  // stereo
        mic_write_pos_.store(0, std::memory_order_relaxed);
        mic_read_pos_ = 0;

        AudioStreamBasicDescription fmt{};
        fmt.mSampleRate = 48000;
        fmt.mFormatID = kAudioFormatLinearPCM;
        fmt.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
        fmt.mBytesPerPacket = 4;
        fmt.mFramesPerPacket = 1;
        fmt.mBytesPerFrame = 4;
        fmt.mChannelsPerFrame = 1;  // mono mic
        fmt.mBitsPerChannel = 32;

        OSStatus st = AudioQueueNewInput(&fmt, mic_aq_callback, this,
                                         nullptr, nullptr, 0, &mic_queue_);
        if (st != noErr) {
            fprintf(stderr, "[DJ-Mic] AudioQueueNewInput failed: %d\n", (int)st);
            mic_queue_ = nullptr;
            return;
        }

        for (int i = 0; i < 3; i++) {
            AudioQueueBufferRef buf;
            AudioQueueAllocateBuffer(mic_queue_, 480 * 4, &buf);
            AudioQueueEnqueueBuffer(mic_queue_, buf, 0, nullptr);
        }
        st = AudioQueueStart(mic_queue_, nullptr);
        if (st != noErr) {
            fprintf(stderr, "[DJ-Mic] AudioQueueStart failed: %d\n", (int)st);
            AudioQueueDispose(mic_queue_, true);
            mic_queue_ = nullptr;
            return;
        }
        fprintf(stderr, "[DJ-Mic] Mic capture started (iOS)\n");
    }

    void stop_mic_capture() {
        if (mic_queue_) {
            AudioQueueStop(mic_queue_, true);
            AudioQueueDispose(mic_queue_, true);
            mic_queue_ = nullptr;
            fprintf(stderr, "[DJ-Mic] Mic capture stopped\n");
        }
    }

    static void mic_aq_callback(void* ctx, AudioQueueRef queue,
                                AudioQueueBufferRef buf,
                                const AudioTimeStamp*, UInt32,
                                const AudioStreamPacketDescription*) {
        auto* self = static_cast<DJBroadcaster*>(ctx);
        const float* data = (const float*)buf->mAudioData;
        size_t frames = buf->mAudioDataByteSize / sizeof(float);
        size_t wr = self->mic_write_pos_.load(std::memory_order_relaxed);
        for (size_t i = 0; i < frames; i++) {
            size_t idx = (wr + i) % self->kMicRingSize;
            self->mic_ring_[idx * 2]     = data[i];  // L = mono
            self->mic_ring_[idx * 2 + 1] = data[i];  // R = mono
        }
        self->mic_write_pos_.store(wr + frames, std::memory_order_release);
        AudioQueueEnqueueBuffer(queue, buf, 0, nullptr);
    }

    /// Mix mic samples into interleaved S24 payload buffer (in-place)
    void mix_mic_into_payload(int32_t* payload, uint32_t frames) {
        if (!mic_mix_enabled_.load(std::memory_order_relaxed)) return;

        float mg  = mic_gain_.load(std::memory_order_relaxed);
        float mug = music_gain_.load(std::memory_order_relaxed);
        size_t mic_avail = mic_write_pos_.load(std::memory_order_acquire) - mic_read_pos_;
        size_t mic_frames = std::min(mic_avail, (size_t)frames);

        for (uint32_t i = 0; i < frames; i++) {
            for (int ch = 0; ch < 2; ch++) {
                float music = (float)payload[i * 2 + ch] / 8388607.0f * mug;
                float mic = 0.0f;
                if (i < mic_frames) {
                    size_t idx = (mic_read_pos_ + i) % kMicRingSize;
                    mic = mic_ring_[idx * 2 + ch] * mg;
                }
                float mixed = music + mic;
                if (mixed > 1.0f) mixed = 1.0f;
                if (mixed < -1.0f) mixed = -1.0f;
                payload[i * 2 + ch] = (int32_t)(mixed * 8388607.0f);
            }
        }
        mic_read_pos_ += mic_frames;
    }

    void send_relay_command(const std::string& cmd) {
        if (!relay_) return;
        // Use the relay's send_audio path which forwards to relay server + peers.
        // But relay commands are text, not audio — send directly via relay's internal socket.
        // We reuse send_audio which sends to relay_addr_ and all peers.
        relay_->send_audio(reinterpret_cast<const uint8_t*>(cmd.c_str()), cmd.size());
    }

    void broadcast_loop() {
        @autoreleasepool {
            NSURL* url = [NSURL fileURLWithPath:@(filepath_.c_str())];
            NSError* err = nil;
            AVAudioFile* file = [[AVAudioFile alloc] initForReading:url error:&err];
            if (!file) {
                fprintf(stderr, "[SolunaDJ] Failed to open file: %s\n",
                        err ? err.localizedDescription.UTF8String : "unknown");
                running_.store(false);
                return;
            }

            AVAudioFormat* procFmt = [[AVAudioFormat alloc]
                initWithCommonFormat:AVAudioPCMFormatFloat32
                sampleRate:48000 channels:2 interleaved:NO];

            AVAudioFrameCount totalFrames = (AVAudioFrameCount)file.length;

            // Send FILE: and META: commands to relay
            std::string file_cmd = "FILE:" + track_name_ + "\n";
            send_relay_command(file_cmd);

            std::string meta_cmd = "META:{\"track\":\"" + track_name_ + "\",\"source\":\"dj\"}\n";
            send_relay_command(meta_cmd);

            constexpr uint32_t kFramesPerPacket = 480; // 10ms @ 48kHz
            AVAudioPCMBuffer* buf = [[AVAudioPCMBuffer alloc]
                initWithPCMFormat:procFmt frameCapacity:kFramesPerPacket];

            const size_t frame_size = 2 * sizeof(int32_t); // stereo S24
            std::vector<uint8_t> packet_buf(transport::kMaxPacketSize);
            int32_t payload[kFramesPerPacket * 2]; // stereo interleaved S24

            uint32_t sequence = 0;
            uint32_t rtp_timestamp = 0;
            AVAudioFramePosition framesRead = 0;
            bool sent_sync = false;

            auto wall_start = std::chrono::steady_clock::now();

            while (running_.load() && !skip_flag_.load()) {
                buf.frameLength = 0;
                [file readIntoBuffer:buf frameCount:kFramesPerPacket error:&err];
                if (buf.frameLength == 0) break; // EOF

                // Convert float32 to int32 S24
                const float* left = buf.floatChannelData[0];
                const float* right = buf.floatChannelData[1];
                for (uint32_t i = 0; i < buf.frameLength; i++) {
                    payload[i * 2]     = (int32_t)(left[i] * 8388607.0f);
                    payload[i * 2 + 1] = (int32_t)(right[i] * 8388607.0f);
                }

                // Mix mic audio into music if enabled
                mix_mic_into_payload(payload, buf.frameLength);

                // Build OSTP packet (same pattern as TransmitterImpl)
                uint16_t seq_lo = static_cast<uint16_t>(sequence & 0xFFFF);
                uint16_t seq_hi = static_cast<uint16_t>((sequence >> 16) & 0xFFFF);

                size_t pkt_size = transport::ostp_build_packet(
                    packet_buf.data(), packet_buf.size(),
                    ssrc_, seq_lo, rtp_timestamp,
                    96,   // kPayloadTypePCM24
                    1,    // stream_id
                    seq_hi,
                    0,    // media_timestamp
                    payload,
                    buf.frameLength * frame_size
                );

                if (pkt_size > 0 && relay_) {
                    relay_->send_audio(packet_buf.data(), pkt_size);
                }

                framesRead += buf.frameLength;
                sequence++;
                rtp_timestamp += buf.frameLength;

                // Update progress
                if (totalFrames > 0) {
                    progress_.store((float)framesRead / (float)totalFrames,
                                    std::memory_order_relaxed);
                }

                // Send SYNC: command after 3 seconds of streaming
                if (!sent_sync && framesRead >= 48000 * 3) {
                    uint64_t wall_ms = (uint64_t)std::chrono::duration_cast<
                        std::chrono::milliseconds>(
                            std::chrono::system_clock::now().time_since_epoch()).count();
                    uint64_t pos_ms = (uint64_t)framesRead * 1000 / 48000;
                    std::string sync_cmd = "SYNC:play:" + std::to_string(pos_ms)
                                         + ":" + std::to_string(wall_ms) + "\n";
                    send_relay_command(sync_cmd);
                    sent_sync = true;
                }

                // Pace to real-time: sleep until next packet time
                auto next_time = wall_start + std::chrono::microseconds(
                    (uint64_t)framesRead * 1000000 / 48000);
                std::this_thread::sleep_until(next_time);
            }

            progress_.store(1.0f, std::memory_order_relaxed);
            running_.store(false);
            fprintf(stderr, "[SolunaDJ] Broadcast finished: %s (frames=%lld)\n",
                    track_name_.c_str(), (long long)framesRead);
        }
    }

    WanRelayClient* relay_;  // borrowed, owned by ReceiverImpl
    std::atomic<bool> running_;
    std::atomic<bool> skip_flag_;
    std::atomic<float> progress_;
    uint32_t ssrc_;
    std::string filepath_;
    std::string track_name_;
    std::thread broadcast_thread_;
};

// ── DJController — dual-deck with equal-power crossfader ──────────────────
class DJController {
public:
    explicit DJController(WanRelayClient* relay)
        : relay_(relay), crossfader_(0.5f), running_(false)
        , ssrc_(arc4random())
        , seq_(0), timestamp_(0)
    {}
    ~DJController() { stop(); }

    struct Deck {
        std::string filepath;
        std::string track_name;
        std::atomic<float> progress{0.0f};
        std::atomic<bool> playing{false};
        std::atomic<bool> pause{false};

        // Audio file reading state (using ExtAudioFile)
        ExtAudioFileRef ext_file = nullptr;
        int64_t total_frames = 0;
        int64_t played_frames = 0;

        bool open(const std::string& path) {
            CFURLRef url = CFURLCreateFromFileSystemRepresentation(
                nullptr, (const UInt8*)path.c_str(), path.size(), false);
            OSStatus err = ExtAudioFileOpenURL(url, &ext_file);
            CFRelease(url);
            if (err != noErr || !ext_file) return false;

            // Tell ExtAudioFile to convert to float32 stereo 48kHz
            AudioStreamBasicDescription out_fmt{};
            out_fmt.mSampleRate = 48000;
            out_fmt.mFormatID = kAudioFormatLinearPCM;
            out_fmt.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
            out_fmt.mBytesPerPacket = 8;
            out_fmt.mFramesPerPacket = 1;
            out_fmt.mBytesPerFrame = 8;
            out_fmt.mChannelsPerFrame = 2;
            out_fmt.mBitsPerChannel = 32;
            ExtAudioFileSetProperty(ext_file, kExtAudioFileProperty_ClientDataFormat,
                                    sizeof(out_fmt), &out_fmt);

            int64_t file_frames = 0;
            UInt32 prop_size = sizeof(file_frames);
            ExtAudioFileGetProperty(ext_file, kExtAudioFileProperty_FileLengthFrames,
                                    &prop_size, &file_frames);
            total_frames = file_frames;
            played_frames = 0;
            return true;
        }

        // Read `frame_count` float stereo frames into `buf`. Returns actual frames read.
        int64_t read_frames(float* buf, int64_t frame_count) {
            if (!ext_file || pause.load()) return 0;
            AudioBufferList abl{};
            abl.mNumberBuffers = 1;
            abl.mBuffers[0].mNumberChannels = 2;
            abl.mBuffers[0].mDataByteSize = (UInt32)(frame_count * 8);
            abl.mBuffers[0].mData = buf;
            UInt32 frames = (UInt32)frame_count;
            ExtAudioFileRead(ext_file, &frames, &abl);
            played_frames += frames;
            if (total_frames > 0) {
                progress.store((float)played_frames / (float)total_frames,
                               std::memory_order_relaxed);
            }
            return frames;
        }

        bool is_done() const {
            return total_frames > 0 && played_frames >= total_frames;
        }

        void close() {
            if (ext_file) { ExtAudioFileDispose(ext_file); ext_file = nullptr; }
            playing.store(false);
        }
    };

    bool start_deck_a(const std::string& path) {
        deck_a_.close();
        if (!deck_a_.open(path)) return false;
        auto slash = path.rfind('/');
        deck_a_.track_name = (slash != std::string::npos) ? path.substr(slash+1) : path;
        deck_a_.playing.store(true);
        deck_a_.pause.store(false);
        if (!running_.load()) start_mix_thread();
        return true;
    }

    bool start_deck_b(const std::string& path) {
        deck_b_.close();
        if (!deck_b_.open(path)) return false;
        auto slash = path.rfind('/');
        deck_b_.track_name = (slash != std::string::npos) ? path.substr(slash+1) : path;
        deck_b_.playing.store(true);
        deck_b_.pause.store(false);
        if (!running_.load()) start_mix_thread();
        return true;
    }

    void toggle_deck_a() { deck_a_.pause.store(!deck_a_.pause.load()); }
    void toggle_deck_b() { deck_b_.pause.store(!deck_b_.pause.load()); }

    void set_crossfader(float v) { crossfader_.store(std::max(0.f, std::min(1.f, v))); }
    float get_crossfader() const { return crossfader_.load(); }

    float deck_a_progress() const { return deck_a_.progress.load(); }
    float deck_b_progress() const { return deck_b_.progress.load(); }
    bool deck_a_playing() const { return deck_a_.playing.load() && !deck_a_.pause.load(); }
    bool deck_b_playing() const { return deck_b_.playing.load() && !deck_b_.pause.load(); }
    std::string deck_a_track() const { return deck_a_.track_name; }
    std::string deck_b_track() const { return deck_b_.track_name; }
    bool is_active() const { return running_.load(); }

    void stop() {
        running_.store(false);
        if (mix_thread_.joinable()) mix_thread_.join();
        deck_a_.close();
        deck_b_.close();
    }

private:
    WanRelayClient* relay_;
    std::atomic<float> crossfader_;
    std::atomic<bool> running_;
    uint32_t ssrc_, seq_;
    uint32_t timestamp_;
    Deck deck_a_, deck_b_;
    std::thread mix_thread_;

    void start_mix_thread() {
        running_.store(true);
        mix_thread_ = std::thread([this]() { mix_loop(); });
    }

    void mix_loop() {
        static constexpr int kFrames = 960; // 20ms at 48kHz
        static constexpr int kCh = 2;
        static constexpr double kInterval = (double)kFrames / 48000.0;

        std::vector<float> buf_a(kFrames * kCh, 0.f);
        std::vector<float> buf_b(kFrames * kCh, 0.f);
        std::vector<int16_t> mix_out(kFrames * kCh, 0);

        auto next_time = std::chrono::steady_clock::now();

        while (running_.load()) {
            next_time += std::chrono::duration_cast<std::chrono::steady_clock::duration>(std::chrono::duration<double>(kInterval));

            // Read from both decks
            std::fill(buf_a.begin(), buf_a.end(), 0.f);
            std::fill(buf_b.begin(), buf_b.end(), 0.f);

            if (deck_a_.playing.load()) {
                deck_a_.read_frames(buf_a.data(), kFrames);
                if (deck_a_.is_done()) { deck_a_.close(); }
            }
            if (deck_b_.playing.load()) {
                deck_b_.read_frames(buf_b.data(), kFrames);
                if (deck_b_.is_done()) { deck_b_.close(); }
            }

            // Equal-power crossfade
            float cf = crossfader_.load();
            float gain_a = cosf(cf * (float)M_PI_2);
            float gain_b = sinf(cf * (float)M_PI_2);

            // Mix and convert to int16
            for (int i = 0; i < kFrames * kCh; i++) {
                float s = buf_a[i] * gain_a + buf_b[i] * gain_b;
                s = std::max(-1.f, std::min(1.f, s));
                mix_out[i] = (int16_t)(s * 32767.f);
            }

            // Build OSTP packet and send
            if (deck_a_.playing.load() || deck_b_.playing.load()) {
                send_ostp(mix_out.data(), kFrames * kCh);
            }

            // Sleep until next frame boundary
            std::this_thread::sleep_until(next_time);
        }
    }

    void send_ostp(const int16_t* pcm, int sample_count) {
        if (!relay_) return;

        const int kHeaderSize = 24; // RTP(12) + RTP-ext header(4) + OSTP ext(8)
        const int payload_bytes = sample_count * (int)sizeof(int16_t);
        const int total = kHeaderSize + payload_bytes + 4; // +4 for CRC

        std::vector<uint8_t> pkt(total, 0);

        // RTP header
        pkt[0] = 0x90; // V=2, X=1
        pkt[1] = 96;   // PT=96 (PCM dynamic)
        pkt[2] = (seq_ >> 8) & 0xFF;
        pkt[3] = seq_ & 0xFF;
        pkt[4] = (timestamp_ >> 24) & 0xFF;
        pkt[5] = (timestamp_ >> 16) & 0xFF;
        pkt[6] = (timestamp_ >> 8)  & 0xFF;
        pkt[7] =  timestamp_ & 0xFF;
        pkt[8]  = (ssrc_ >> 24) & 0xFF;
        pkt[9]  = (ssrc_ >> 16) & 0xFF;
        pkt[10] = (ssrc_ >> 8)  & 0xFF;
        pkt[11] =  ssrc_ & 0xFF;

        // RTP extension: OSTP profile 'OS'
        pkt[12] = 0x4F; pkt[13] = 0x53; // profile
        pkt[14] = 0x00; pkt[15] = 0x02; // length=2 (8 bytes)

        // OSTP ext: stream_id=0x0200 (deck=0, ch=2 stereo), seq_ext, media_ts
        pkt[16] = 0x02; pkt[17] = 0x00; // stream_id
        pkt[18] = 0x00; pkt[19] = 0x00; // seq_ext
        pkt[20] = (timestamp_ >> 24) & 0xFF;
        pkt[21] = (timestamp_ >> 16) & 0xFF;
        pkt[22] = (timestamp_ >> 8)  & 0xFF;
        pkt[23] =  timestamp_ & 0xFF;

        // PCM payload
        memcpy(pkt.data() + 24, pcm, payload_bytes);

        // CRC-32
        uint32_t crc = 0xFFFFFFFF;
        for (int i = 0; i < 24 + payload_bytes; i++) {
            crc ^= pkt[i];
            for (int j = 0; j < 8; j++) crc = (crc >> 1) ^ (crc & 1 ? 0xEDB88320u : 0u);
        }
        crc = ~crc;
        pkt[24 + payload_bytes + 0] = (crc >> 24) & 0xFF;
        pkt[24 + payload_bytes + 1] = (crc >> 16) & 0xFF;
        pkt[24 + payload_bytes + 2] = (crc >> 8)  & 0xFF;
        pkt[24 + payload_bytes + 3] =  crc & 0xFF;

        seq_++;
        timestamp_ += 960;

        relay_->send_audio(pkt.data(), pkt.size());
    }
};

// ── Multi-source audio mixer ────────────────────────────────────────────────
// Maintains per-SSRC ring buffers and mixes them into a single output buffer.
// Used when talk_mode is active to support multiple simultaneous speakers.
class MultiSourceMixer {
public:
    static constexpr size_t kMaxSources = 64;
    static constexpr size_t kRingFrames = 48000;  // 1 second at 48kHz
    static constexpr size_t kMaxChannels = 8;
    static constexpr size_t kTimeoutMs = 5000;    // Remove inactive sources after 5s
    static constexpr size_t kTopN = 8;            // Mix only the loudest N speakers
    static constexpr float  kVadThreshold = 200.0f;  // RMS threshold for voice activity (int32 scale)
    static constexpr float  kAgcTarget = 0.25f;   // Target RMS level (normalized to INT32_MAX)
    static constexpr float  kAgcAttack = 0.01f;   // AGC gain smoothing (fast attack)
    static constexpr float  kAgcRelease = 0.001f; // AGC gain smoothing (slow release)
    static constexpr float  kFadeInRate = 0.02f;  // Smooth fade-in per frame when becoming active
    static constexpr float  kFadeOutRate = 0.005f; // Smooth fade-out per frame when muted

    struct Source {
        uint32_t ssrc = 0;
        std::vector<int32_t> ring;
        size_t write_pos = 0;
        size_t read_pos = 0;
        uint32_t channels = 2;
        std::chrono::steady_clock::time_point last_seen;
        bool active = false;

        // VAD: energy-based voice activity detection
        float rms_energy = 0.0f;      // Smoothed RMS energy (EMA)
        bool  voice_active = false;    // Currently speaking?

        // AGC: per-source automatic gain control
        float agc_gain = 1.0f;        // Current gain multiplier

        // Spatial panning: position in stereo field (-1.0 = full left, +1.0 = full right)
        float pan = 0.0f;             // Assigned on creation, spread evenly
        float pan_gain_l = 1.0f;
        float pan_gain_r = 1.0f;

        // Smooth fade for mute/unmute transitions
        float fade = 0.0f;            // 0.0 = silent, 1.0 = full volume

        // Source index (for deterministic pan assignment)
        uint32_t slot_index = 0;
    };

    MultiSourceMixer() {
        for (size_t i = 0; i < kMaxSources; i++) {
            sources_[i].ring.resize(kRingFrames * 2, 0);  // Stereo by default
            sources_[i].slot_index = static_cast<uint32_t>(i);
        }
    }

    // Write decoded PCM from a specific SSRC into its ring buffer
    void write(uint32_t ssrc, const int32_t* data, size_t frames, uint32_t channels) {
        auto* src = find_or_create(ssrc, channels);
        if (!src) return;
        src->last_seen = std::chrono::steady_clock::now();
        src->channels = channels;

        // Resize ring if channel count changed
        size_t needed = kRingFrames * channels;
        if (src->ring.size() != needed) {
            src->ring.resize(needed, 0);
            src->write_pos = 0;
            src->read_pos = 0;
        }

        // Update RMS energy for VAD (exponential moving average)
        double sum_sq = 0.0;
        size_t samples = frames * channels;
        for (size_t i = 0; i < samples; i++) {
            double s = static_cast<double>(data[i]);
            sum_sq += s * s;
        }
        float frame_rms = static_cast<float>(std::sqrt(sum_sq / std::max(samples, size_t(1))));
        src->rms_energy = src->rms_energy * 0.85f + frame_rms * 0.15f;  // EMA α=0.15
        src->voice_active = (src->rms_energy > kVadThreshold);

        // AGC: adjust gain toward target level
        if (src->voice_active && frame_rms > 0.0f) {
            float target_rms = kAgcTarget * static_cast<float>(INT32_MAX);
            float desired_gain = target_rms / frame_rms;
            desired_gain = std::max(0.1f, std::min(4.0f, desired_gain));  // Clamp gain range
            float alpha = (desired_gain < src->agc_gain) ? kAgcAttack : kAgcRelease;
            src->agc_gain = src->agc_gain * (1.0f - alpha) + desired_gain * alpha;
        }

        // Write to ring buffer
        for (size_t i = 0; i < samples; i++) {
            src->ring[(src->write_pos + i) % src->ring.size()] = data[i];
        }
        src->write_pos = (src->write_pos + samples) % src->ring.size();
    }

    // Read mixed audio from active sources with VAD + Top-N + spatial panning + AGC
    size_t read_mixed(int32_t* output, size_t frames, uint32_t out_channels) {
        size_t total_samples = frames * out_channels;
        std::memset(output, 0, total_samples * sizeof(int32_t));

        auto now = std::chrono::steady_clock::now();

        // Step 1: Collect active sources and sort by energy (Top-N selection)
        struct Candidate { Source* src; float energy; size_t avail; };
        std::vector<Candidate> candidates;
        candidates.reserve(kMaxSources);

        for (auto& src : sources_) {
            if (!src.active) continue;
            auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(now - src.last_seen).count();
            if (elapsed > static_cast<long long>(kTimeoutMs)) {
                src.active = false;
                src.fade = 0.0f;
                continue;
            }

            size_t src_samples = frames * src.channels;
            size_t avail = (src.write_pos >= src.read_pos)
                ? (src.write_pos - src.read_pos)
                : (src.ring.size() - src.read_pos + src.write_pos);
            if (avail < src_samples) continue;

            candidates.push_back({&src, src.rms_energy, avail});
        }

        // Sort by energy descending — loudest speakers first
        std::sort(candidates.begin(), candidates.end(),
                  [](const Candidate& a, const Candidate& b) { return a.energy > b.energy; });

        // Step 2: Mix Top-N sources with VAD gating, AGC, and spatial panning
        size_t mixed_count = 0;
        for (size_t ci = 0; ci < candidates.size(); ci++) {
            auto* src = candidates[ci].src;
            bool should_mix = (ci < kTopN) && src->voice_active;

            // Smooth fade in/out
            float target_fade = should_mix ? 1.0f : 0.0f;
            // Process per-frame for smooth transitions

            size_t src_samples = frames * src->channels;
            float gain = src->agc_gain;
            float pan_l = src->pan_gain_l;
            float pan_r = src->pan_gain_r;

            for (size_t f = 0; f < frames; f++) {
                // Update fade
                if (src->fade < target_fade) {
                    src->fade = std::min(src->fade + kFadeInRate, 1.0f);
                } else if (src->fade > target_fade) {
                    src->fade = std::max(src->fade - kFadeOutRate, 0.0f);
                }

                if (src->fade < 0.001f) continue;  // Skip if fully faded out

                float frame_gain = gain * src->fade;

                if (out_channels >= 2) {
                    // Stereo output with spatial panning
                    int32_t src_l = 0, src_r = 0;
                    size_t base = (src->read_pos + f * src->channels) % src->ring.size();
                    src_l = src->ring[base];
                    if (src->channels >= 2) {
                        src_r = src->ring[(base + 1) % src->ring.size()];
                    } else {
                        src_r = src_l;  // Mono source → duplicate
                    }

                    int64_t out_l = (int64_t)output[f * out_channels + 0]
                                  + (int64_t)(src_l * frame_gain * pan_l);
                    int64_t out_r = (int64_t)output[f * out_channels + 1]
                                  + (int64_t)(src_r * frame_gain * pan_r);
                    output[f * out_channels + 0] = (int32_t)std::clamp(out_l, (int64_t)INT32_MIN, (int64_t)INT32_MAX);
                    output[f * out_channels + 1] = (int32_t)std::clamp(out_r, (int64_t)INT32_MIN, (int64_t)INT32_MAX);
                } else {
                    // Mono output
                    size_t base = (src->read_pos + f * src->channels) % src->ring.size();
                    int32_t sample = src->ring[base];
                    if (src->channels >= 2) {
                        sample = (int32_t)(((int64_t)sample + src->ring[(base + 1) % src->ring.size()]) / 2);
                    }
                    int64_t out_m = (int64_t)output[f] + (int64_t)(sample * frame_gain);
                    output[f] = (int32_t)std::clamp(out_m, (int64_t)INT32_MIN, (int64_t)INT32_MAX);
                }
            }

            src->read_pos = (src->read_pos + src_samples) % src->ring.size();
            if (src->fade > 0.001f) mixed_count++;
        }

        return (mixed_count > 0) ? frames : 0;
    }

    size_t active_source_count() const {
        size_t count = 0;
        for (const auto& s : sources_) if (s.active) count++;
        return count;
    }

    size_t speaking_count() const {
        size_t count = 0;
        for (const auto& s : sources_) if (s.active && s.voice_active) count++;
        return count;
    }

    bool has_data(size_t frames, uint32_t channels) const {
        for (const auto& src : sources_) {
            if (!src.active) continue;
            size_t src_samples = frames * src.channels;
            size_t avail = (src.write_pos >= src.read_pos)
                ? (src.write_pos - src.read_pos)
                : (src.ring.size() - src.read_pos + src.write_pos);
            if (avail >= src_samples) return true;
        }
        return false;
    }

private:
    Source* find_or_create(uint32_t ssrc, uint32_t channels) {
        // Find existing
        for (auto& s : sources_) {
            if (s.active && s.ssrc == ssrc) return &s;
        }
        // Find empty slot
        for (size_t i = 0; i < kMaxSources; i++) {
            if (!sources_[i].active) {
                auto& s = sources_[i];
                s.ssrc = ssrc;
                s.channels = channels;
                s.write_pos = 0;
                s.read_pos = 0;
                s.active = true;
                s.voice_active = false;
                s.rms_energy = 0.0f;
                s.agc_gain = 1.0f;
                s.fade = 0.0f;
                s.last_seen = std::chrono::steady_clock::now();
                // Assign spatial pan position: spread evenly across stereo field
                assign_pan(s);
                std::memset(s.ring.data(), 0, s.ring.size() * sizeof(int32_t));
                return &s;
            }
        }
        // All slots full, evict the oldest inactive source
        Source* oldest = nullptr;
        for (auto& s : sources_) {
            if (!s.voice_active && (!oldest || s.last_seen < oldest->last_seen)) {
                oldest = &s;
            }
        }
        if (!oldest) oldest = &sources_[0];  // Fallback: evict first
        oldest->ssrc = ssrc;
        oldest->channels = channels;
        oldest->write_pos = 0;
        oldest->read_pos = 0;
        oldest->active = true;
        oldest->voice_active = false;
        oldest->rms_energy = 0.0f;
        oldest->agc_gain = 1.0f;
        oldest->fade = 0.0f;
        oldest->last_seen = std::chrono::steady_clock::now();
        assign_pan(*oldest);
        std::memset(oldest->ring.data(), 0, oldest->ring.size() * sizeof(int32_t));
        return oldest;
    }

    // Assign stereo pan position based on slot index
    // Spreads sources across the stereo field: center, left, right, ...
    void assign_pan(Source& s) {
        // Pattern: 0=center, 1=left30%, 2=right30%, 3=left60%, 4=right60%, ...
        uint32_t idx = s.slot_index;
        if (idx == 0) {
            s.pan = 0.0f;
        } else {
            float spread = 0.3f * ((idx + 1) / 2);  // 0.3, 0.3, 0.6, 0.6, 0.9, 0.9, ...
            spread = std::min(spread, 0.9f);
            s.pan = (idx % 2 == 1) ? -spread : spread;
        }
        // Equal-power panning (constant-power law)
        float angle = (s.pan + 1.0f) * 0.5f;  // 0.0 (left) to 1.0 (right)
        s.pan_gain_l = std::cos(angle * static_cast<float>(M_PI) * 0.5f);
        s.pan_gain_r = std::sin(angle * static_cast<float>(M_PI) * 0.5f);
    }

    std::array<Source, kMaxSources> sources_;
};

/// Internal receiver implementation
class ReceiverImpl {
public:
    static constexpr uint32_t kMaxRxChannels = 8;  // Support up to 7.1ch

    ReceiverImpl(const std::string& multicast_group, uint16_t port, uint32_t channels)
        : multicast_group_(multicast_group)
        , port_(port)
        , channels_(channels)      // Output channels: 1=mono (downmix), 2=stereo
        , volume_(1.0f)
        , muted_(false)
        , running_(false)
        , target_fill_frames_(1440)  // 30ms initial
        , ring_buffer_(192000, kMaxRxChannels * sizeof(int32_t)) // 4s capacity, max channels
        , read_buffer_(4096 * kMaxRxChannels)
        , drain_buf_(4096 * kMaxRxChannels)
        , held_sample_(kMaxRxChannels, 0)
        , ramp_(0.0f)
    {}

    ~ReceiverImpl() {
        stop();
    }

    bool start() {
        if (running_.load()) return false;

        // Create RTP receiver — channel count auto-detected from OSTP stream_id
        SimpleRtpReceiver::Config rx_config;
        rx_config.listen_port = port_;
        rx_config.multicast_group = multicast_group_;
        rx_config.channels = kMaxRxChannels;  // Max capacity; actual count detected per-packet
        rx_config.format = SampleFormat::S24_LE;
        rx_config.mode = ReceiveMode::Auto;

        rtp_receiver_ = std::make_unique<SimpleRtpReceiver>(rx_config);
        if (!rtp_receiver_->init()) {
            // Multicast socket init failed (sandbox, port conflict, or no network).
            // Continue in relay-only mode — audio arrives via inject_raw_packet.
            fprintf(stderr, "[SolunaRx] Multicast init failed — relay-only mode\n");
            relay_network_disabled_.store(true);
        }

        // Wire up NTP sync: receiver adjusts target_fill_frames_ based on media_timestamp
        rtp_receiver_->sync_target_frames_ = &target_fill_frames_;
        rtp_receiver_->sync_playout_delay_ms_ = 80.0;

        // Wire up multi-source mixer callback (feeds decoded PCM per-SSRC)
        rtp_receiver_->on_decoded = [this](uint32_t ssrc, const int32_t* data, size_t frames, uint32_t channels) {
            if (talk_mode_active_.load(std::memory_order_relaxed)) {
                multi_mixer_.write(ssrc, data, frames, channels);
            }
        };

        // Create audio output device
        audio_device_ = pal::AudioDevice::create();
        if (!audio_device_) {
            return false;
        }

        pal::AudioStreamConfig audio_config;
        audio_config.sample_rate = kDefaultSampleRate;
        audio_config.channels = channels_;  // Output: user's choice (1=mono, 2=stereo)
        audio_config.frames_per_buffer = 512;
        audio_config.format = SampleFormat::S24_LE;

        if (!audio_device_->open_output("default", audio_config)) {
            return false;
        }

        running_.store(true);

        // Start audio playback FIRST so the render callback is active before data arrives
        auto callback = [this](float* buffer, uint32_t frame_count) {
            audio_callback(buffer, frame_count);
        };

        if (!audio_device_->start(callback)) {
            fprintf(stderr, "[SolunaRx] Failed to start audio device\n");
            running_.store(false);
            return false;
        }

        // Flush ALL stale packets from the UDP socket buffer.
        if (rtp_receiver_) {
            pipeline::RingBuffer discard_buf(65536, channels_ * sizeof(int32_t));
            int flushed = 0;
            for (int i = 0; i < 100000; i++) {
                if (!rtp_receiver_->receive_packet(discard_buf)) break;
                flushed++;
                if (discard_buf.available_write() < 1024) discard_buf.reset();
            }
            if (flushed > 0) {
                fprintf(stderr, "[SolunaRx] Flushed %d stale packets from socket\n", flushed);
            }
        }

        // Reset ring buffer and state for a clean start
        ring_buffer_.reset();
        prefilled_ = false;
        ramp_ = 0.0f;

        // NOW start the receive thread with a clean slate
        receive_thread_ = std::thread([this]() {
            receive_loop();
        });

        // Start WebSocket control server on port 8400
        ws_server_.set_web_files(
            reinterpret_cast<const soluna::control::WebFile*>(embedded_web_files),
            embedded_web_file_count);
        ws_server_.set_message_callback([this](const std::string& msg) -> std::string {
            return handle_ws_command(msg);
        });
        ws_server_.start(8400);

        return true;
    }

    void stop() {
        if (!running_.load()) return;

        wan_relay_disconnect();
        running_.store(false);

        if (audio_device_) {
            audio_device_->stop();
            audio_device_->close();
        }

        if (receive_thread_.joinable()) {
            receive_thread_.join();
        }

        rtp_receiver_.reset();
        audio_device_.reset();
        ring_buffer_.reset();
    }

    bool is_running() const {
        return running_.load();
    }

    void set_volume(float volume) {
        volume_.store(std::max(0.0f, std::min(1.0f, volume)));
    }

    float volume() const { return volume_.load(); }

    void set_muted(bool muted) { muted_.store(muted); }
    bool is_muted() const { return muted_.load(); }

    void set_buffer_ms(uint32_t ms) {
        ms = std::max(5u, std::min(2000u, ms));
        target_fill_frames_.store(ms * 48u);
    }
    uint32_t buffer_ms() const { return target_fill_frames_.load() / 48u; }

    // ── Sync mode ──────────────────────────────────────────────────────────
    void set_sync_mode(bool enabled) {
        sync_mode_.store(enabled);
        if (enabled) {
            target_fill_frames_.store(sync_delay_ms_.load() * 48u);
            sync_samples_count_ = 0;  // Reset for fast convergence on new session
            sync_delay_idx_ = 0;
        }
    }
    bool is_sync_mode() const { return sync_mode_.load(); }

    void set_sync_delay_ms(uint32_t ms) {
        ms = std::max(50u, std::min(1000u, ms));
        sync_delay_ms_.store(ms);
        if (sync_mode_.load()) {
            target_fill_frames_.store(ms * 48u);
        }
    }
    uint32_t get_sync_delay_ms() const { return sync_delay_ms_.load(); }

    // ── Output latency compensation (Bluetooth/AirPlay) ─────────────────
    void set_output_latency_ms(float ms) { output_latency_ms_.store(std::max(0.0f, ms)); }
    float get_output_latency_ms() const { return output_latency_ms_.load(); }

    // ── Loudness normalization (EBU R128) ─────────────────────────────────
    void set_loudness_norm(bool enabled) { loudness_norm_enabled_.store(enabled); }
    bool is_loudness_norm() const { return loudness_norm_enabled_.load(); }

    // ── Talk mode (multi-speaker) ──────────────────────────────────────────
    void set_talk_mode(bool enabled) { talk_mode_active_.store(enabled, std::memory_order_relaxed); }
    bool is_talk_mode() const { return talk_mode_active_.load(std::memory_order_relaxed); }

    // ── 3-Band EQ ─────────────────────────────────────────────────────────
    void set_eq(int band, float gain_db) {
        if (band >= 0 && band < 3) {
            eq_.gains[band].store(std::clamp(gain_db, -12.0f, 12.0f));
            eq_.update_coeffs();
        }
    }

    // ── Compressor ────────────────────────────────────────────────────────
    void set_compressor(float thresh, float rat, float att, float rel, bool en) {
        compressor_.threshold.store(std::clamp(thresh, -60.0f, 0.0f));
        compressor_.ratio.store(std::clamp(rat, 1.0f, 20.0f));
        compressor_.attack_ms.store(std::clamp(att, 0.1f, 100.0f));
        compressor_.release_ms.store(std::clamp(rel, 10.0f, 1000.0f));
        compressor_.enabled.store(en);
    }

    // ── Recording ─────────────────────────────────────────────────────────
    void set_record_callback(std::function<void(const float*, uint32_t)> cb) {
        std::lock_guard<std::mutex> lock(record_mutex_);
        record_callback_ = std::move(cb);
    }

    // ── Sample Tap (for fingerprinting) ──────────────────────────────────
    void set_sample_tap_callback(std::function<void(const float*, uint32_t, uint32_t)> cb) {
        std::lock_guard<std::mutex> lock(sample_tap_mutex_);
        sample_tap_callback_ = std::move(cb);
    }

    SimpleRtpReceiver::Stats stats() const {
        if (rtp_receiver_) return rtp_receiver_->stats_snapshot();
        return {};
    }

    int device_health() const {
        return health_.load(std::memory_order_relaxed);
    }

    void set_filesync_network_disabled(bool d) { filesync_network_disabled_.store(d); }
    bool is_filesync_network_disabled() const { return filesync_network_disabled_.load(); }
    bool is_network_disabled() const { return relay_network_disabled_.load() || filesync_network_disabled_.load(); }

    // ── Relay support ──────────────────────────────────────────────────────

    void set_relay_callback(std::function<void(const uint8_t*, size_t)> cb) {
        relay_callback_ = std::move(cb);
        if (rtp_receiver_) rtp_receiver_->relay_callback = relay_callback_;
    }

    void inject_raw_packet(const uint8_t* data, size_t len) {
        if (!rtp_receiver_) return;
        // When FileSync is active, skip PCM stream injection to avoid mixing
        if (filesync_network_disabled_.load(std::memory_order_relaxed)) return;
        // On first relay packet: flush stale data & set reasonable buffer
        if (!relay_first_packet_received_.load(std::memory_order_relaxed)) {
            relay_first_packet_received_.store(true, std::memory_order_relaxed);
            flush_requested_.store(true, std::memory_order_release);
            target_fill_frames_.store(24000, std::memory_order_relaxed);  // 500ms — WAN jitter cushion (EU→JP ~250ms RTT)
            health_.store(0, std::memory_order_relaxed);
            health_silenced_.store(false, std::memory_order_relaxed);
            health_window_start_ms_ = 0;
            health_underruns_in_window_ = 0;
            last_underrun_ms_ = 0;
            NSLog(@"[relay] First packet — buffer flushed, target=24000 (500ms)");
        }
        relay_inject_count_++;
        rtp_receiver_->inject_raw_packet(data, len, ring_buffer_);

        // ── RTCP jitter feedback: RFC 3550 §6.4.1 inter-arrival jitter ──────────
        // D(i,j) = |(Rj-Ri) - (Sj-Si)|  where R=arrival_ms, S=rtp_ts_ms
        // J(i) = J(i-1) + (D(i,j) - J(i-1)) / 16
        if (len >= 8 && (data[0] & 0xC0) == 0x80) {
            uint32_t rtp_ts;
            std::memcpy(&rtp_ts, data + 4, 4);
            rtp_ts = ntohl(rtp_ts);

            struct timespec now_ts;
            clock_gettime(CLOCK_REALTIME, &now_ts);
            uint64_t now_ns = static_cast<uint64_t>(now_ts.tv_sec) * 1'000'000'000ULL + now_ts.tv_nsec;

            if (ia_last_arrival_ns_ != 0 && ia_last_rtp_ts_ != 0) {
                double arrival_diff_ms = static_cast<double>(now_ns - ia_last_arrival_ns_) / 1'000'000.0;
                double rtp_diff_ms = static_cast<double>(static_cast<int32_t>(rtp_ts - ia_last_rtp_ts_)) / 48.0; // @48kHz
                double d = std::abs(arrival_diff_ms - rtp_diff_ms);
                ia_jitter_ema_ms_ += (d - ia_jitter_ema_ms_) / 16.0;
            }
            ia_last_arrival_ns_ = now_ns;
            ia_last_rtp_ts_ = rtp_ts;
        }

        // Propagate detected TX channel count from receiver to audio callback
        uint32_t rx_tx_ch = rtp_receiver_->detected_tx_channels_.load(std::memory_order_relaxed);
        if (rx_tx_ch > 0) {
            detected_tx_channels_.store(rx_tx_ch, std::memory_order_relaxed);
        }

        // Periodic stats log (every ~5 seconds at 500pps)
        if (relay_inject_count_ % 2500 == 0) {
            auto st = rtp_receiver_->stats();
            size_t fill = ring_buffer_.available_read();
            uint32_t tx_ch = detected_tx_channels_.load(std::memory_order_relaxed);
            NSLog(@"[relay] pkts=%llu ostp=%llu seq_err=%llu fill=%zu target=%u tx_ch=%u jitter=%.1fms",
                  (unsigned long long)st.packets_received,
                  (unsigned long long)st.ostp_packets,
                  (unsigned long long)st.sequence_errors,
                  fill, target_fill_frames_.load(), tx_ch,
                  ia_jitter_ema_ms_);

            // RTCP jitter → jitter buffer target (OSTP v0.9.3 §6)
            // Only apply in non-sync mode (sync mode uses media_timestamp instead)
            if (!sync_mode_.load(std::memory_order_relaxed) && ia_jitter_ema_ms_ > 1.0) {
                // RFC 3550 recommendation: buffer = 4× jitter, clamped to [30ms, 500ms]
                double jitter_target_ms = ia_jitter_ema_ms_ * 4.0;
                if (jitter_target_ms < 30.0)  jitter_target_ms = 30.0;
                if (jitter_target_ms > 500.0) jitter_target_ms = 500.0;
                uint32_t jitter_target_frames = static_cast<uint32_t>(jitter_target_ms * 48.0);
                // Blend with current target (slow EMA α=0.1 to avoid oscillation)
                uint32_t cur = target_fill_frames_.load(std::memory_order_relaxed);
                uint32_t blended = static_cast<uint32_t>(cur * 0.9 + jitter_target_frames * 0.1);
                target_fill_frames_.store(blended, std::memory_order_relaxed);
            }

        }

        // Sync mode: adjust buffer target using OSTP media_timestamp (relay mode).
        // receive_loop() sleeps in relay mode so sync adjustment runs here every 50 pkts (~0.25s).
        // All receivers see the same media_timestamp and converge to the same playout offset → sync.
        if ((relay_inject_count_ % 50 == 0) &&
            sync_mode_.load(std::memory_order_relaxed) && rtp_receiver_) {
            uint32_t media_ts = rtp_receiver_->last_media_timestamp.load(std::memory_order_relaxed);
            if (media_ts != 0) {
                struct timespec now_ts;
                clock_gettime(CLOCK_REALTIME, &now_ts);
                uint32_t now_ms32 = static_cast<uint32_t>(
                    (static_cast<uint64_t>(now_ts.tv_sec) * 1000ULL +
                     static_cast<uint64_t>(now_ts.tv_nsec) / 1'000'000ULL) & 0xFFFFFFFF);
                int64_t offset_ns = clock_offset_ns_.load(std::memory_order_relaxed);
                int32_t offset_ms = static_cast<int32_t>(offset_ns / 1'000'000LL);
                int32_t net_delay_ms = static_cast<int32_t>(now_ms32 - media_ts) + offset_ms;
                if (net_delay_ms >= 0 && net_delay_ms < 2000) {
                    float hw_latency_ms = output_latency_ms_.load(std::memory_order_relaxed);
                    uint32_t total_delay_ms = sync_delay_ms_.load() + static_cast<uint32_t>(hw_latency_ms);
                    int32_t buffer_ms = static_cast<int32_t>(total_delay_ms) - net_delay_ms;
                    if (buffer_ms < 5) buffer_ms = 5;
                    uint32_t target = static_cast<uint32_t>(buffer_ms * 48);
                    uint32_t prev = target_fill_frames_.load();
                    int32_t diff = static_cast<int32_t>(target) - static_cast<int32_t>(prev);
                    double alpha = (sync_samples_count_ < 50) ? 0.20
                                 : (std::abs(diff) > 2400)    ? 0.15
                                 : (std::abs(diff) > 480)     ? 0.08
                                                               : 0.02;
                    if (sync_samples_count_ < 50) sync_samples_count_++;
                    uint32_t smoothed = static_cast<uint32_t>(prev * (1.0 - alpha) + target * alpha);
                    // In relay mode, enforce 500ms floor for WAN stability
                    // (WAN RTT ~200ms + jitter needs at least 500ms buffer or underruns cause ジリジリ)
                    smoothed = std::max(smoothed, 24000u);
                    target_fill_frames_.store(smoothed);
                }
            }
        }
    }

    void inject_pcm_samples(const int32_t* samples, size_t frame_count) {
        ring_buffer_.write(samples, frame_count);
    }

    uint32_t ring_buffer_channels() const { return channels_; }

    // ── Karaoke mic monitor (separate from main ring buffer) ──
    // Lock-free SPSC: mic callback writes, audio_callback reads
    static constexpr size_t kMicRingSize = 48000; // 1 second
    float mic_ring_[kMicRingSize] = {};
    std::atomic<size_t> mic_write_pos_{0};
    std::atomic<size_t> mic_read_pos_{0};
    std::atomic<bool> mic_monitor_active_{false};

    void write_mic_monitor(const float* samples, uint32_t count) {
        size_t w = mic_write_pos_.load(std::memory_order_relaxed);
        for (uint32_t i = 0; i < count; i++) {
            mic_ring_[(w + i) % kMicRingSize] = samples[i];
        }
        mic_write_pos_.store(w + count, std::memory_order_release);
    }

    // Called from audio_callback to mix mic into output buffer
    void mix_mic_monitor(float* output, uint32_t frame_count, uint32_t out_channels) {
        if (!mic_monitor_active_.load(std::memory_order_relaxed)) return;
        if (!output || frame_count == 0 || out_channels == 0) return;

        size_t r = mic_read_pos_.load(std::memory_order_relaxed);
        size_t w = mic_write_pos_.load(std::memory_order_acquire);

        // Safe unsigned subtraction
        if (w < r) { mic_read_pos_.store(w, std::memory_order_relaxed); return; }
        size_t avail = w - r;
        // Cap to prevent reading stale data (max 1 second behind)
        if (avail > kMicRingSize) {
            r = w - kMicRingSize / 2;
            mic_read_pos_.store(r, std::memory_order_relaxed);
            avail = w - r;
        }

        size_t to_mix = std::min(avail, static_cast<size_t>(frame_count));
        for (size_t i = 0; i < to_mix; i++) {
            float mic_sample = mic_ring_[(r + i) % kMicRingSize] * 0.4f; // low gain to prevent howling
            // Clamp to prevent overflow
            for (uint32_t ch = 0; ch < out_channels; ch++) {
                size_t idx = i * out_channels + ch;
                if (idx < frame_count * out_channels) {
                    float mixed = output[idx] + mic_sample;
                    output[idx] = std::max(-1.0f, std::min(1.0f, mixed));
                }
            }
        }
        mic_read_pos_.store(r + to_mix, std::memory_order_release);
    }

    void set_mic_monitor_active(bool active) {
        mic_monitor_active_.store(active, std::memory_order_relaxed);
        if (!active) {
            // Reset positions
            mic_write_pos_.store(0, std::memory_order_relaxed);
            mic_read_pos_.store(0, std::memory_order_relaxed);
        }
    }

    void flush_ring_buffer() {
        flush_requested_.store(true, std::memory_order_release);
    }

    // ── WAN Relay ─────────────────────────────────────────────────────────

    bool wan_relay_connect(const std::string& host, uint16_t port,
                           const std::string& group, const std::string& password,
                           const std::string& device_id = "") {
        if (!wan_relay_) wan_relay_ = std::make_unique<WanRelayClient>();
        wan_relay_->set_rx_callback([this](const uint8_t* data, size_t len) {
            inject_raw_packet(data, len);
        });
        // Apply stored callbacks BEFORE connect so they're active when
        // the relay sends FILE:/SYNC: to new joiners immediately after JOIN
        if (stored_meta_cb_) wan_relay_->set_meta_callback(stored_meta_cb_);
        if (stored_file_cb_) wan_relay_->set_file_callback(stored_file_cb_);
        if (stored_sync_cb_) wan_relay_->set_sync_callback(stored_sync_cb_);
        // MAXDELAY: adapt sync_delay_ms_ to group-wide max (up to 2000ms)
        wan_relay_->set_maxdelay_callback([this](uint32_t max_ms) {
            uint32_t capped = std::min(max_ms, 2000u);
            uint32_t current = sync_delay_ms_.load(std::memory_order_relaxed);
            if (capped != current) {
                sync_delay_ms_.store(capped, std::memory_order_relaxed);
                NSLog(@"[sync] MAXDELAY received: %u ms (was %u ms)", capped, current);
            }
        });
        // VOLUME_SET: remote volume control from Mac/other device
        wan_relay_->set_volume_callback([this](float vol) {
            volume_.store(vol, std::memory_order_relaxed);
            NSLog(@"[relay] Remote volume set to %.0f%%", vol * 100.0f);
        });
        // Reset first-packet flag BEFORE connect so inject_raw_packet triggers buffer reset
        relay_first_packet_received_.store(false, std::memory_order_relaxed);
        bool ok = wan_relay_->connect(host, port, group, password, "iPhone", device_id);
        if (ok) {
            // Switch to relay-only mode: multicast is LAN-only, relay carries WAN audio
            relay_network_disabled_.store(true);
            // Force stable buffer for relay — sync mode EMA may have reduced it
            // Flush old channel audio from ring buffer
            flush_requested_.store(true, std::memory_order_release);
            target_fill_frames_.store(24000, std::memory_order_relaxed);  // 500ms WAN jitter cushion (EU→JP ~250ms RTT)
            health_.store(0, std::memory_order_relaxed);
            health_silenced_.store(false, std::memory_order_relaxed);
            prefilled_ = false;  // Re-prefill with relay data
            NSLog(@"[relay] Connected — buffer flushed, target=24000 (500ms), reset health");
        }
        return ok;
    }

    void wan_relay_disconnect() {
        if (wan_relay_) wan_relay_->disconnect();
        relay_network_disabled_.store(false);  // restore multicast
    }

    WanRelayClient::State wan_relay_state() const {
        return wan_relay_ ? wan_relay_->state() : WanRelayClient::State::Disconnected;
    }

    std::string wan_relay_group() const {
        return wan_relay_ ? wan_relay_->group() : "";
    }

    std::string wan_relay_error() const {
        return wan_relay_ ? wan_relay_->error() : "";
    }

    std::string wan_relay_external_addr() const {
        return wan_relay_ ? wan_relay_->external_addr() : "";
    }

    std::string wan_relay_debug_log() const {
        return wan_relay_ ? wan_relay_->get_debug_log() : "no relay";
    }

    void wan_relay_set_meta_callback(WanRelayClient::MetaCallback cb) {
        stored_meta_cb_ = cb;
        if (wan_relay_) wan_relay_->set_meta_callback(std::move(cb));
    }

    void wan_relay_set_file_callback(WanRelayClient::FileCallback cb) {
        stored_file_cb_ = cb;
        if (wan_relay_) wan_relay_->set_file_callback(std::move(cb));
    }

    void wan_relay_set_sync_callback(WanRelayClient::SyncCallback cb) {
        stored_sync_cb_ = cb;
        if (wan_relay_) wan_relay_->set_sync_callback(std::move(cb));
    }

    void wan_relay_send_ready(const std::string& filename) {
        if (wan_relay_) wan_relay_->send_ready(filename);
    }

    void wan_relay_send_audio(const uint8_t* data, size_t len) {
        if (wan_relay_) wan_relay_->send_audio(data, len);
    }

    void wan_relay_mic_allow(const std::string& device_id) {
        if (wan_relay_) wan_relay_->send_mic_allow(device_id);
    }

    void wan_relay_mic_deny(const std::string& device_id) {
        if (wan_relay_) wan_relay_->send_mic_deny(device_id);
    }

    void wan_relay_mic_list() {
        if (wan_relay_) wan_relay_->send_mic_list();
    }

    void wan_relay_members() {
        if (wan_relay_) wan_relay_->send_members();
    }

    void wan_relay_send_volume(const std::string& target_device_id, int level) {
        if (wan_relay_) wan_relay_->send_volume(target_device_id, level);
    }

    std::unique_ptr<WanRelayClient> wan_relay_;
    WanRelayClient::MetaCallback stored_meta_cb_;
    WanRelayClient::FileCallback stored_file_cb_;
    WanRelayClient::SyncCallback stored_sync_cb_;

    // ── Public accessors for ObjC bridge ──────────────────────────────────
    float output_peak() const { return output_peak_.load(std::memory_order_relaxed); }
    size_t ring_buffer_available_read() const { return ring_buffer_.available_read(); }
    uint32_t get_target_fill_frames() const { return target_fill_frames_.load(); }
    bool is_prefilled() const { return prefilled_; }
    bool is_health_silenced() const { return health_silenced_.load(std::memory_order_relaxed); }
    float get_volume() const { return volume_.load(std::memory_order_relaxed); }
    bool is_relay_first_packet() const { return relay_first_packet_received_.load(std::memory_order_relaxed); }
    SimpleRtpReceiver::Stats get_rtp_stats() const {
        return rtp_receiver_ ? rtp_receiver_->stats_snapshot() : SimpleRtpReceiver::Stats{};
    }
    bool has_rtp_receiver() const { return rtp_receiver_ != nullptr; }

private:
    // ── Health tracking helpers (audio-callback thread only) ──────────────

    static uint64_t now_ms_() {
        using namespace std::chrono;
        return (uint64_t)duration_cast<milliseconds>(
            steady_clock::now().time_since_epoch()).count();
    }

    void record_underrun_now() {
        // Before first relay packet: skip entirely to prevent hp=2/sil=1 on startup.
        if (!relay_first_packet_received_.load(std::memory_order_relaxed)) {
            return;
        }

        uint64_t now = now_ms_();
        if (health_window_start_ms_ == 0 || now - health_window_start_ms_ >= 30000) {
            health_window_start_ms_ = now;
            health_underruns_in_window_ = 0;
        }
        health_underruns_in_window_++;
        last_underrun_ms_ = now;

        // ── Adaptive buffer: increase on underrun ──────────────────────────
        // Bump target by 50ms (2400 frames @ 48kHz) each underrun, up to 2000ms max.
        // Critical for WAN relay: jitter can exceed 500ms initial buffer.
        uint32_t cur_target = target_fill_frames_.load(std::memory_order_relaxed);
        constexpr uint32_t kBumpFrames = 2400;   // 50ms
        constexpr uint32_t kMaxTarget  = 96000;  // 2000ms
        if (cur_target + kBumpFrames <= kMaxTarget) {
            target_fill_frames_.store(cur_target + kBumpFrames, std::memory_order_relaxed);
        }

        // In relay mode, skip health degradation (silencing) — only grow buffer
        if (relay_network_disabled_.load(std::memory_order_relaxed)) {
            return;
        }

        int cur = health_.load(std::memory_order_relaxed);
        if (health_underruns_in_window_ >= 200 && cur < 2) {
            // Extreme underruns: silence device to prevent noise
            health_.store(2, std::memory_order_relaxed);
            health_silenced_.store(true, std::memory_order_relaxed);
        } else if (health_underruns_in_window_ >= 30 && cur < 1) {
            // Moderate underruns: mark stressed (UI indicator only)
            health_.store(1, std::memory_order_relaxed);
        }
    }

    void maybe_check_recovery() {
        if (++recovery_check_counter_ < 200) return;  // ~1 s at 5ms/callback
        recovery_check_counter_ = 0;

        // ── Adaptive buffer: shrink when stable ────────────────────────────
        // If no underrun for 5 seconds, reduce target by 5ms (240 frames).
        // This slowly converges to the minimum viable buffer for the network.
        // Skip shrinking in relay mode — buffer needs to stay large for stability.
        constexpr uint32_t kShrinkFrames = 240;   // 5ms
        constexpr uint32_t kMinTarget    = 1440;   // 30ms floor
        uint64_t now = now_ms_();
        if (!relay_network_disabled_.load(std::memory_order_relaxed) &&
            last_underrun_ms_ != 0 && now - last_underrun_ms_ >= 5000) {
            uint32_t cur_target = target_fill_frames_.load(std::memory_order_relaxed);
            if (cur_target > kMinTarget + kShrinkFrames) {
                target_fill_frames_.store(cur_target - kShrinkFrames, std::memory_order_relaxed);
            }
        }

        // Health recovery: 10 seconds clean → restore good
        if (health_.load(std::memory_order_relaxed) == 0) return;
        if (last_underrun_ms_ == 0) return;
        if (now - last_underrun_ms_ >= 10000) {
            health_.store(0, std::memory_order_relaxed);
            health_silenced_.store(false, std::memory_order_relaxed);
            health_window_start_ms_ = 0;
            health_underruns_in_window_ = 0;
            last_underrun_ms_ = 0;
        }
    }

    void receive_loop() {
        // ONLY writes to ring_buffer_ — never reads (RingBuffer is SPSC).
        // Drain happens exclusively in audio_callback to avoid data race.
        // Propagate relay callback now that rtp_receiver_ is initialized.
        if (relay_callback_ && rtp_receiver_) {
            rtp_receiver_->relay_callback = relay_callback_;
        }
        uint64_t log_counter = 0;
        while (running_.load()) {
            // When network disabled (relay or file-sync), audio arrives via inject_raw_packet instead
            if (relay_network_disabled_.load() || filesync_network_disabled_.load()) {
                std::this_thread::sleep_for(std::chrono::milliseconds(5));
                continue;
            }
            if (rtp_receiver_) {
                for (int i = 0; i < 10 && running_.load(); i++) {
                    if (!rtp_receiver_->receive_packet(ring_buffer_)) break;
                }
                // Propagate detected TX channel count from receiver to audio callback
                uint32_t rx_tx_ch = rtp_receiver_->detected_tx_channels_.load(std::memory_order_relaxed);
                if (rx_tx_ch > 0) {
                    detected_tx_channels_.store(rx_tx_ch, std::memory_order_relaxed);
                }
            }

            // ── Sync mode: adjust buffer target from OSTP wall-clock timestamps ──
            // Uses NTP-like clock sync to correct offset between TX and RX clocks.
            // All devices seeing the same media_timestamp will converge to the same
            // playout offset, achieving multi-device synchronization within ±5ms.
            // Propagate clock offset from relay client (updated every 5s via PT=125)
            if (wan_relay_) {
                clock_offset_ns_.store(wan_relay_->clock_offset_ns(), std::memory_order_relaxed);
            }
            if (sync_mode_.load(std::memory_order_relaxed) && rtp_receiver_) {
                uint32_t media_ts = rtp_receiver_->last_media_timestamp.load(std::memory_order_relaxed);
                if (media_ts != 0) {
                    // OSTP v0.9.3: media_timestamp is milliseconds (49-day rollover)
                    struct timespec now_ts;
                    clock_gettime(CLOCK_REALTIME, &now_ts);
                    uint32_t now_ms32 = static_cast<uint32_t>(
                        (static_cast<uint64_t>(now_ts.tv_sec) * 1000ULL +
                         static_cast<uint64_t>(now_ts.tv_nsec) / 1'000'000ULL)
                        & 0xFFFFFFFF);
                    // Apply clock offset correction (relay_time - local_time)
                    // media_ts is stamped by TX (relay's clock reference).
                    int64_t offset_ns = clock_offset_ns_.load(std::memory_order_relaxed);
                    int32_t offset_ms = static_cast<int32_t>(offset_ns / 1'000'000LL);
                    int32_t net_delay_ms = static_cast<int32_t>(now_ms32 - media_ts) + offset_ms;
                    if (net_delay_ms >= 0 && net_delay_ms < 2000) {
                        // Add hardware output latency (Bluetooth/AirPlay) to sync delay
                        float hw_latency_ms = output_latency_ms_.load(std::memory_order_relaxed);
                        uint32_t total_delay_ms = sync_delay_ms_.load() + static_cast<uint32_t>(hw_latency_ms);
                        int32_t buffer_ms = static_cast<int32_t>(total_delay_ms) - net_delay_ms;
                        if (buffer_ms < 5) buffer_ms = 5;   // 5ms floor
                        uint32_t target = static_cast<uint32_t>(buffer_ms * 48);  // ms→frames @48kHz

                        // Adaptive EMA: fast convergence initially (α=0.2), slow when stable (α=0.02)
                        uint32_t prev = target_fill_frames_.load();
                        int32_t diff = static_cast<int32_t>(target) - static_cast<int32_t>(prev);
                        double alpha;
                        if (sync_samples_count_ < 50) {
                            alpha = 0.20;  // First ~250ms: fast lock-on
                            sync_samples_count_++;
                        } else if (std::abs(diff) > 2400) {
                            alpha = 0.15;  // >50ms jump: re-converge quickly
                        } else if (std::abs(diff) > 480) {
                            alpha = 0.08;  // 10-50ms drift: moderate correction
                        } else {
                            alpha = 0.02;  // Stable: gentle smoothing (±10ms)
                        }
                        uint32_t smoothed = static_cast<uint32_t>(prev * (1.0 - alpha) + target * alpha);
                        // In relay mode, enforce minimum 500ms buffer for WAN stability
                        // (WAN RTT ~200ms + jitter: 200ms floor causes underruns → ジリジリ)
                        if (relay_network_disabled_.load(std::memory_order_relaxed)) {
                            smoothed = std::max(smoothed, 24000u);  // 500ms floor for WAN
                        }
                        target_fill_frames_.store(smoothed);

                        // Median filter: track last 5 net_delay measurements
                        sync_delay_history_[sync_delay_idx_ % 5] = net_delay_ms;
                        sync_delay_idx_++;
                    }
                }
            }

            // Report network delay to relay every ~5 seconds for sync coordination
            if (log_counter % 50000 == 0 && wan_relay_ && sync_mode_.load(std::memory_order_relaxed)) {
                if (rtp_receiver_) {
                    uint32_t media_ts = rtp_receiver_->last_media_timestamp.load(std::memory_order_relaxed);
                    if (media_ts != 0) {
                        // OSTP v0.9.3: media_timestamp in ms
                        struct timespec rpt_ts;
                        clock_gettime(CLOCK_REALTIME, &rpt_ts);
                        uint32_t rpt_ms32 = static_cast<uint32_t>(
                            (static_cast<uint64_t>(rpt_ts.tv_sec) * 1000ULL +
                             static_cast<uint64_t>(rpt_ts.tv_nsec) / 1'000'000ULL) & 0xFFFFFFFF);
                        int64_t offset_ns = clock_offset_ns_.load(std::memory_order_relaxed);
                        int32_t offset_ms = static_cast<int32_t>(offset_ns / 1'000'000LL);
                        int32_t nd_ms = static_cast<int32_t>(rpt_ms32 - media_ts) + offset_ms;
                        if (nd_ms >= 0 && nd_ms < 2000) {
                            wan_relay_->send_delay(static_cast<uint32_t>(nd_ms));
                        }
                    }
                }
            }

            // Periodic debug log every ~2 seconds
            if (++log_counter % 20000 == 0) {
                auto st = rtp_receiver_ ? rtp_receiver_->stats_snapshot() : SimpleRtpReceiver::Stats{};
                fprintf(stderr, "[SolunaRx] pkts=%llu seq_err=%llu dropped=%llu fill=%zu prefilled=%d target=%u underruns=%u\n",
                        (unsigned long long)st.packets_received,
                        (unsigned long long)st.sequence_errors,
                        (unsigned long long)st.packets_dropped,
                        ring_buffer_.available_read(),
                        (int)prefilled_,
                        target_fill_frames_.load() / 48u,
                        health_underruns_in_window_);
            }
            std::this_thread::sleep_for(std::chrono::microseconds(100));
        }
    }

    std::string handle_ws_command(const std::string& msg) {
        int id = 0;
        auto p = msg.find("\"id\":");
        if (p != std::string::npos) try { id = std::stoi(msg.substr(p + 5)); } catch (...) {}

        std::string cmd;
        p = msg.find("\"command\":\"");
        if (p != std::string::npos) {
            auto s = p + 11, e = msg.find('"', s);
            if (e != std::string::npos) cmd = msg.substr(s, e - s);
        }

        char buf[512];
        if (cmd == "rx.stats" || cmd == "system.stats") {
            auto st = stats();
            size_t fill = ring_buffer_.available_read();
            uint32_t target_ms = target_fill_frames_.load() / 48u;
            snprintf(buf, sizeof(buf),
                "{\"id\":%d,\"success\":true,\"data\":"
                "\"{\\\"packets\\\":%llu,\\\"errors\\\":%llu,"
                "\\\"buf_fill\\\":%zu,\\\"buf_cap\\\":4096,"
                "\\\"volume\\\":%.3f,\\\"muted\\\":%s,"
                "\\\"buf_target_ms\\\":%u}\"}",
                id,
                (unsigned long long)st.packets_received,
                (unsigned long long)st.sequence_errors,
                fill,
                (double)volume_.load(),
                muted_.load() ? "true" : "false",
                target_ms);
        } else if (cmd == "rx.set_buffer") {
            p = msg.find("\"ms\":");
            if (p != std::string::npos) {
                try {
                    uint32_t ms = static_cast<uint32_t>(std::stoul(msg.substr(p + 5)));
                    ms = std::max(5u, std::min(200u, ms));
                    target_fill_frames_.store(ms * 48u);
                } catch (...) {}
            }
            snprintf(buf, sizeof(buf), "{\"id\":%d,\"success\":true,\"data\":\"\"}", id);
        } else if (cmd == "rx.set_volume") {
            p = msg.find("\"volume\":");
            if (p != std::string::npos) {
                try { set_volume(std::stof(msg.substr(p + 9))); } catch (...) {}
            }
            snprintf(buf, sizeof(buf), "{\"id\":%d,\"success\":true,\"data\":\"\"}", id);
        } else if (cmd == "rx.set_mute") {
            p = msg.find("\"muted\":");
            if (p != std::string::npos)
                set_muted(msg.substr(p + 8, 4) == "true");
            snprintf(buf, sizeof(buf), "{\"id\":%d,\"success\":true,\"data\":\"\"}", id);

        // ── monitor.* aliases (Mac DaemonClient compatibility) ──────────
        } else if (cmd == "monitor.stats") {
            auto st = stats();
            uint32_t bms = target_fill_frames_.load() / 48u;
            snprintf(buf, sizeof(buf),
                "{\"id\":%d,\"success\":true,\"data\":"
                "\"{\\\"supported\\\":true,\\\"running\\\":true,"
                "\\\"volume\\\":%.3f,\\\"muted\\\":%s,"
                "\\\"packets\\\":%llu,\\\"buf_ms\\\":%u}\"}",
                id,
                (double)volume_.load(),
                muted_.load() ? "true" : "false",
                (unsigned long long)st.packets_received,
                bms);
        } else if (cmd == "monitor.set_volume") {
            p = msg.find("\"volume\":");
            if (p != std::string::npos) {
                try { set_volume(std::stof(msg.substr(p + 9))); } catch (...) {}
            }
            snprintf(buf, sizeof(buf), "{\"id\":%d,\"success\":true,\"data\":\"\"}", id);
        } else if (cmd == "monitor.set_mute") {
            p = msg.find("\"muted\":");
            if (p != std::string::npos)
                set_muted(msg.substr(p + 8, 4) == "true");
            snprintf(buf, sizeof(buf), "{\"id\":%d,\"success\":true,\"data\":\"\"}", id);
        } else if (cmd == "monitor.set_buffer") {
            p = msg.find("\"ms\":");
            if (p != std::string::npos) {
                try {
                    uint32_t ms = static_cast<uint32_t>(std::stoul(msg.substr(p + 5)));
                    set_buffer_ms(ms);
                } catch (...) {}
            }
            snprintf(buf, sizeof(buf), "{\"id\":%d,\"success\":true,\"data\":\"\"}", id);
        } else if (cmd == "monitor.list_devices") {
            snprintf(buf, sizeof(buf),
                "{\"id\":%d,\"success\":true,\"data\":\"[]\"}",
                id);
        } else if (cmd == "system.info") {
            snprintf(buf, sizeof(buf),
                "{\"id\":%d,\"success\":true,\"data\":"
                "\"{\\\"tunnel_url\\\":\\\"\\\"}\"}",
                id);
        } else {
            snprintf(buf, sizeof(buf),
                "{\"id\":%d,\"success\":false,\"data\":\"unknown command\"}", id);
        }
        return buf;
    }

    /// Downmix one frame from tx_ch → out_ch (no EQ/compressor, for underrun path)
    inline void downmix_frame(const int32_t* src, uint32_t tx_ch,
                              float* dst, uint32_t out_ch, float gain) {
        if (out_ch == 1) {
            // Sum all TX channels → mono
            float sum = 0;
            for (uint32_t c = 0; c < tx_ch; c++)
                sum += static_cast<float>(src[c]) / 8388608.0f;
            float s = sum / static_cast<float>(tx_ch);
            if (s > 1.0f) s = 1.0f; else if (s < -1.0f) s = -1.0f;
            float out = s * gain;
            dst[0] = out;
            held_sample_[0] = out;
        } else if (out_ch == 2 && tx_ch == 1) {
            // Mono → Stereo: duplicate to both channels
            float s = static_cast<float>(src[0]) / 8388608.0f;
            if (s > 1.0f) s = 1.0f; else if (s < -1.0f) s = -1.0f;
            float out = s * gain;
            dst[0] = out; dst[1] = out;
            held_sample_[0] = out; held_sample_[1] = out;
        } else if (out_ch == 2 && tx_ch > 2) {
            // Downmix surround → stereo: L = sum(even ch) / (tx_ch/2), R = sum(odd ch) / (tx_ch/2)
            float L = 0, R = 0;
            for (uint32_t c = 0; c < tx_ch; c++) {
                float s = static_cast<float>(src[c]) / 8388608.0f;
                if (c % 2 == 0) L += s; else R += s;
            }
            float div = static_cast<float>((tx_ch + 1) / 2);
            L = std::max(-1.0f, std::min(1.0f, L / div)) * gain;
            R = std::max(-1.0f, std::min(1.0f, R / div)) * gain;
            dst[0] = L; dst[1] = R;
            held_sample_[0] = L; held_sample_[1] = R;
        } else {
            // Pass-through or truncate to out_ch (tx_ch >= out_ch)
            uint32_t n = std::min(tx_ch, out_ch);
            for (uint32_t c = 0; c < n; c++) {
                float s = static_cast<float>(src[c]) / 8388608.0f;
                if (s > 1.0f) s = 1.0f; else if (s < -1.0f) s = -1.0f;
                float out = s * gain;
                dst[c] = out;
                held_sample_[c] = out;
            }
            for (uint32_t c = n; c < out_ch; c++) {
                dst[c] = 0; held_sample_[c] = 0;
            }
        }
    }

    /// Downmix one frame with EQ + compressor + drift crossfade (normal playback path)
    inline void downmix_frame_eq(const int32_t* src, uint32_t tx_ch,
                                 float* dst, uint32_t out_ch, float gain) {
        if (out_ch == 1) {
            float sum = 0;
            for (uint32_t c = 0; c < tx_ch; c++)
                sum += static_cast<float>(src[c]) / 8388608.0f;
            float s = sum / static_cast<float>(tx_ch);
            if (s > 1.0f) s = 1.0f; else if (s < -1.0f) s = -1.0f;
            s = eq_.process(s, 0);
            s = compressor_.process(s);
            float out = s * gain;
            if (drift_xfade_ > 0) {
                float alpha = 1.0f - static_cast<float>(drift_xfade_) / 49.0f;
                out = out * alpha + held_sample_[0] * (1.0f - alpha);
            }
            dst[0] = out;
            held_sample_[0] = out;
        } else if (out_ch == 2 && tx_ch == 1) {
            // Mono → Stereo: process once, duplicate to both channels
            float s = static_cast<float>(src[0]) / 8388608.0f;
            if (s > 1.0f) s = 1.0f; else if (s < -1.0f) s = -1.0f;
            s = eq_.process(s, 0);
            s = compressor_.process(s);
            float out = s * gain;
            if (drift_xfade_ > 0) {
                float alpha = 1.0f - static_cast<float>(drift_xfade_) / 49.0f;
                out = out * alpha + held_sample_[0] * (1.0f - alpha);
            }
            dst[0] = out; dst[1] = out;
            held_sample_[0] = out; held_sample_[1] = out;
        } else if (out_ch == 2 && tx_ch > 2) {
            // Surround → stereo downmix with EQ
            float L = 0, R = 0;
            for (uint32_t c = 0; c < tx_ch; c++) {
                float s = static_cast<float>(src[c]) / 8388608.0f;
                if (c % 2 == 0) L += s; else R += s;
            }
            float div = static_cast<float>((tx_ch + 1) / 2);
            L = std::max(-1.0f, std::min(1.0f, L / div));
            R = std::max(-1.0f, std::min(1.0f, R / div));
            float chans[2] = {L, R};
            for (uint32_t c = 0; c < 2; c++) {
                float s = eq_.process(chans[c], c);
                s = compressor_.process(s);
                float out = s * gain;
                if (drift_xfade_ > 0) {
                    float alpha = 1.0f - static_cast<float>(drift_xfade_) / 49.0f;
                    out = out * alpha + held_sample_[c] * (1.0f - alpha);
                }
                dst[c] = out;
                held_sample_[c] = out;
            }
        } else {
            // Pass-through or truncate
            uint32_t n = std::min(tx_ch, out_ch);
            for (uint32_t c = 0; c < n; c++) {
                float s = static_cast<float>(src[c]) / 8388608.0f;
                if (s > 1.0f) s = 1.0f; else if (s < -1.0f) s = -1.0f;
                s = eq_.process(s, c);
                s = compressor_.process(s);
                float out = s * gain;
                if (drift_xfade_ > 0) {
                    float alpha = 1.0f - static_cast<float>(drift_xfade_) / 49.0f;
                    out = out * alpha + held_sample_[c] * (1.0f - alpha);
                }
                dst[c] = out;
                held_sample_[c] = out;
            }
            for (uint32_t c = n; c < out_ch; c++) {
                dst[c] = 0; held_sample_[c] = 0;
            }
        }
    }

    void audio_callback(float* buffer, uint32_t frame_count) {
        if (flush_requested_.load(std::memory_order_acquire)) {
            flush_requested_.store(false, std::memory_order_relaxed);
            // Safe consumer-side drain: advance read_pos to current write_pos.
            // Do NOT use ring_buffer_.reset() — it resets both write_pos and read_pos,
            // which is unsafe while the relay thread is concurrently writing.
            size_t to_drain = ring_buffer_.available_read();
            if (to_drain > 0) ring_buffer_.discard(to_drain);
            prefilled_ = false;
            ramp_ = 0.0f;
        }

        const float vol = (muted_.load() || health_silenced_.load(std::memory_order_relaxed))
                          ? 0.0f : volume_.load();
        const uint32_t tx_ch = detected_tx_channels_.load(std::memory_order_relaxed);
        const uint32_t out_ch = channels_;
        const uint32_t total_samples = frame_count * out_ch;

        // ── Multi-source mixing path (talk mode) ─────────────────────────
        if (talk_mode_active_.load(std::memory_order_relaxed) && multi_mixer_.has_data(frame_count, tx_ch)) {
            std::vector<int32_t> mix_buf(frame_count * tx_ch);
            size_t mixed = multi_mixer_.read_mixed(mix_buf.data(), frame_count, tx_ch);
            if (mixed > 0) {
                const float gain = vol;
                for (uint32_t i = 0; i < frame_count; i++) {
                    ramp_ += 0.002f * (gain - ramp_);
                    downmix_frame_eq(mix_buf.data() + i * tx_ch, tx_ch, buffer + i * out_ch, out_ch, ramp_);
                }
                return;
            }
        }

        uint32_t target = target_fill_frames_.load();
        // Ensure target is at least a few callbacks worth
        const uint32_t min_target = frame_count * 3;
        if (target < min_target) target = min_target;

        // ── Drift correction with overflow protection ────────────────────
        {
            size_t avail_now = ring_buffer_.available_read();
            size_t capacity = ring_buffer_.capacity();

            // Emergency: if buffer is >80% full, flush to target to prevent crash
            if (avail_now > capacity * 4 / 5) {
                size_t drain_to = static_cast<size_t>(target);
                if (avail_now > drain_to) {
                    ring_buffer_.discard(avail_now - drain_to);
                }
                drift_xfade_ = 96;
            }
            // Normal: gradual drift when overfilled (3x target)
            else if (prefilled_ && avail_now > static_cast<size_t>(target) * 3) {
                size_t excess = avail_now - static_cast<size_t>(target) * 2;
                // Discard more aggressively: up to frame_count/4
                size_t drift = std::min(excess, static_cast<size_t>(frame_count / 4 + 1));
                ring_buffer_.discard(drift);
                drift_xfade_ = 48;
            }
        }

        const size_t avail = ring_buffer_.available_read();

        constexpr float kFadeIn  = 0.002f;  // faster fade-in for snappier recovery
        constexpr float kFadeOut = 0.004f;

        // ── Initial prefill (only at startup, NOT reset on underrun) ───────
        if (!prefilled_) {
            // Wait until ring buffer has enough data before starting playback.
            // Use the full target (buffer target from adaptive/sync) as threshold
            // to prevent underruns on WAN connections (e.g. Germany→Japan ~250ms RTT).
            uint32_t prefill_threshold = target;
            if (avail < prefill_threshold) {
                std::memset(buffer, 0, total_samples * sizeof(float));
                return;
            }
            prefilled_ = true;
            ramp_ = 0.0f;  // ensure clean fade-in
        }

        // ── Underrun: play what we have ────────────────────────────────────
        // Ring buffer frames are kMaxRxChannels-wide; stride by kMaxRxChannels
        if (avail < frame_count) {
            record_underrun_now();
            maybe_check_recovery();
            const size_t have = avail;
            if (have > 0) {
                ring_buffer_.read(read_buffer_.data(), have);
                const int32_t* src = read_buffer_.data();
                for (uint32_t i = 0; i < have; i++) {
                    ramp_ += kFadeIn * (vol - ramp_);
                    // Downmix tx_ch → out_ch (stride by kMaxRxChannels in ring buffer)
                    downmix_frame(src + i * kMaxRxChannels, tx_ch, buffer + i * out_ch, out_ch, ramp_);
                }
            }
            // Hold last sample with gentle decay to prevent clicks
            if (relay_network_disabled_.load(std::memory_order_relaxed)) {
                constexpr float kHoldDecay = 0.998f;
                for (uint32_t i = static_cast<uint32_t>(have); i < frame_count; i++) {
                    for (uint32_t ch = 0; ch < out_ch; ch++) {
                        held_sample_[ch] *= kHoldDecay;
                        buffer[i * out_ch + ch] = held_sample_[ch];
                    }
                }
            } else {
                for (uint32_t i = static_cast<uint32_t>(have); i < frame_count; i++) {
                    ramp_ *= (1.0f - kFadeOut);
                    for (uint32_t ch = 0; ch < out_ch; ch++) {
                        buffer[i * out_ch + ch] = held_sample_[ch] * ramp_;
                    }
                }
            }
            return;
        }

        maybe_check_recovery();

        // ── Normal playback ────────────────────────────────────────────────
        // Ring buffer frames are kMaxRxChannels-wide; stride by kMaxRxChannels
        ring_buffer_.read(read_buffer_.data(), frame_count);
        const int32_t* src = read_buffer_.data();

        // Diagnostic: log sample values on first few callbacks to detect bad data
        if (audio_diag_count_ < 5) {
            audio_diag_count_++;
            float s0 = static_cast<float>(src[0]) / 8388608.0f;
            float s1 = static_cast<float>(src[1]) / 8388608.0f;
            float s2 = static_cast<float>(src[kMaxRxChannels]) / 8388608.0f;
            float s3 = static_cast<float>(src[kMaxRxChannels + 1]) / 8388608.0f;
            NSLog(@"[AudioCB] diag#%u tx_ch=%u out_ch=%u fc=%u raw0=%d raw1=%d f0L=%.4f f0R=%.4f f1L=%.4f f1R=%.4f ramp=%.3f",
                  audio_diag_count_, tx_ch, out_ch, frame_count,
                  src[0], src[1], s0, s1, s2, s3, ramp_);
        }
        for (uint32_t i = 0; i < frame_count; i++) {
            ramp_ += kFadeIn * (vol - ramp_);
            // Downmix tx_ch → out_ch with EQ/compressor (stride by kMaxRxChannels)
            downmix_frame_eq(src + i * kMaxRxChannels, tx_ch, buffer + i * out_ch, out_ch, ramp_);
            if (drift_xfade_ > 0) drift_xfade_--;
        }

        // ── EBU R128 loudness normalization ──────────────────────────────
        if (loudness_norm_enabled_.load(std::memory_order_relaxed)) {
            // Simplified K-weighted loudness measurement — mean square power
            float sum_sq = 0;
            for (uint32_t i = 0; i < total_samples; i++) {
                float s = buffer[i];
                sum_sq += s * s;
            }
            float mean_sq = sum_sq / total_samples;

            // Store power (mean square) in sliding window (~400ms at ~120 callbacks/sec)
            // Power-domain averaging is correct for EBU R128 (not dB averaging)
            loudness_window_[loudness_window_pos_] = mean_sq;
            loudness_window_pos_ = (loudness_window_pos_ + 1) % 48;
            if (loudness_window_pos_ == 0) loudness_window_full_ = true;

            // Calculate integrated loudness — average power then convert to dB
            int count = loudness_window_full_ ? 48 : loudness_window_pos_;
            if (count > 0) {
                float power_sum = 0;
                for (int i = 0; i < count; i++) power_sum += loudness_window_[i];
                float avg_power = power_sum / count;
                float avg_db = (avg_power > 1e-20f) ? 10.0f * log10f(avg_power) : -100.0f;

                // Target -23 LUFS, calculate needed gain
                float target_db = -23.0f;
                float gain_db = target_db - avg_db;
                // Clamp gain to reasonable range (-12 to +12 dB)
                if (gain_db < -12.0f) gain_db = -12.0f;
                if (gain_db > 12.0f) gain_db = 12.0f;

                float target_gain = powf(10.0f, gain_db / 20.0f);
                // Smooth gain changes (EMA)
                loudness_current_gain_ = loudness_current_gain_ * 0.95f + target_gain * 0.05f;
            }

            // Apply gain
            for (uint32_t i = 0; i < total_samples; i++) {
                buffer[i] *= loudness_current_gain_;
            }
        }

        // ── Output level metering (for visualization) ───────────────────
        {
            // Mix secondary SSRC sources (karaoke mics, talk mode)
            if (rtp_receiver_) rtp_receiver_->mix_secondary_sources(buffer, frame_count, out_ch);

            float peak = 0.0f;
            for (uint32_t i = 0; i < total_samples; i++) {
                float a = buffer[i] < 0 ? -buffer[i] : buffer[i];
                if (a > peak) peak = a;
            }
            float prev = output_peak_.load(std::memory_order_relaxed);
            if (peak > prev) {
                output_peak_.store(peak, std::memory_order_relaxed);
            } else {
                output_peak_.store(prev * 0.92f, std::memory_order_relaxed);
            }
        }

        // ── Recording: write rendered samples ────────────────────────────
        {
            std::lock_guard<std::mutex> lock(record_mutex_);
            if (record_callback_) {
                record_callback_(buffer, total_samples);
            }
        }

        // ── Sample tap: feed fingerprinting ──────────────────────────────
        {
            std::lock_guard<std::mutex> lock(sample_tap_mutex_);
            if (sample_tap_callback_) {
                sample_tap_callback_(buffer, total_samples, channels_);
            }
        }
    }

    std::function<void(const uint8_t*, size_t)> relay_callback_;

    float test_tone_phase_ = 0.0f;  // test tone phase counter

    std::string multicast_group_;
    uint16_t port_;
    uint32_t channels_;
    std::atomic<float>    volume_;
    std::atomic<bool>     muted_;
    std::atomic<bool>     running_;
    std::atomic<uint32_t> target_fill_frames_;
    std::atomic<bool>     relay_network_disabled_{false};
    std::atomic<bool>     relay_first_packet_received_{false};
    uint64_t              relay_inject_count_{0};
    // RTCP jitter feedback (OSTP v0.9.3 §6 / RFC 3550 §6.4.1)
    double                ia_jitter_ema_ms_{0.0};   // inter-arrival jitter EMA (ms)
    uint64_t              ia_last_arrival_ns_{0};    // wall-clock ns of last packet
    uint32_t              ia_last_rtp_ts_{0};        // RTP timestamp of last packet
    std::atomic<uint32_t> detected_tx_channels_{2};  // Auto-detected from OSTP stream_id (default stereo)
    std::atomic<bool>     filesync_network_disabled_{false};
    std::atomic<bool>     sync_mode_{true};
    std::atomic<uint32_t> sync_delay_ms_{80};     // 80ms default (was 200ms — tighter for WiFi sync)
    // Sync convergence state:
    uint32_t              sync_samples_count_{0};  // EMA sample counter for fast initial lock
    int32_t               sync_delay_history_[5]{};// median filter for outlier rejection
    uint32_t              sync_delay_idx_{0};
    // Clock offset from relay (nanoseconds, relay_time - local_time):
    std::atomic<int64_t>  clock_offset_ns_{0};
    // Output latency compensation (Bluetooth/AirPlay):
    std::atomic<float>    output_latency_ms_{0.0f};
    // Loudness normalization (EBU R128):
    std::atomic<bool>     loudness_norm_enabled_{false};
    // Output level metering (written audio-cb, read ObjC for visualization):
    std::atomic<float>    output_peak_{0.0f};
    // 3-band EQ and compressor (audio-callback-only processing state):
    EQ3Band               eq_;
    Compressor            compressor_;
    // Recording callback (called from audio callback with float samples):
    std::function<void(const float*, uint32_t)> record_callback_;
    std::mutex record_mutex_;
    // Sample tap callback (for fingerprinting — called from audio callback):
    std::function<void(const float*, uint32_t, uint32_t)> sample_tap_callback_;
    std::mutex sample_tap_mutex_;
    // Health tracking atomics (written audio-cb, read ObjC):
    std::atomic<int>      health_{0};           ///< 0=good 1=stressed 2=silenced
    std::atomic<bool>     health_silenced_{false};
    std::atomic<bool>     flush_requested_{false};
    // audio_callback-only state (no atomics needed):
    bool                  prefilled_ = false;
    float                 ramp_      = 0.0f;
    std::vector<float>    held_sample_;
    // Drift correction crossfade counter (audio-callback-only):
    uint32_t drift_xfade_ = 0;
    // Loudness normalization state (audio-callback-only):
    float loudness_current_gain_ = 1.0f;
    float loudness_window_[48]{};           // 400ms window at ~120 callbacks/sec
    int   loudness_window_pos_ = 0;
    bool  loudness_window_full_ = false;
    // Diagnostic logging counter (audio-callback-only):
    uint32_t audio_diag_count_ = 0;
    // Health tracking — audio-callback-only (no atomic needed):
    uint64_t health_window_start_ms_    = 0;
    uint32_t health_underruns_in_window_ = 0;
    uint64_t last_underrun_ms_          = 0;
    uint32_t recovery_check_counter_    = 0;

    std::unique_ptr<SimpleRtpReceiver> rtp_receiver_;
    std::unique_ptr<pal::AudioDevice>  audio_device_;
    pipeline::RingBuffer  ring_buffer_;
    std::vector<int32_t>  read_buffer_;
    std::vector<int32_t>  drain_buf_;

    // Multi-source mixer for talk mode (multiple simultaneous speakers)
    MultiSourceMixer multi_mixer_;
    std::atomic<bool> talk_mode_active_{false};

    std::thread receive_thread_;
    soluna::control::WebSocketServer ws_server_;
};

} // anonymous namespace


// ============================================================================
// Objective-C Implementation
// ============================================================================

@implementation SolunaReceiverStats {
    uint64_t _packetsReceived;
    uint64_t _packetsDropped;
    uint64_t _packetsConcealed;
    uint64_t _sequenceErrors;
    uint64_t _aes67Packets;
    uint64_t _ostpPackets;
}

- (instancetype)initWithStats:(const SimpleRtpReceiver::Stats&)stats {
    self = [super init];
    if (self) {
        _packetsReceived  = stats.packets_received;
        _packetsDropped   = stats.packets_dropped;
        _packetsConcealed = stats.packets_concealed;
        _sequenceErrors   = stats.sequence_errors;
        _aes67Packets     = stats.aes67_packets;
        _ostpPackets      = stats.ostp_packets;
    }
    return self;
}

- (uint64_t)packetsReceived  { return _packetsReceived; }
- (uint64_t)packetsDropped   { return _packetsDropped; }
- (uint64_t)packetsConcealed { return _packetsConcealed; }
- (uint64_t)sequenceErrors   { return _sequenceErrors; }
- (uint64_t)aes67Packets     { return _aes67Packets; }
- (uint64_t)ostpPackets      { return _ostpPackets; }

@end


@interface SolunaAudioReceiver () {
    std::unique_ptr<ReceiverImpl> _impl;
    std::unique_ptr<TransmitterImpl> _txImpl;
    std::unique_ptr<DJBroadcaster> _djImpl;
    std::unique_ptr<DJController> _djCtrlImpl;
    NSTimer *_statsTimer;
    uint32_t _bufferTargetMs;
    CMHeadphoneMotionManager *_headphoneMotion;
    ExtAudioFileRef _recordFile;
    BOOL _isRecording;
}
@end

@implementation SolunaAudioReceiver
@synthesize micGlobal = _micGlobal;

+ (instancetype)sharedInstance {
    static SolunaAudioReceiver *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[SolunaAudioReceiver alloc] init];
    });
    return shared;
}

- (instancetype)init {
    return [self initWithMulticastGroup:@"239.69.0.1" port:5004 channels:2];
}

- (instancetype)initWithMulticastGroup:(NSString *)group
                                  port:(uint16_t)port
                              channels:(uint32_t)channels {
    self = [super init];
    if (self) {
        _multicastGroup = [group copy];
        _port = port;
        _channels = channels;
        _volume = 1.0f;
        _bufferTargetMs = 80;
        _state = SolunaReceiverStateStopped;
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (BOOL)start {
    if (_state != SolunaReceiverStateStopped) {
        return NO;
    }

    [self willChangeValueForKey:@"state"];
    _state = SolunaReceiverStateConnecting;
    [self didChangeValueForKey:@"state"];

    if ([_delegate respondsToSelector:@selector(receiverDidChange:)]) {
        [_delegate receiverDidChange:_state];
    }

    // Create implementation
    _impl = std::make_unique<ReceiverImpl>(
        std::string([_multicastGroup UTF8String]),
        _port,
        _channels
    );
    _impl->set_volume(_volume);
    _impl->set_buffer_ms(_bufferTargetMs);

    if (!_impl->start()) {
        _impl.reset();

        [self willChangeValueForKey:@"state"];
        _state = SolunaReceiverStateError;
        [self didChangeValueForKey:@"state"];

        if ([_delegate respondsToSelector:@selector(receiverDidChange:)]) {
            [_delegate receiverDidChange:_state];
        }

        NSError *error = [NSError errorWithDomain:@"SolunaReceiver"
                                             code:-1
                                         userInfo:@{NSLocalizedDescriptionKey: @"Failed to start receiver"}];
        if ([_delegate respondsToSelector:@selector(receiverDidEncounter:)]) {
            [_delegate receiverDidEncounter:error];
        }

        return NO;
    }

    [self willChangeValueForKey:@"state"];
    _state = SolunaReceiverStateReceiving;
    [self didChangeValueForKey:@"state"];

    if ([_delegate respondsToSelector:@selector(receiverDidChange:)]) {
        [_delegate receiverDidChange:_state];
    }

    // Start stats timer
    _statsTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                   target:self
                                                 selector:@selector(updateStats)
                                                 userInfo:nil
                                                  repeats:YES];

    return YES;
}

- (void)stop {
    // Stop mic transmit if active
    [self stopMicTransmit];

    [_statsTimer invalidate];
    _statsTimer = nil;

    if (_impl) {
        _impl->stop();
        _impl.reset();
    }

    [self willChangeValueForKey:@"state"];
    _state = SolunaReceiverStateStopped;
    [self didChangeValueForKey:@"state"];

    if ([_delegate respondsToSelector:@selector(receiverDidChange:)]) {
        [_delegate receiverDidChange:_state];
    }
}

- (void)setVolume:(float)volume {
    _volume = std::max(0.0f, std::min(1.0f, volume));
    if (_impl) _impl->set_volume(_volume);
}

- (BOOL)muted {
    return _impl ? (BOOL)_impl->is_muted() : NO;
}

- (void)setMuted:(BOOL)muted {
    if (_impl) _impl->set_muted((bool)muted);
}

- (uint32_t)bufferTargetMs {
    return _impl ? _impl->buffer_ms() : _bufferTargetMs;
}

- (void)setBufferTargetMs:(uint32_t)ms {
    _bufferTargetMs = std::max(5u, std::min(2000u, ms));
    if (_impl) _impl->set_buffer_ms(_bufferTargetMs);
}

- (SolunaDeviceHealth)deviceHealth {
    return _impl ? (SolunaDeviceHealth)_impl->device_health() : SolunaDeviceHealthGood;
}

- (BOOL)networkDisabled {
    return _impl ? (BOOL)_impl->is_network_disabled() : NO;
}

- (void)setNetworkDisabled:(BOOL)disabled {
    if (_impl) _impl->set_filesync_network_disabled((bool)disabled);
}

- (BOOL)filesyncNetworkDisabled {
    return _impl ? (BOOL)_impl->is_filesync_network_disabled() : NO;
}

- (void)setFilesyncNetworkDisabled:(BOOL)disabled {
    if (_impl) _impl->set_filesync_network_disabled((bool)disabled);
}

- (SolunaReceiverStats *)currentStats {
    if (_impl) {
        auto stats = _impl->stats();
        return [[SolunaReceiverStats alloc] initWithStats:stats];
    }
    return [[SolunaReceiverStats alloc] init];
}

- (void)updateStats {
    if ([_delegate respondsToSelector:@selector(receiverDidUpdate:)]) {
        [_delegate receiverDidUpdate:[self currentStats]];
    }
    // Send pipeline state to Mac debug server
    if (_impl) {
        static int dbg_sock2 = -1;
        static struct sockaddr_in dbg_addr2 = {};
        if (dbg_sock2 < 0) {
            dbg_sock2 = socket(AF_INET, SOCK_DGRAM, 0);
            dbg_addr2.sin_family = AF_INET;
            dbg_addr2.sin_port = htons(9999);
            inet_pton(AF_INET, "192.168.0.194", &dbg_addr2.sin_addr);
        }
        size_t rb = _impl->ring_buffer_available_read();
        uint32_t tgt = _impl->get_target_fill_frames();
        int hp = _impl->device_health();
        bool pf = _impl->is_prefilled();
        bool sil = _impl->is_health_silenced();
        bool rel = _impl->is_network_disabled();
        bool fp = _impl->is_relay_first_packet();
        float vol = _impl->get_volume();
        float peak = _impl->output_peak();
        char buf[256];
        snprintf(buf, sizeof(buf),
                 "PIPE: RB=%zu tgt=%u hp=%d pf=%d sil=%d rel=%d fp=%d vol=%.2f peak=%.4f",
                 rb, tgt, hp, pf, sil, rel, fp, vol, peak);
        sendto(dbg_sock2, buf, strlen(buf), 0,
               (struct sockaddr*)&dbg_addr2, sizeof(dbg_addr2));
    }
}

// ── P2P Relay ───────────────────────────────────────────────────────────────

- (void)setRelayCallback:(nullable void(^)(NSData *))callback {
    if (_impl) {
        if (callback) {
            _impl->set_relay_callback([callback](const uint8_t* data, size_t len) {
                NSData *packet = [NSData dataWithBytes:data length:len];
                callback(packet);
            });
        } else {
            _impl->set_relay_callback(nullptr);
        }
    }
}

- (void)setMetaCallback:(nullable void(^)(NSString *))callback {
    if (_impl) {
        if (callback) {
            _impl->wan_relay_set_meta_callback([callback](const std::string& json) {
                NSString *str = [NSString stringWithUTF8String:json.c_str()];
                dispatch_async(dispatch_get_main_queue(), ^{
                    callback(str);
                });
            });
        } else {
            _impl->wan_relay_set_meta_callback(nullptr);
        }
    }
}

- (void)setFileCallback:(nullable void(^)(NSString *))callback {
    if (_impl) {
        if (callback) {
            _impl->wan_relay_set_file_callback([callback](const std::string& filename) {
                NSString *str = [NSString stringWithUTF8String:filename.c_str()];
                dispatch_async(dispatch_get_main_queue(), ^{
                    callback(str);
                });
            });
        } else {
            _impl->wan_relay_set_file_callback(nullptr);
        }
    }
}

- (void)setSyncCallback:(nullable void(^)(NSString *))callback {
    if (_impl) {
        if (callback) {
            _impl->wan_relay_set_sync_callback([callback](const std::string& sync) {
                NSString *str = [NSString stringWithUTF8String:sync.c_str()];
                dispatch_async(dispatch_get_main_queue(), ^{
                    callback(str);
                });
            });
        } else {
            _impl->wan_relay_set_sync_callback(nullptr);
        }
    }
}

- (void)sendReady:(NSString *)filename {
    if (_impl) {
        _impl->wan_relay_send_ready(std::string(filename.UTF8String));
    }
}

- (void)injectRawPacket:(NSData *)data {
    if (_impl && data.length > 0) {
        _impl->inject_raw_packet(static_cast<const uint8_t*>(data.bytes), data.length);
    }
}

- (void)injectPcmSamples:(NSData *)data frameCount:(NSUInteger)frameCount {
    if (_impl && data.length > 0) {
        _impl->inject_pcm_samples(static_cast<const int32_t*>(data.bytes), frameCount);
    }
}

- (void)flushRingBuffer {
    if (_impl) {
        _impl->flush_ring_buffer();
    }
}

// ── WAN Relay ───────────────────────────────────────────────────────────────

- (BOOL)connectToRelay:(NSString *)host port:(uint16_t)port
                 group:(NSString *)group password:(NSString *)password {
    return [self connectToRelay:host port:port group:group password:password deviceId:@""];
}

- (BOOL)connectToRelay:(NSString *)host port:(uint16_t)port
                 group:(NSString *)group password:(NSString *)password
              deviceId:(NSString *)deviceId {
    if (!_impl) return NO;
    auto* impl = _impl.get();
    bool ok = impl->wan_relay_connect(
        std::string([host UTF8String]), port,
        std::string([group UTF8String]),
        std::string([password UTF8String]),
        std::string([deviceId UTF8String]));
    if (ok && _txImpl) {
        _txImpl->tx_relay_callback = [impl](const uint8_t* data, size_t len) {
            impl->wan_relay_send_audio(data, len);
        };
    }
    return ok ? YES : NO;
}

- (void)sendMicAllow:(NSString *)deviceId {
    if (_impl) _impl->wan_relay_mic_allow(std::string([deviceId UTF8String]));
}

- (void)sendMicDeny:(NSString *)deviceId {
    if (_impl) _impl->wan_relay_mic_deny(std::string([deviceId UTF8String]));
}

- (void)requestMicList {
    if (_impl) _impl->wan_relay_mic_list();
}

- (void)requestMembers {
    if (_impl) _impl->wan_relay_members();
}

- (void)sendVolumeToDevice:(NSString *)deviceId level:(int)level {
    if (_impl) _impl->wan_relay_send_volume(std::string([deviceId UTF8String]), level);
}

- (void)disconnectRelay {
    if (_impl) _impl->wan_relay_disconnect();
    if (_txImpl) _txImpl->tx_relay_callback = nullptr;
}

- (void)sendAudioViaWanRelay:(NSData *)data {
    if (_impl) _impl->wan_relay_send_audio(
        static_cast<const uint8_t*>(data.bytes), data.length);
}

- (SolunaRelayState)relayState {
    if (!_impl) return SolunaRelayStateDisconnected;
    switch (_impl->wan_relay_state()) {
        case WanRelayClient::State::Connecting:   return SolunaRelayStateConnecting;
        case WanRelayClient::State::Connected:     return SolunaRelayStateConnected;
        case WanRelayClient::State::Error:         return SolunaRelayStateError;
        default:                                   return SolunaRelayStateDisconnected;
    }
}

- (NSString *)relayGroup {
    if (!_impl) return nil;
    auto g = _impl->wan_relay_group();
    return g.empty() ? nil : [NSString stringWithUTF8String:g.c_str()];
}

- (NSString *)relayError {
    if (!_impl) return nil;
    auto e = _impl->wan_relay_error();
    return e.empty() ? nil : [NSString stringWithUTF8String:e.c_str()];
}

- (NSString *)relayExternalAddr {
    if (!_impl) return nil;
    auto a = _impl->wan_relay_external_addr();
    return a.empty() ? nil : [NSString stringWithUTF8String:a.c_str()];
}

- (NSString *)debugLog {
    if (!_impl) return @"impl=nil";
    auto log = _impl->wan_relay_debug_log();
    // Append audio pipeline state
    size_t rb_avail = _impl->ring_buffer_available_read();
    uint32_t target = _impl->get_target_fill_frames();
    int health = _impl->device_health();
    bool prefilled = _impl->is_prefilled();
    bool silenced = _impl->is_health_silenced();
    bool relay_dis = _impl->is_network_disabled();
    float vol = _impl->get_volume();
    char extra[256];
    snprintf(extra, sizeof(extra),
             "\nRB:%zu tgt:%u hp:%d pf:%d sil:%d rel:%d vol:%.2f",
             rb_avail, target, health, prefilled, silenced, relay_dis, vol);
    log += extra;
    return [NSString stringWithUTF8String:log.c_str()];
}

// ── Sync Mode ───────────────────────────────────────────────────────────────

- (BOOL)syncMode {
    return _impl ? _impl->is_sync_mode() : NO;
}

- (void)setSyncMode:(BOOL)syncMode {
    if (_impl) _impl->set_sync_mode(syncMode);
}

- (uint32_t)syncDelayMs {
    return _impl ? _impl->get_sync_delay_ms() : 200;
}

- (void)setSyncDelayMs:(uint32_t)syncDelayMs {
    if (_impl) _impl->set_sync_delay_ms(syncDelayMs);
}

// ── Talk Mode (multi-speaker) ────────────────────────────────────────────────

- (void)setTalkMode:(BOOL)enabled {
    if (_impl) {
        _impl->set_talk_mode(enabled);
    }
}

// ── Mic Transmit (TX) ───────────────────────────────────────────────────────

- (BOOL)isMicTransmitting {
    return _txImpl && _txImpl->is_running();
}

- (uint64_t)txPacketsSent {
    return _txImpl ? _txImpl->packets_sent() : 0;
}

- (float)micInputLevel {
    return _txImpl ? _txImpl->peak_level() : 0.0f;
}

- (float)outputPeakLevel {
    return _impl ? _impl->output_peak() : 0.0f;
}

- (BOOL)startMicTransmit {
    if (_txImpl && _txImpl->is_running()) return YES;

    // Note: AVAudioSession category is managed by Swift (AudioReceiver.toggleMic)
    // to avoid triggering interruption notifications.

    // Default: LAN multicast. If _micGlobal is set, send to relay instead.
    std::string dest_ip = std::string([_multicastGroup UTF8String]);
    uint16_t dest_port = _port;
    if (_micGlobal) {
        // Use relay IP directly (DNS resolution in audio thread is unreliable)
        dest_ip = "46.225.77.119";
        dest_port = 5100;
    }
    fprintf(stderr, "[SolunaTx] Mic TX to %s: %s:%u\n",
            _micGlobal ? "RELAY" : "LAN", dest_ip.c_str(), dest_port);

    _txImpl = std::make_unique<TransmitterImpl>(
        dest_ip,
        dest_port,
        _channels
    );

    // Wire up relay callback so mic audio goes through WAN relay
    if (_impl) {
        auto impl = _impl.get();
        _txImpl->tx_relay_callback = [impl](const uint8_t* data, size_t len) {
            impl->wan_relay_send_audio(data, len);
        };
        fprintf(stderr, "[SolunaTx] Relay callback wired for mic TX\n");
    }

    if (!_txImpl->start()) {
        fprintf(stderr, "[SolunaTx] Failed to start transmitter\n");
        _txImpl.reset();
        return NO;
    }

    fprintf(stderr, "[SolunaTx] Mic transmit started (global=%d)\n", _micGlobal);
    return YES;
}

// ── Karaoke mode: mic + music mixed on device, sent as 1 stream to relay ──
// No local monitoring (avoids howling). Listeners hear the mix via relay.

- (BOOL)startMicMonitor {
    // In karaoke/broadcast mode, just enable mic transmit to relay.
    // The TransmitterImpl's tx_relay_callback sends to relay.
    // Listeners receive: radio audio + mic audio as 2 SSRCs,
    // but relay's TALK mode makes this work.
    //
    // For now: just enable Global mic mode (send mic to relay).
    // The receiver side only plays 1 SSRC at a time (the loudest/latest).
    _micGlobal = YES;
    return [self startMicTransmit];
}

- (void)stopMicMonitor {
    [self stopMicTransmit];
}

- (void)stopMicTransmit {
    if (_txImpl) {
        _txImpl->stop();
        _txImpl.reset();
    }

    // Note: AVAudioSession restore is managed by Swift (AudioReceiver.toggleMic)
    fprintf(stderr, "[SolunaTx] Mic transmit stopped\n");
}

// ── Network Quality Stats ───────────────────────────────────────────────────

- (float)networkLatencyMs {
    if (!_impl) return 0;
    // Approximate latency from ring buffer fill depth (at 48kHz)
    size_t fill = _impl->ring_buffer_available_read();
    return (float)fill / 48.0f;
}

- (float)jitterMs {
    if (!_impl) return 0;
    // Approximate jitter from difference between actual and target buffer fill
    size_t fill = _impl->ring_buffer_available_read();
    uint32_t target = _impl->get_target_fill_frames();
    int32_t diff = (int32_t)fill - (int32_t)target;
    return fabsf((float)diff / 48.0f);
}

- (float)packetLossPercent {
    if (!_impl || !_impl->has_rtp_receiver()) return 0;
    auto st = _impl->get_rtp_stats();
    if (st.packets_received == 0) return 0;
    uint64_t total = st.packets_received + st.packets_dropped;
    return (float)st.packets_dropped / (float)total * 100.0f;
}

// ── Loudness Normalization ──────────────────────────────────────────────────

- (void)setLoudnessNormEnabled:(BOOL)enabled {
    if (_impl) _impl->set_loudness_norm(enabled);
}

- (BOOL)loudnessNormEnabled {
    return _impl ? _impl->is_loudness_norm() : NO;
}

// ── Output Latency Compensation ─────────────────────────────────────────────

- (void)setOutputLatencyMs:(float)ms {
    if (_impl) _impl->set_output_latency_ms(ms);
}

- (float)outputLatencyMs {
    return _impl ? _impl->get_output_latency_ms() : 0.0f;
}

// ── Spatial Audio (AirPods Head Tracking) ───────────────────────────────────

- (void)setSpatialAudioEnabled:(BOOL)enabled {
    if (enabled && !_headphoneMotion) {
        _headphoneMotion = [[CMHeadphoneMotionManager alloc] init];
        if (_headphoneMotion.isDeviceMotionAvailable) {
            [_headphoneMotion startDeviceMotionUpdates];
            fprintf(stderr, "[SolunaRx] Spatial audio: head tracking started\n");
        } else {
            fprintf(stderr, "[SolunaRx] Spatial audio: head tracking not available\n");
            _headphoneMotion = nil;
        }
    } else if (!enabled && _headphoneMotion) {
        [_headphoneMotion stopDeviceMotionUpdates];
        _headphoneMotion = nil;
        fprintf(stderr, "[SolunaRx] Spatial audio: head tracking stopped\n");
    }
}

- (BOOL)spatialAudioEnabled {
    return _headphoneMotion != nil;
}

// ── 3-Band EQ ───────────────────────────────────────────────────────────────

- (void)setEQBand:(int)band gain:(float)gainDb {
    if (_impl) _impl->set_eq(band, gainDb);
}

// ── Compressor ──────────────────────────────────────────────────────────────

- (void)setCompressorThreshold:(float)thresh ratio:(float)ratio attack:(float)attackMs release:(float)releaseMs enabled:(BOOL)enabled {
    if (_impl) _impl->set_compressor(thresh, ratio, attackMs, releaseMs, enabled);
}

// ── Recording ───────────────────────────────────────────────────────────────

- (BOOL)startRecordingToFile:(NSString *)path {
    if (_isRecording) return NO;

    NSURL *url = [NSURL fileURLWithPath:path];
    uint32_t ch = _channels;

    // Client (input) format: 32-bit float interleaved
    AudioStreamBasicDescription clientFormat = {};
    clientFormat.mSampleRate = 48000;
    clientFormat.mFormatID = kAudioFormatLinearPCM;
    clientFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    clientFormat.mBitsPerChannel = 32;
    clientFormat.mChannelsPerFrame = ch;
    clientFormat.mFramesPerPacket = 1;
    clientFormat.mBytesPerFrame = ch * 4;
    clientFormat.mBytesPerPacket = ch * 4;

    // File format: 16-bit WAV
    AudioStreamBasicDescription fileFormat = {};
    fileFormat.mSampleRate = 48000;
    fileFormat.mFormatID = kAudioFormatLinearPCM;
    fileFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    fileFormat.mBitsPerChannel = 16;
    fileFormat.mChannelsPerFrame = ch;
    fileFormat.mFramesPerPacket = 1;
    fileFormat.mBytesPerFrame = ch * 2;
    fileFormat.mBytesPerPacket = ch * 2;

    OSStatus status = ExtAudioFileCreateWithURL(
        (__bridge CFURLRef)url,
        kAudioFileWAVEType,
        &fileFormat,
        nullptr,
        kAudioFileFlags_EraseFile,
        &_recordFile
    );
    if (status != noErr) return NO;

    status = ExtAudioFileSetProperty(
        _recordFile,
        kExtAudioFileProperty_ClientDataFormat,
        sizeof(clientFormat),
        &clientFormat
    );
    if (status != noErr) {
        ExtAudioFileDispose(_recordFile);
        _recordFile = nullptr;
        return NO;
    }

    _isRecording = YES;

    // Set record callback on impl
    ExtAudioFileRef file = _recordFile;
    _impl->set_record_callback([file, ch](const float* samples, uint32_t count) {
        AudioBufferList abl;
        abl.mNumberBuffers = 1;
        abl.mBuffers[0].mNumberChannels = ch;
        abl.mBuffers[0].mDataByteSize = count * sizeof(float);
        abl.mBuffers[0].mData = (void*)samples;
        UInt32 frames = count / ch;
        ExtAudioFileWriteAsync(file, frames, &abl);
    });

    return YES;
}

- (void)stopRecording {
    if (!_isRecording) return;
    _isRecording = NO;

    if (_impl) {
        _impl->set_record_callback(nullptr);
    }

    if (_recordFile) {
        ExtAudioFileDispose(_recordFile);
        _recordFile = nullptr;
    }
}

- (BOOL)isRecording {
    return _isRecording;
}

// ── DJ Mode ─────────────────────────────────────────────────────────────────

- (BOOL)startDJBroadcast:(NSString *)filePath {
    if (_djImpl && _djImpl->is_running()) return NO;
    if (!_impl) return NO;

    // Ensure WAN relay is connected — DJ mode requires relay
    WanRelayClient* relay = _impl->wan_relay_.get();
    if (!relay || relay->state() != WanRelayClient::State::Connected) {
        fprintf(stderr, "[SolunaDJ] Cannot start: relay not connected\n");
        return NO;
    }

    _djImpl = std::make_unique<DJBroadcaster>(relay);
    if (!_djImpl->start(std::string(filePath.UTF8String))) {
        _djImpl.reset();
        return NO;
    }
    return YES;
}

- (void)stopDJ {
    if (_djImpl) {
        _djImpl->stop();
        _djImpl.reset();
    }
}

- (void)skipDJTrack {
    if (_djImpl) _djImpl->skip();
}

- (BOOL)isDJActive {
    return _djImpl && _djImpl->is_running();
}

- (NSString *)djCurrentTrack {
    if (!_djImpl) return nil;
    auto name = _djImpl->track_name();
    return name.empty() ? nil : @(name.c_str());
}

- (float)djProgress {
    return _djImpl ? _djImpl->progress() : 0.0f;
}

// ── DJ Mic Mix ──────────────────────────────────────────────────────────────

- (void)setDjMicMixEnabled:(BOOL)enabled {
    if (_djImpl) _djImpl->set_mic_mix(enabled);
}

- (BOOL)djMicMixEnabled {
    return _djImpl ? _djImpl->mic_mix_enabled_.load() : NO;
}

- (void)setDjMicGain:(float)gain {
    if (_djImpl) _djImpl->mic_gain_.store(gain, std::memory_order_relaxed);
}

- (float)djMicGain {
    return _djImpl ? _djImpl->mic_gain_.load(std::memory_order_relaxed) : 1.0f;
}

- (void)setDjMusicGain:(float)gain {
    if (_djImpl) _djImpl->music_gain_.store(gain, std::memory_order_relaxed);
}

- (float)djMusicGain {
    return _djImpl ? _djImpl->music_gain_.load(std::memory_order_relaxed) : 0.7f;
}

// ── DJ Dual-Deck Mode ────────────────────────────────────────────────────────

- (BOOL)startDeckA:(NSString *)filePath {
    if (!_impl) return NO;
    WanRelayClient* relay = _impl->wan_relay_.get();
    if (!relay || relay->state() != WanRelayClient::State::Connected) {
        fprintf(stderr, "[DJCtrl] Cannot start deck A: relay not connected\n");
        return NO;
    }
    if (!_djCtrlImpl) _djCtrlImpl = std::make_unique<DJController>(relay);
    return _djCtrlImpl->start_deck_a(filePath.UTF8String) ? YES : NO;
}

- (BOOL)startDeckB:(NSString *)filePath {
    if (!_impl) return NO;
    WanRelayClient* relay = _impl->wan_relay_.get();
    if (!relay || relay->state() != WanRelayClient::State::Connected) {
        fprintf(stderr, "[DJCtrl] Cannot start deck B: relay not connected\n");
        return NO;
    }
    if (!_djCtrlImpl) _djCtrlImpl = std::make_unique<DJController>(relay);
    return _djCtrlImpl->start_deck_b(filePath.UTF8String) ? YES : NO;
}

- (void)toggleDeckA {
    if (_djCtrlImpl) _djCtrlImpl->toggle_deck_a();
}

- (void)toggleDeckB {
    if (_djCtrlImpl) _djCtrlImpl->toggle_deck_b();
}

- (void)stopDualDeck {
    _djCtrlImpl.reset();
}

- (void)setDjCrossfader:(float)v {
    if (_djCtrlImpl) _djCtrlImpl->set_crossfader(v);
}

- (float)djCrossfader {
    return _djCtrlImpl ? _djCtrlImpl->get_crossfader() : 0.5f;
}

- (BOOL)isDualDeckActive {
    return _djCtrlImpl && _djCtrlImpl->is_active() ? YES : NO;
}

- (NSString *)deckATrack {
    if (!_djCtrlImpl) return nil;
    auto name = _djCtrlImpl->deck_a_track();
    return name.empty() ? nil : @(name.c_str());
}

- (NSString *)deckBTrack {
    if (!_djCtrlImpl) return nil;
    auto name = _djCtrlImpl->deck_b_track();
    return name.empty() ? nil : @(name.c_str());
}

- (float)deckAProgress {
    return _djCtrlImpl ? _djCtrlImpl->deck_a_progress() : 0.0f;
}

- (float)deckBProgress {
    return _djCtrlImpl ? _djCtrlImpl->deck_b_progress() : 0.0f;
}

- (BOOL)deckAPlaying {
    return _djCtrlImpl && _djCtrlImpl->deck_a_playing() ? YES : NO;
}

- (BOOL)deckBPlaying {
    return _djCtrlImpl && _djCtrlImpl->deck_b_playing() ? YES : NO;
}

// ── Sample Tap (for fingerprinting) ─────────────────────────────────────────

- (void)setSampleTapCallback:(nullable void(^)(const float * _Nonnull samples, uint32_t sampleCount, uint32_t channels))callback {
    if (!_impl) return;
    if (callback) {
        auto block = [callback](const float* samples, uint32_t count, uint32_t ch) {
            callback(samples, count, ch);
        };
        _impl->set_sample_tap_callback(block);
    } else {
        _impl->set_sample_tap_callback(nullptr);
    }
}

@end
