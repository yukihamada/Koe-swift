#pragma once

/**
 * Ravenna Compatibility — AES67 + mDNS service discovery + SDP extensions
 *
 * Ravenna extends AES67 with:
 * - mDNS service advertisement via _ravenna._tcp
 * - Ravenna-specific SDP attributes (x-ravenna-session, x-ravenna-device)
 *
 * Requires AES67 to be enabled (SOLUNA_HAS_AES67).
 *
 * SPDX-License-Identifier: MIT
 */

#ifdef SOLUNA_HAS_RAVENNA

#include <soluna/transport/aes67.h>
#include <string>
#include <cstdint>

namespace soluna::transport {

/**
 * Ravenna session descriptor — extends Aes67Session with Ravenna metadata.
 */
struct RavennaSession : public Aes67Session {
    std::string device_name;                // friendly name for mDNS TXT record
    uint32_t    ravenna_session_version = 1; // for SDP update tracking
};

/**
 * Generate SDP text for a Ravenna session.
 *
 * Calls aes67_generate_sdp() and appends Ravenna-specific attributes:
 *   a=x-ravenna-session:<session_version>
 *   a=x-ravenna-device:<device_name>
 */
std::string ravenna_generate_sdp(const RavennaSession& session);

/**
 * Build a SAP announcement packet using Ravenna SDP.
 *
 * Same as aes67_build_sap_packet but uses ravenna_generate_sdp().
 */
size_t ravenna_build_sap_packet(const RavennaSession& session,
                                 uint8_t* out_buf, size_t buf_size);

/**
 * Start mDNS advertisement for _ravenna._tcp service.
 *
 * Advertises on port 5004 (RTP) with TXT records containing:
 *   txtvers=1, rate=<sample_rate>, ch=<channels>, name=<device_name>
 *
 * Uses dns_sd.h (Apple Bonjour) on macOS.
 *
 * @param session  Ravenna session with device info
 * @return         true if advertisement started successfully
 */
bool ravenna_start_mdns(const RavennaSession& session);

/**
 * Stop mDNS advertisement for _ravenna._tcp service.
 */
void ravenna_stop_mdns();

} // namespace soluna::transport

#endif // SOLUNA_HAS_RAVENNA
