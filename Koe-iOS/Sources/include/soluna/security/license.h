#pragma once

/**
 * Soluna — License Key Validation
 *
 * Simple HMAC-SHA256 based license key system.
 * License keys are base64-encoded JSON with a signature.
 *
 * Format: base64({"tier":"S","max_participants":5000,"expires":"2027-01-01",...}).signature
 *
 * SPDX-License-Identifier: OpenSonic-Community-1.0
 */

#include <soluna/core/error.h>
#include <cstdint>
#include <string>

namespace soluna::security {

/**
 * License tier matching the OpenSonic Community License pricing.
 */
enum class LicenseTier {
    Free = 0,   // ≤1,000 participants, no key needed
    Small,      // 1,001 - 5,000
    Medium,     // 5,001 - 10,000
    Large,      // 10,001+
};

/**
 * Parsed and validated license information.
 */
struct LicenseInfo {
    LicenseTier tier = LicenseTier::Free;
    uint32_t max_participants = 1000;
    std::string licensee;      // Organization name
    std::string expires;       // ISO 8601 date (YYYY-MM-DD)
    bool annual = false;       // Annual vs per-event
    bool valid = false;
};

/**
 * Validate a license key string.
 *
 * @param key The license key (base64.signature format)
 * @return LicenseInfo with valid=true if the key is legitimate
 */
LicenseInfo validate_license_key(const std::string& key);

/**
 * Check if a license has expired.
 *
 * @param info Previously validated license info
 * @return true if the license is still valid (not expired)
 */
bool is_license_active(const LicenseInfo& info);

/**
 * Get the tier name as a string.
 */
const char* tier_name(LicenseTier tier);

/**
 * Load license key from standard paths:
 * 1. SOLUNA_LICENSE_KEY env var
 * 2. ~/.config/soluna/license.key
 * 3. /etc/soluna/license.key
 *
 * @return The license key string, or empty if not found
 */
std::string load_license_key();

} // namespace soluna::security
