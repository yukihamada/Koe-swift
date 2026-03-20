#pragma once

/**
 * DLNA/UPnP Media Renderer — Receive audio from DLNA control points
 *
 * Implements a UPnP AV MediaRenderer device that:
 * - Responds to SSDP M-SEARCH discovery (239.255.255.250:1900)
 * - Serves UPnP device/service description XML
 * - Handles SOAP control actions (AVTransport, RenderingControl)
 * - Fetches audio via HTTP GET and feeds into the audio pipeline
 *
 * Supported formats: audio/L16, audio/L24, audio/x-flac, audio/mpeg
 *
 * No external XML library required — uses string templates.
 *
 * SPDX-License-Identifier: MIT
 */

#ifdef SOLUNA_HAS_DLNA

#include <soluna/soluna.h>
#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <thread>

namespace soluna::transport {

// SSDP multicast address and port
constexpr const char* kSsdpMulticastAddr = "239.255.255.250";
constexpr uint16_t    kSsdpPort          = 1900;

// DLNA transport states
enum class DlnaTransportState {
    NoMediaPresent,
    Stopped,
    Playing,
    PausedPlayback,
    Transitioning,
};

const char* dlna_transport_state_str(DlnaTransportState state);

// DLNA transport status
enum class DlnaTransportStatus {
    OK,
    ErrorOccurred,
};

/**
 * Audio data callback — called when decoded audio is available.
 *
 * @param samples   Interleaved 32-bit signed integer samples (S24 in S32 container)
 * @param frames    Number of frames (samples / channels)
 * @param channels  Channel count
 * @param rate      Sample rate in Hz
 */
using DlnaAudioCallback = std::function<void(const int32_t* samples, size_t frames,
                                              uint32_t channels, uint32_t rate)>;

/**
 * DlnaRenderer — UPnP AV Media Renderer
 *
 * Provides SSDP discovery, HTTP description/control server, and audio
 * stream reception. Feed received audio into the existing pipeline via
 * the audio callback.
 */
class DlnaRenderer {
public:
    struct Config {
        std::string friendly_name = "Soluna";
        std::string manufacturer  = "Soluna Project";
        std::string model_name    = "Soluna Audio Renderer";
        uint16_t    http_port     = 0;  // 0 = auto-assign
        uint32_t    sample_rate   = 48000;
        uint32_t    channels      = 2;
    };

    DlnaRenderer();
    ~DlnaRenderer();

    DlnaRenderer(const DlnaRenderer&) = delete;
    DlnaRenderer& operator=(const DlnaRenderer&) = delete;

    /**
     * Start the DLNA renderer.
     *
     * @param config          Renderer configuration
     * @param audio_callback  Called when decoded audio frames are available
     * @return true if started successfully
     */
    bool start(const Config& config, DlnaAudioCallback audio_callback);

    /**
     * Stop the DLNA renderer and clean up.
     */
    void stop();

    /**
     * Check if the renderer is running.
     */
    bool is_running() const;

    /**
     * Get the HTTP port the control server is listening on.
     */
    uint16_t http_port() const;

    /**
     * Get the current transport state.
     */
    DlnaTransportState transport_state() const;

    /**
     * Get the current volume (0-100).
     */
    int volume() const;

    /**
     * Get the mute state.
     */
    bool muted() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace soluna::transport

#endif // SOLUNA_HAS_DLNA
