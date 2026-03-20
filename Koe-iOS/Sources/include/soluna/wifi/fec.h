#pragma once

/**
 * Forward Error Correction (FEC)
 *
 * Two modes:
 * - XOR parity: lightweight, for ESP32. Protects against single packet loss per group.
 * - Reed-Solomon: desktop. Protects against multiple losses per group.
 *
 * SPDX-License-Identifier: MIT
 */

#include <cstdint>
#include <cstddef>
#include <map>
#include <vector>
#include <memory>

namespace soluna::wifi {

enum class FecMode : uint8_t {
    None = 0,
    XorParity = 1,      // 1 parity per N packets (single-loss recovery)
    ReedSolomon = 2,    // K data + M parity (multi-loss recovery)
};

struct FecConfig {
    FecMode mode = FecMode::XorParity;
    uint8_t group_size = 5;         // N data packets per FEC group
    uint8_t parity_count = 1;       // XOR: always 1, RS: configurable (1-4)
    size_t max_packet_size = 1500;  // max payload size
};

// FEC-encoded packet
struct FecPacket {
    uint32_t fec_group_id = 0;      // identifies the FEC group
    uint8_t index = 0;              // position within group (0..group_size+parity-1)
    bool is_parity = false;
    std::vector<uint8_t> data;
};

/**
 * FEC Encoder — generates parity packets from data packets.
 */
class FecEncoder {
public:
    explicit FecEncoder(const FecConfig& config = {});
    ~FecEncoder();

    /**
     * Feed a data packet. When a full group is accumulated,
     * parity packet(s) are generated and available via get_parity().
     * Returns true if parity is now available.
     */
    bool feed(const void* data, size_t size);

    /**
     * Get generated parity packets for the last complete group.
     * Only valid after feed() returns true.
     */
    const std::vector<FecPacket>& get_parity() const { return parity_packets_; }

    /**
     * Get the current FEC group ID.
     */
    uint32_t current_group_id() const { return group_id_; }

    /**
     * Get index within current group (0-based).
     */
    uint8_t current_index() const { return static_cast<uint8_t>(group_buf_.size()); }

    void reset();
    const FecConfig& config() const { return config_; }

private:
    FecConfig config_;
    uint32_t group_id_ = 0;
    std::vector<std::vector<uint8_t>> group_buf_;
    std::vector<FecPacket> parity_packets_;
    size_t max_len_in_group_ = 0;

    void generate_xor_parity();
    void generate_rs_parity();
};

/**
 * FEC Decoder — recovers lost packets using parity.
 */
class FecDecoder {
public:
    explicit FecDecoder(const FecConfig& config = {});
    ~FecDecoder();

    /**
     * Feed a received packet (data or parity).
     * group_id: FEC group identifier
     * index: position within group
     * is_parity: true if this is a parity packet
     * data/size: packet payload
     */
    void feed(uint32_t group_id, uint8_t index, bool is_parity,
              const void* data, size_t size);

    /**
     * Attempt to recover missing packets in a group.
     * Returns recovered packets (empty if recovery not possible).
     */
    std::vector<FecPacket> recover(uint32_t group_id);

    /**
     * Check if a group is complete (all data packets received).
     */
    bool is_complete(uint32_t group_id) const;

    /**
     * Check if a group can be recovered.
     */
    bool can_recover(uint32_t group_id) const;

    /**
     * Remove old groups to free memory.
     */
    void prune(uint32_t keep_groups = 8);

    void reset();
    const FecConfig& config() const { return config_; }

private:
    struct Group {
        std::vector<std::vector<uint8_t>> data_packets;   // indexed by position
        std::vector<std::vector<uint8_t>> parity_packets;
        std::vector<bool> data_received;
        std::vector<bool> parity_received;
        size_t max_packet_size = 0;
    };

    FecConfig config_;
    std::map<uint32_t, Group> groups_;

    Group& get_or_create_group(uint32_t group_id);
    std::vector<FecPacket> recover_xor(Group& group, uint32_t group_id);
    std::vector<FecPacket> recover_rs(Group& group, uint32_t group_id);
};

} // namespace soluna::wifi
