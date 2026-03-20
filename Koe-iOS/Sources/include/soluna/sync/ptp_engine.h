#pragma once

/**
 * PTP Engine — PTPv2 state machine and clock synchronization
 *
 * Manages the full PTP protocol lifecycle:
 * - BMCA for master election
 * - Sync / Follow_Up / Delay_Req / Delay_Resp message exchange
 * - Clock offset and path delay calculation
 * - Clock servo integration
 *
 * SPDX-License-Identifier: MIT
 */

#include <soluna/sync/ptp.h>
#include <soluna/sync/clock_servo.h>
#include <soluna/pal/net.h>
#include <soluna/pal/time.h>
#include <soluna/pal/thread.h>

#include <atomic>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace soluna::sync {

enum class PtpRole {
    Listening,   // startup / waiting for announce
    Master,      // this node is grandmaster
    Slave,       // this node is slave
};

struct PtpConfig {
    uint8_t domain = 0;
    uint8_t priority1 = 128;
    uint8_t priority2 = 128;
    PtpClockQuality clock_quality;

    int8_t log_announce_interval = 1;    // 2^1 = 2s
    int8_t log_sync_interval = -3;       // 2^-3 = 125ms
    int8_t log_delay_req_interval = -3;

    uint8_t announce_receipt_timeout = 3; // miss 3 → become master

    std::string interface;  // network interface (optional)
    ClockServoConfig servo_config;
};

struct PtpSyncInfo {
    int64_t offset_ns = 0;           // clock offset (local - master)
    int64_t path_delay_ns = 0;       // one-way delay
    double freq_adj_ppb = 0.0;       // current frequency adjustment
    bool synchronized = false;       // offset < threshold
    PtpRole role = PtpRole::Listening;
    PtpPortIdentity master_id;
    uint64_t sync_count = 0;
};

// Callback when sync state changes
using PtpSyncCallback = std::function<void(const PtpSyncInfo& info)>;

class PtpEngine {
public:
    explicit PtpEngine(const PtpConfig& config = {});
    ~PtpEngine();

    // Non-copyable
    PtpEngine(const PtpEngine&) = delete;
    PtpEngine& operator=(const PtpEngine&) = delete;

    /** Start PTP engine (spawns internal threads). */
    bool start();

    /** Stop PTP engine. */
    void stop();

    /** Get current sync information. */
    PtpSyncInfo sync_info() const;

    /** Get PTP-synchronized timestamp (local clock + offset correction). */
    pal::Timestamp ptp_now() const;

    /**
     * Get media clock timestamp in nanoseconds for AES67 RTP.
     * This returns the current PTP-synchronized time as a 64-bit nanosecond value,
     * suitable for deriving RTP timestamps in AES67 mode.
     */
    int64_t get_media_clock_ns() const;

    /**
     * Convert media clock nanoseconds to RTP timestamp at the given sample rate.
     */
    static uint32_t media_clock_to_rtp_timestamp(int64_t media_clock_ns, uint32_t sample_rate);

    /** Set callback for sync state changes. */
    void set_sync_callback(PtpSyncCallback cb);

    /** Get local port identity. */
    const PtpPortIdentity& local_port_id() const { return local_port_id_; }

    /** Get current role. */
    PtpRole role() const { return role_.load(); }

    /** Check if running. */
    bool is_running() const { return running_.load(); }

    // --- BMCA ---

    /**
     * Compare two announce datasets.
     * Returns true if 'a' is better than 'b'.
     */
    static bool bmca_compare(const PtpAnnounceBody& a, const PtpPortIdentity& a_id,
                              const PtpAnnounceBody& b, const PtpPortIdentity& b_id);

private:
    void event_loop();       // PTP event port (319) — Sync, Delay_Req
    void general_loop();     // PTP general port (320) — Follow_Up, Delay_Resp, Announce
    void master_loop();      // Master: periodic Sync + Announce
    void slave_loop();       // Slave: periodic Delay_Req

    void handle_sync(const uint8_t* buf, size_t len, const pal::Timestamp& recv_ts);
    void handle_follow_up(const uint8_t* buf, size_t len);
    void handle_delay_resp(const uint8_t* buf, size_t len);
    void handle_announce(const uint8_t* buf, size_t len);

    void send_sync();
    void send_follow_up(uint16_t seq_id, const PtpTimestamp& precise_ts);
    void send_delay_req();
    void send_delay_resp(uint16_t seq_id, const PtpTimestamp& recv_ts,
                          const PtpPortIdentity& requester);
    void send_announce();

    void run_bmca();
    void update_sync_info();
    void generate_clock_id();

    PtpConfig config_;
    PtpPortIdentity local_port_id_;
    ClockServo servo_;

    std::unique_ptr<pal::UdpSocket> event_socket_;    // port 319
    std::unique_ptr<pal::UdpSocket> general_socket_;   // port 320

    std::atomic<PtpRole> role_{PtpRole::Listening};
    std::atomic<bool> running_{false};

    // Sync state (protected by mutex for multi-field reads)
    mutable std::mutex sync_mutex_;
    PtpSyncInfo sync_info_;
    PtpSyncCallback sync_callback_;

    // Master state
    PtpAnnounceBody best_announce_;
    PtpPortIdentity best_master_id_;
    int announce_timeout_count_ = 0;

    // Slave state — timestamps for offset/delay calculation
    PtpTimestamp t1_;          // Sync origin (master send time)
    pal::Timestamp t2_;        // Sync receive (local time)
    pal::Timestamp t3_;        // Delay_Req send (local time)
    PtpTimestamp t4_;          // Delay_Resp receive (master receive time)
    uint16_t sync_seq_ = 0;
    uint16_t delay_req_seq_ = 0;
    bool have_t1_ = false;
    bool have_t2_ = false;

    // Sequence counters (master)
    uint16_t master_sync_seq_ = 0;
    uint16_t master_announce_seq_ = 0;

    // Threads
    std::unique_ptr<pal::Thread> event_thread_;
    std::unique_ptr<pal::Thread> general_thread_;
    std::unique_ptr<pal::Thread> task_thread_;
};

} // namespace soluna::sync
