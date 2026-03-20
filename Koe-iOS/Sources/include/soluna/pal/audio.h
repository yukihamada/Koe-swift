#pragma once

#include <soluna/soluna.h>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace soluna::pal {

/// Transport type of an audio device
enum class TransportType : uint8_t {
    BuiltIn   = 0,
    USB       = 1,
    Bluetooth = 2,
    AirPlay   = 3,
    Virtual   = 4,
    Unknown   = 255
};

struct AudioDeviceInfo {
    std::string id;
    std::string name;
    uint32_t max_input_channels;
    uint32_t max_output_channels;
    std::vector<uint32_t> supported_sample_rates;
    TransportType transport_type = TransportType::Unknown;
    uint32_t hardware_latency_frames = 0;
    uint32_t safety_offset_frames = 0;
};

struct AudioStreamConfig {
    uint32_t sample_rate = kDefaultSampleRate;
    uint32_t channels = 1;
    uint32_t frames_per_buffer = 48; // 1ms at 48kHz
    SampleFormat format = SampleFormat::S24_LE;
};

// Callback: (buffer, frame_count) -> void
// buffer is interleaved samples
using AudioCallback = std::function<void(float* buffer, uint32_t frame_count)>;

class AudioDevice {
public:
    virtual ~AudioDevice() = default;

    virtual bool open_input(const std::string& device_id, const AudioStreamConfig& config) = 0;
    virtual bool open_output(const std::string& device_id, const AudioStreamConfig& config) = 0;
    virtual void close() = 0;

    virtual bool start(AudioCallback callback) = 0;
    virtual void stop() = 0;

    virtual bool is_running() const = 0;
    virtual const AudioStreamConfig& config() const = 0;

    static std::vector<AudioDeviceInfo> enumerate();
    static std::unique_ptr<AudioDevice> create();
};

} // namespace soluna::pal
