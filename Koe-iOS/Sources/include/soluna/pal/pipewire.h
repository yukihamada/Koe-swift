#pragma once
#ifdef SOLUNA_HAS_PIPEWIRE

#include <cstdint>
#include <string>

namespace soluna::pal {

class PipeWireAudioSink {
public:
    struct Config {
        uint32_t sample_rate = 48000;
        uint32_t channels = 1;
        uint32_t frames_per_buffer = 480;
        std::string stream_name = "Soluna";
    };

    PipeWireAudioSink();
    ~PipeWireAudioSink();

    bool open(const Config& cfg);
    void close();

    // Write interleaved int32_t samples (24-bit range)
    // Returns number of frames written
    size_t write(const int32_t* data, size_t frames);

    bool is_open() const;

private:
    struct Impl;
    Impl* impl_ = nullptr;
};

} // namespace soluna::pal
#endif // SOLUNA_HAS_PIPEWIRE
