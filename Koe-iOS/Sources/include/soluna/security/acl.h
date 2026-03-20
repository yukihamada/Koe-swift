#pragma once

/**
 * Soluna — Access Control List
 *
 * Role-based access control for API operations.
 *
 * SPDX-License-Identifier: MIT
 */

#include <soluna/security/auth.h>
#include <soluna/core/error.h>
#include <string>
#include <vector>
#include <map>
#include <set>
#include <mutex>

namespace soluna {
namespace security {

/**
 * Standard permissions.
 */
namespace permissions {
    // Stream operations
    constexpr const char* STREAM_CREATE = "stream_create";
    constexpr const char* STREAM_DELETE = "stream_delete";
    constexpr const char* STREAM_MODIFY = "stream_modify";
    constexpr const char* STREAM_VIEW = "stream_view";

    // Route operations
    constexpr const char* ROUTE_CREATE = "route_create";
    constexpr const char* ROUTE_DELETE = "route_delete";
    constexpr const char* ROUTE_MODIFY = "route_modify";
    constexpr const char* ROUTE_VIEW = "route_view";

    // Configuration
    constexpr const char* CONFIG_READ = "config_read";
    constexpr const char* CONFIG_WRITE = "config_write";

    // Device management
    constexpr const char* DEVICE_MANAGE = "device_manage";

    // Metrics and monitoring
    constexpr const char* METRICS_VIEW = "metrics_view";

    // Administrative
    constexpr const char* ADMIN = "admin";
}

/**
 * Standard roles.
 */
namespace roles {
    constexpr const char* ADMIN = "admin";
    constexpr const char* OPERATOR = "operator";
    constexpr const char* VIEWER = "viewer";
    constexpr const char* STREAM = "stream";
}

/**
 * Role definition with permissions.
 */
struct Role {
    std::string name;
    std::set<std::string> permissions;
    std::string description;
};

/**
 * Access Control List manager.
 *
 * Manages roles and permissions for authorization.
 */
class ACL {
public:
    ACL();

    /**
     * Initialize with configuration.
     */
    Result<void> init(const config::SecurityConfig& config);

    /**
     * Define a role with permissions.
     */
    Result<void> define_role(const std::string& role_name,
                              const std::vector<std::string>& permissions,
                              const std::string& description = "");

    /**
     * Remove a role definition.
     */
    Result<void> remove_role(const std::string& role_name);

    /**
     * Get role definition.
     */
    const Role* get_role(const std::string& role_name) const;

    /**
     * List all defined roles.
     */
    std::vector<std::string> list_roles() const;

    /**
     * Check if a role has a specific permission.
     */
    bool role_has_permission(const std::string& role_name, const std::string& permission) const;

    /**
     * Check if auth context is authorized for a permission.
     */
    bool check_permission(const AuthContext& ctx, const std::string& permission) const;

    /**
     * Check multiple permissions (all must be satisfied).
     */
    bool check_all_permissions(const AuthContext& ctx,
                                const std::vector<std::string>& permissions) const;

    /**
     * Check multiple permissions (any must be satisfied).
     */
    bool check_any_permission(const AuthContext& ctx,
                               const std::vector<std::string>& permissions) const;

    /**
     * Require permission, returning error if not authorized.
     */
    Result<void> require_permission(const AuthContext& ctx, const std::string& permission) const;

    /**
     * Get all permissions for given roles.
     */
    std::set<std::string> get_permissions(const std::vector<std::string>& roles) const;

    /**
     * List all defined permissions.
     */
    std::vector<std::string> list_permissions() const;

    /**
     * Load default roles.
     */
    void load_defaults();

private:
    mutable std::mutex mutex_;
    std::map<std::string, Role> roles_;
    std::set<std::string> all_permissions_;
};

/**
 * Authorization decorator for request handlers.
 */
class Authorizer {
public:
    Authorizer(const ACL& acl, bool auth_enabled);

    /**
     * Check if request is authorized.
     */
    Result<void> authorize(const AuthContext& ctx, const std::string& permission) const;

    /**
     * Check if authentication is required.
     */
    bool requires_auth() const { return auth_enabled_; }

private:
    const ACL& acl_;
    bool auth_enabled_;
};

} // namespace security
} // namespace soluna
