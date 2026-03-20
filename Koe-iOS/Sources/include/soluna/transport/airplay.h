#pragma once

/**
 * AirPlay 2 Receiver + Sender
 *
 * Receiver: RTSP server + RTP audio receiver with ALAC decoding.
 *   Advertises _raop._tcp and _airplay._tcp via mDNS (Bonjour on macOS,
 *   Avahi on Linux), accepts RTSP connections from Apple devices, and
 *   decodes ALAC audio into interleaved int16 PCM.
 *
 * Sender (TX): mDNS discovery of AirPlay speakers + RTSP client + RTP
 *   streaming with ALAC encoding.  Discovers local AirPlay speakers via
 *   Bonjour/Avahi, establishes RTSP sessions (ANNOUNCE/SETUP/RECORD),
 *   encodes PCM to ALAC, and streams RTP audio to them.
 *
 * Initial implementation supports UNENCRYPTED connections (pw=false, et=0,1).
 * FairPlay encryption is deferred to a follow-up.
 *
 * SPDX-License-Identifier: OpenSonic-Community-1.0
 */

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace soluna::transport {

// ── ALAC Decoder (minimal, based on Apple ALAC reference, BSD license) ───────

class AlacDecoder {
public:
    AlacDecoder();
    ~AlacDecoder();
    AlacDecoder(AlacDecoder&&) noexcept;
    AlacDecoder& operator=(AlacDecoder&&) noexcept;

    /**
     * Configure the decoder from an RTSP ANNOUNCE SDP fmtp line.
     * Format: "96 352 0 16 40 10 14 2 255 0 0 44100"
     *   frameLength, compatVer, bitDepth, tuningSize, riceHistoryMult,
     *   riceInitialHistory, riceKModifier, numChannels, maxRun, maxFrameBytes,
     *   avgBitRate, sampleRate
     */
    bool configure(const std::string& fmtp);

    /**
     * Configure with explicit parameters.
     */
    bool configure(uint32_t frame_length, uint32_t sample_rate,
                   uint8_t bit_depth, uint8_t num_channels);

    /**
     * Decode one ALAC frame.
     * @param input   compressed ALAC data
     * @param in_len  bytes of compressed data
     * @param output  output buffer (must hold frame_length * channels * sizeof(int16_t))
     * @param out_frames  set to number of decoded frames on success
     * @return true on success
     */
    bool decode(const uint8_t* input, size_t in_len,
                int16_t* output, uint32_t& out_frames);

    uint32_t frame_length() const { return frame_length_; }
    uint32_t sample_rate() const { return sample_rate_; }
    uint8_t  bit_depth() const { return bit_depth_; }
    uint8_t  channels() const { return num_channels_; }

private:
    uint32_t frame_length_  = 352;
    uint32_t sample_rate_   = 44100;
    uint8_t  bit_depth_     = 16;
    uint8_t  num_channels_  = 2;
    bool     configured_    = false;

    // Internal decode state
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

// ── RTSP Session ─────────────────────────────────────────────────────────────

struct AirPlaySession {
    int              client_fd     = -1;
    uint16_t         audio_port    = 0;   // local UDP port for RTP audio
    uint16_t         control_port  = 0;   // local UDP port for control
    uint16_t         timing_port   = 0;   // local UDP port for timing
    uint16_t         remote_audio  = 0;   // client's audio port
    uint16_t         remote_control= 0;   // client's control port
    uint16_t         remote_timing = 0;   // client's timing port
    std::string      client_ip;
    float            volume        = -30.0f; // dB, -144 = mute, 0 = max
    bool             active        = false;
    AlacDecoder      decoder;
};

// ── Audio Callback ───────────────────────────────────────────────────────────

/**
 * Called when decoded PCM audio is available.
 * @param pcm        interleaved int16 PCM samples
 * @param frames     number of audio frames
 * @param channels   number of channels (usually 2)
 * @param sample_rate sample rate (usually 44100)
 */
using AirPlayAudioCallback = std::function<void(
    const int16_t* pcm, uint32_t frames, uint8_t channels, uint32_t sample_rate)>;

// ── AirPlay Receiver ─────────────────────────────────────────────────────────

class AirPlayReceiver {
public:
    AirPlayReceiver();
    ~AirPlayReceiver();

    // Non-copyable
    AirPlayReceiver(const AirPlayReceiver&) = delete;
    AirPlayReceiver& operator=(const AirPlayReceiver&) = delete;

    /**
     * Set the device name shown in AirPlay menus.
     */
    void set_device_name(const std::string& name);

    /**
     * Set the callback for decoded audio.
     */
    void set_audio_callback(AirPlayAudioCallback cb);

    /**
     * Start the AirPlay receiver (mDNS + RTSP server).
     * @param rtsp_port  TCP port for RTSP (default 7000)
     * @return true on success
     */
    bool start(uint16_t rtsp_port = 7000);

    /**
     * Stop the receiver and clean up.
     */
    void stop();

    /**
     * Check if receiver is running.
     */
    bool is_running() const { return running_.load(); }

    /**
     * Get current session info (empty if no client connected).
     */
    std::string client_ip() const;

private:
    // mDNS advertisement
    bool start_mdns(uint16_t rtsp_port);
    void stop_mdns();

    // RTSP server
    void rtsp_accept_loop();
    void rtsp_handle_client(int client_fd, const std::string& client_ip);
    std::string handle_rtsp_request(const std::string& method, const std::string& uri,
                                    const std::string& headers, const std::string& body,
                                    int cseq);

    // RTSP method handlers
    std::string handle_options(int cseq);
    std::string handle_announce(const std::string& body, int cseq);
    std::string handle_setup(const std::string& headers, int cseq);
    std::string handle_record(int cseq);
    std::string handle_set_parameter(const std::string& headers, const std::string& body, int cseq);
    std::string handle_flush(int cseq);
    std::string handle_teardown(int cseq);
    std::string handle_get_info(int cseq);

    // Audio reception
    void audio_receive_loop();

    // Helpers
    std::string get_mac_address() const;
    static uint16_t alloc_udp_port();

    std::string          device_name_ = "Soluna";
    AirPlayAudioCallback audio_callback_;
    std::atomic<bool>    running_{false};
    uint16_t             rtsp_port_ = 7000;
    int                  rtsp_fd_   = -1;

    // mDNS handles (platform-specific)
    struct MdnsState;
    std::unique_ptr<MdnsState> mdns_;

    // Session (single session for now)
    std::mutex           session_mutex_;
    AirPlaySession       session_;

    // Threads
    std::thread          rtsp_thread_;
    std::thread          audio_thread_;
};

// ── ALAC Encoder (minimal, for AirPlay TX) ──────────────────────────────────

class AlacEncoder {
public:
    AlacEncoder();
    ~AlacEncoder();
    AlacEncoder(AlacEncoder&&) noexcept;
    AlacEncoder& operator=(AlacEncoder&&) noexcept;

    /**
     * Configure the encoder.
     */
    bool configure(uint32_t frame_length, uint32_t sample_rate,
                   uint8_t bit_depth, uint8_t num_channels);

    /**
     * Encode one frame of interleaved int16 PCM to ALAC.
     * @param input   interleaved int16 PCM (frame_length * channels samples)
     * @param output  output buffer (must be at least frame_length * channels * 2 + 32 bytes)
     * @param out_len set to number of encoded bytes on success
     * @return true on success
     */
    bool encode(const int16_t* input, uint32_t num_frames,
                uint8_t* output, size_t output_capacity, size_t& out_len);

    uint32_t frame_length() const { return frame_length_; }
    uint32_t sample_rate() const { return sample_rate_; }
    uint8_t  bit_depth() const { return bit_depth_; }
    uint8_t  channels() const { return num_channels_; }

    /** Generate SDP fmtp line for RTSP ANNOUNCE. */
    std::string fmtp_line() const;

private:
    uint32_t frame_length_  = 352;
    uint32_t sample_rate_   = 44100;
    uint8_t  bit_depth_     = 16;
    uint8_t  num_channels_  = 2;
    bool     configured_    = false;
};

// ── Discovered AirPlay Speaker ───────────────────────────────────────────────

struct AirPlaySpeaker {
    std::string name;         // human-readable name (e.g., "Living Room")
    std::string host;         // resolved IP or hostname
    uint16_t    port = 7000;  // RTSP port
    std::string device_id;    // MAC address / device identifier

    // RTSP session state (managed by AirPlaySender)
    int         rtsp_fd    = -1;
    int         audio_fd   = -1;  // UDP socket for RTP audio
    uint16_t    server_audio_port = 0;
    uint16_t    server_control_port = 0;
    uint16_t    server_timing_port = 0;
    uint16_t    local_audio_port = 0;
    uint16_t    local_control_port = 0;
    uint16_t    local_timing_port = 0;
    uint16_t    rtp_seq     = 0;
    uint32_t    rtp_timestamp = 0;
    uint32_t    ssrc        = 0;
    bool        active      = false;
};

// ── AirPlay Sender (TX) ─────────────────────────────────────────────────────

class AirPlaySender {
public:
    AirPlaySender();
    ~AirPlaySender();

    AirPlaySender(const AirPlaySender&) = delete;
    AirPlaySender& operator=(const AirPlaySender&) = delete;

    /**
     * Start mDNS browsing for AirPlay speakers and connect to all found.
     * @return true if browsing started successfully
     */
    bool start();

    /**
     * Stop all sessions and mDNS browsing.
     */
    void stop();

    /**
     * Send PCM audio to all connected AirPlay speakers.
     * Audio is ALAC-encoded and sent as RTP.
     * @param pcm         interleaved int16 PCM samples
     * @param frames      number of audio frames
     * @param channels    number of channels (1 or 2)
     * @param sample_rate sample rate (44100 recommended)
     */
    void send_audio(const int16_t* pcm, uint32_t frames,
                    uint8_t channels, uint32_t sample_rate);

    /**
     * Check if sender is running.
     */
    bool is_running() const { return running_.load(); }

    /**
     * Get list of discovered speakers (thread-safe snapshot).
     */
    std::vector<std::string> discovered_speakers() const;

    /**
     * Get count of currently connected (active) speakers.
     */
    size_t active_speaker_count() const;

    // mDNS browse state (public for C callback access)
    struct BrowseState;

    // Called by mDNS callbacks (public for C function pointer access)
    void on_speaker_found(const std::string& name, const std::string& host, uint16_t port);
    void on_speaker_removed(const std::string& name);

private:
    // mDNS discovery
    bool start_mdns_browse();
    void stop_mdns_browse();

    // RTSP client (connects to a speaker)
    bool rtsp_connect(AirPlaySpeaker& speaker);
    bool rtsp_announce(AirPlaySpeaker& speaker);
    bool rtsp_setup(AirPlaySpeaker& speaker);
    bool rtsp_record(AirPlaySpeaker& speaker);
    void rtsp_teardown(AirPlaySpeaker& speaker);
    std::string rtsp_send_receive(int fd, const std::string& request);

    // RTP audio streaming
    void send_rtp_audio(AirPlaySpeaker& speaker,
                        const uint8_t* alac_data, size_t alac_len);

    // Timing sync (NTP-like)
    void timing_thread_func();

    // Helpers
    static uint16_t alloc_udp_port();
    static uint32_t generate_ssrc();

    std::atomic<bool>  running_{false};
    int                cseq_ = 0;

    // Encoder
    AlacEncoder        encoder_;

    // Discovered speakers
    mutable std::mutex speakers_mutex_;
    std::vector<AirPlaySpeaker> speakers_;

    // mDNS browse state
    std::unique_ptr<BrowseState> browse_;

    // Background threads
    std::thread        browse_thread_;
    std::thread        timing_thread_;
};

} // namespace soluna::transport
