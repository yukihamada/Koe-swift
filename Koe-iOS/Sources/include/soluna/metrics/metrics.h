#pragma once

/**
 * Soluna — Metrics Types
 *
 * Prometheus-compatible metric types for operational monitoring.
 *
 * SPDX-License-Identifier: MIT
 */

#include <atomic>
#include <chrono>
#include <cstdint>
#include <string>
#include <vector>
#include <map>
#include <mutex>
#include <memory>

namespace soluna {
namespace metrics {

/**
 * Metric type identifiers.
 */
enum class MetricType {
    Counter,
    Gauge,
    Histogram,
    Summary,
};

/**
 * Label pair for metric dimensions.
 */
struct Label {
    std::string name;
    std::string value;
};

using Labels = std::vector<Label>;

/**
 * Base metric interface.
 */
class Metric {
public:
    Metric(std::string name, std::string help, MetricType type)
        : name_(std::move(name)), help_(std::move(help)), type_(type) {}

    virtual ~Metric() = default;

    const std::string& name() const { return name_; }
    const std::string& help() const { return help_; }
    MetricType type() const { return type_; }

    /**
     * Format metric as Prometheus text format.
     */
    virtual std::string format() const = 0;

protected:
    std::string name_;
    std::string help_;
    MetricType type_;
};

/**
 * Counter - monotonically increasing value.
 *
 * Use for: requests, packets, errors, bytes processed.
 */
class Counter : public Metric {
public:
    Counter(std::string name, std::string help)
        : Metric(std::move(name), std::move(help), MetricType::Counter)
        , value_(0) {}

    void inc() { value_.fetch_add(1, std::memory_order_relaxed); }
    void add(uint64_t delta) { value_.fetch_add(delta, std::memory_order_relaxed); }

    uint64_t value() const { return value_.load(std::memory_order_relaxed); }

    std::string format() const override;

private:
    std::atomic<uint64_t> value_;
};

/**
 * Labeled counter - counter with dimension labels.
 */
class LabeledCounter : public Metric {
public:
    LabeledCounter(std::string name, std::string help, std::vector<std::string> label_names)
        : Metric(std::move(name), std::move(help), MetricType::Counter)
        , label_names_(std::move(label_names)) {}

    void inc(const Labels& labels) { add(labels, 1); }
    void add(const Labels& labels, uint64_t delta);

    std::string format() const override;

private:
    std::string labels_to_key(const Labels& labels) const;

    std::vector<std::string> label_names_;
    mutable std::mutex mutex_;
    std::map<std::string, std::pair<Labels, std::atomic<uint64_t>>> values_;
};

/**
 * Gauge - value that can go up and down.
 *
 * Use for: queue length, active connections, temperature.
 */
class Gauge : public Metric {
public:
    Gauge(std::string name, std::string help)
        : Metric(std::move(name), std::move(help), MetricType::Gauge)
        , value_(0.0) {}

    void set(double value) { value_.store(value, std::memory_order_relaxed); }
    void inc() { add(1.0); }
    void dec() { add(-1.0); }
    void add(double delta);

    double value() const { return value_.load(std::memory_order_relaxed); }

    /**
     * Set to current Unix timestamp in seconds.
     */
    void set_to_current_time();

    std::string format() const override;

private:
    std::atomic<double> value_;
};

/**
 * Labeled gauge - gauge with dimension labels.
 */
class LabeledGauge : public Metric {
public:
    LabeledGauge(std::string name, std::string help, std::vector<std::string> label_names)
        : Metric(std::move(name), std::move(help), MetricType::Gauge)
        , label_names_(std::move(label_names)) {}

    void set(const Labels& labels, double value);
    void inc(const Labels& labels) { add(labels, 1.0); }
    void dec(const Labels& labels) { add(labels, -1.0); }
    void add(const Labels& labels, double delta);

    std::string format() const override;

private:
    std::string labels_to_key(const Labels& labels) const;

    std::vector<std::string> label_names_;
    mutable std::mutex mutex_;
    std::map<std::string, std::pair<Labels, std::atomic<double>>> values_;
};

/**
 * Histogram bucket.
 */
struct HistogramBucket {
    double upper_bound;
    std::atomic<uint64_t> count{0};
};

/**
 * Histogram - distribution of values in buckets.
 *
 * Use for: latency, request size.
 */
class Histogram : public Metric {
public:
    /**
     * Create histogram with custom bucket boundaries.
     */
    Histogram(std::string name, std::string help, std::vector<double> bucket_bounds);

    /**
     * Create histogram with default buckets for latency measurement.
     * Buckets: 0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10
     */
    Histogram(std::string name, std::string help);

    /**
     * Observe a value and add it to appropriate buckets.
     */
    void observe(double value);

    /**
     * Get count of all observations.
     */
    uint64_t count() const { return count_.load(std::memory_order_relaxed); }

    /**
     * Get sum of all observed values.
     */
    double sum() const;

    std::string format() const override;

    /**
     * Default latency buckets (in seconds).
     */
    static std::vector<double> default_buckets();

    /**
     * Linear buckets: start, width, count.
     */
    static std::vector<double> linear_buckets(double start, double width, int count);

    /**
     * Exponential buckets: start, factor, count.
     */
    static std::vector<double> exponential_buckets(double start, double factor, int count);

private:
    std::vector<std::unique_ptr<HistogramBucket>> buckets_;
    std::atomic<uint64_t> count_{0};
    std::atomic<double> sum_{0.0};
    mutable std::mutex sum_mutex_;
};

/**
 * Timer helper for histogram - automatically observes duration on destruction.
 */
class Timer {
public:
    explicit Timer(Histogram& histogram)
        : histogram_(histogram)
        , start_(std::chrono::steady_clock::now()) {}

    ~Timer() {
        auto end = std::chrono::steady_clock::now();
        std::chrono::duration<double> elapsed = end - start_;
        histogram_.observe(elapsed.count());
    }

    // Non-copyable, non-movable
    Timer(const Timer&) = delete;
    Timer& operator=(const Timer&) = delete;

private:
    Histogram& histogram_;
    std::chrono::steady_clock::time_point start_;
};

} // namespace metrics
} // namespace soluna
