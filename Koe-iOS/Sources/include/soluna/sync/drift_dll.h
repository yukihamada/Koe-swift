#pragma once

/**
 * Delay-Locked Loop for clock drift estimation.
 *
 * Based on Fons Adriaensen's "Using a DLL to filter time" (2005).
 * Estimates the true sample rate of an audio clock from noisy,
 * block-level timestamps.
 *
 * Usage:
 *   1. Call init() with nominal sample rate and block size.
 *   2. On each audio callback, call update() with the system timestamp.
 *   3. Read ratio() to get the resampling ratio (1.0 = no drift).
 *
 * The DLL bandwidth is very narrow (default 0.01) so it reacts slowly
 * and smoothly — no audible pitch wobble.
 *
 * SPDX-License-Identifier: MIT
 */

#include <cmath>
#include <cstdint>

namespace soluna::sync {

class DriftDLL {
public:
    /**
     * Initialize the DLL.
     *
     * @param nominal_rate  Expected sample rate (e.g., 48000)
     * @param block_size    Audio callback size in frames (e.g., 480)
     * @param bandwidth     DLL bandwidth in Hz (default 0.01 — very smooth)
     *                      Lower = smoother but slower to converge.
     *                      SonoBus uses 0.008; we use 0.01 for slightly
     *                      faster convergence while still being inaudible.
     */
    void init(double nominal_rate, uint32_t block_size, double bandwidth = 0.01) {
        nominal_rate_ = nominal_rate;
        block_size_ = block_size;
        nominal_period_ = static_cast<double>(block_size) / nominal_rate;

        // DLL coefficients (2nd-order critically damped)
        double omega = 2.0 * M_PI * bandwidth * nominal_period_;
        b_ = omega * M_SQRT2;  // sqrt(2) * omega
        c_ = omega * omega;

        reset();
    }

    /**
     * Reset DLL state (call when stream restarts).
     */
    void reset() {
        initialized_ = false;
        t0_ = 0.0;
        t1_ = 0.0;
        e2_ = nominal_period_;
        ratio_ = 1.0;
        samples_processed_ = 0;
    }

    /**
     * Update the DLL with a new timestamp.
     * Call once per audio callback with the current system time in seconds.
     *
     * @param timestamp_sec  Monotonic system time in seconds (e.g., from
     *                       clock_gettime(CLOCK_MONOTONIC) or mach_absolute_time)
     * @return Current ratio estimate
     */
    double update(double timestamp_sec) {
        if (!initialized_) {
            // First callback: initialize state
            t0_ = timestamp_sec;
            t1_ = t0_ + nominal_period_;
            e2_ = nominal_period_;
            initialized_ = true;
            samples_processed_ = block_size_;
            return 1.0;
        }

        // Second-order DLL update
        double e = timestamp_sec - t1_;  // timing error

        // Safety: ignore wildly wrong timestamps (>10x nominal period)
        if (std::fabs(e) > nominal_period_ * 10.0) {
            // Reset on large discontinuity
            t0_ = timestamp_sec;
            t1_ = t0_ + nominal_period_;
            e2_ = nominal_period_;
            return ratio_;
        }

        t0_ = t1_;
        t1_ += b_ * e + e2_;            // predicted next callback time
        e2_ += c_ * e;                  // filtered period estimate

        samples_processed_ += block_size_;

        // Calculate ratio: actual rate vs nominal rate
        // e2_ is the estimated period between callbacks (in seconds)
        // If e2_ > nominal_period_, the clock is slower → ratio > 1 (read more)
        // If e2_ < nominal_period_, the clock is faster → ratio < 1 (read less)
        double estimated_rate = static_cast<double>(block_size_) / e2_;
        ratio_ = nominal_rate_ / estimated_rate;

        // Clamp ratio to reasonable bounds (±500 ppm)
        if (ratio_ < 0.9995) ratio_ = 0.9995;
        if (ratio_ > 1.0005) ratio_ = 1.0005;

        return ratio_;
    }

    /**
     * Get the current resampling ratio.
     * 1.0 = no drift. >1.0 = source is faster, need to read more.
     * <1.0 = source is slower, need to read less.
     */
    double ratio() const { return ratio_; }

    /**
     * Get the estimated actual sample rate.
     */
    double estimated_rate() const {
        return (e2_ > 0.0) ? static_cast<double>(block_size_) / e2_ : nominal_rate_;
    }

    /**
     * Get the estimated period between callbacks (seconds).
     */
    double estimated_period() const { return e2_; }

    /**
     * Check if DLL has converged (after enough samples).
     * Convergence typically takes ~2-5 seconds.
     */
    bool converged() const {
        return samples_processed_ > static_cast<uint64_t>(nominal_rate_ * 2.0);
    }

    bool is_initialized() const { return initialized_; }

private:
    double nominal_rate_ = 48000.0;
    double nominal_period_ = 0.01;   // block_size / rate
    uint32_t block_size_ = 480;

    // DLL coefficients
    double b_ = 0.0;
    double c_ = 0.0;

    // DLL state
    bool initialized_ = false;
    double t0_ = 0.0;   // previous callback time
    double t1_ = 0.0;   // predicted current callback time
    double e2_ = 0.0;   // filtered period estimate

    double ratio_ = 1.0;
    uint64_t samples_processed_ = 0;
};

} // namespace soluna::sync
