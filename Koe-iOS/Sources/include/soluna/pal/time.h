#pragma once

#include <cstdint>

namespace soluna::pal {

// Nanosecond-resolution timestamp
struct Timestamp {
    int64_t seconds = 0;
    int32_t nanoseconds = 0;

    int64_t to_ns() const {
        return seconds * 1'000'000'000LL + nanoseconds;
    }

    static Timestamp from_ns(int64_t ns) {
        Timestamp t;
        t.seconds = ns / 1'000'000'000LL;
        t.nanoseconds = static_cast<int32_t>(ns % 1'000'000'000LL);
        if (t.nanoseconds < 0) {
            t.seconds--;
            t.nanoseconds += 1'000'000'000;
        }
        return t;
    }
};

class Clock {
public:
    virtual ~Clock() = default;

    // Get current monotonic time (for intervals)
    virtual Timestamp monotonic_now() = 0;

    // Get current realtime (wall clock)
    virtual Timestamp realtime_now() = 0;

    // High-resolution sleep
    virtual void sleep_ns(int64_t ns) = 0;

    // High-resolution sleep until absolute monotonic time
    virtual void sleep_until(const Timestamp& target) = 0;

    static Clock& instance();
};

} // namespace soluna::pal
