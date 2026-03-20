#pragma once

/**
 * Clock Servo — PI Controller for PTP clock discipline
 *
 * Adjusts the local clock based on measured offset from master.
 * Uses a proportional-integral controller for smooth convergence.
 *
 * SPDX-License-Identifier: MIT
 */

#include <cstdint>
#include <cmath>

namespace soluna::sync {

struct ClockServoConfig {
    // PI gains (tuned for audio-grade sync)
    double kp = 0.7;      // proportional gain
    double ki = 0.3;       // integral gain

    // Limits
    double max_freq_adj_ppb = 100000.0;  // max frequency adjustment (100 ppm)
    int64_t step_threshold_ns = 100'000'000; // 100ms — step instead of slew
    double filter_weight = 0.1; // exponential moving average weight for offset

    // Convergence detection
    double converged_threshold_ns = 1000.0; // 1us
};

struct ClockServoState {
    double offset_ns = 0.0;           // filtered offset from master (ns)
    double raw_offset_ns = 0.0;       // unfiltered offset
    double freq_adj_ppb = 0.0;        // current frequency adjustment (ppb)
    double integral = 0.0;            // accumulated integral term
    double path_delay_ns = 0.0;       // one-way path delay (ns)
    int64_t step_count = 0;           // number of time steps applied
    int64_t sample_count = 0;         // total samples processed
    bool converged = false;           // offset < threshold for N samples
    int32_t converged_count = 0;      // consecutive samples within threshold
};

class ClockServo {
public:
    explicit ClockServo(const ClockServoConfig& config = {});

    /**
     * Feed a new offset measurement from PTP.
     * offset_ns: measured clock offset (local - master) in nanoseconds
     * Returns the recommended frequency adjustment in ppb.
     */
    double feed_offset(double offset_ns);

    /**
     * Feed a new path delay measurement.
     * delay_ns: measured one-way path delay in nanoseconds
     */
    void feed_delay(double delay_ns);

    /**
     * Check if a time step is needed (offset too large for slew).
     * Returns the step amount in nanoseconds, or 0 if slew is sufficient.
     */
    int64_t check_step(double offset_ns) const;

    /** Reset servo state. */
    void reset();

    const ClockServoState& state() const { return state_; }
    const ClockServoConfig& config() const { return config_; }

private:
    ClockServoConfig config_;
    ClockServoState state_;
};

} // namespace soluna::sync
