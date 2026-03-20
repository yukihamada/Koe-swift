#pragma once

/**
 * WebSocket Server — Embedded HTTP + WebSocket server for Web UI
 *
 * Lightweight single-threaded server on port 8400:
 * - HTTP: Serves embedded web files (index.html, app.js, style.css)
 * - WebSocket: Handles ControlRequest/ControlResponse JSON
 *
 * RFC 6455 minimal implementation (text frames only).
 *
 * SPDX-License-Identifier: MIT
 */

#include <cstdint>
#include <cstddef>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace soluna::control {

/**
 * Embedded web file entry (generated at build time).
 */
struct WebFile {
    const char* path;       // e.g., "/index.html"
    const char* mime_type;  // e.g., "text/html"
    const uint8_t* data;
    size_t size;
};

/**
 * WebSocket message callback: receives JSON text, returns JSON response.
 */
using WsMessageCallback = std::function<std::string(const std::string& message)>;

/**
 * HTTP POST callback: receives path + raw body bytes, returns HTTP response body.
 * Return empty string to fall through to 404.
 */
using HttpPostCallback = std::function<std::string(
    const std::string& path,
    const std::vector<uint8_t>& body,
    std::string& out_content_type)>;

/**
 * WebSocket Server
 */
class WebSocketServer {
public:
    WebSocketServer();
    ~WebSocketServer();

    WebSocketServer(const WebSocketServer&) = delete;
    WebSocketServer& operator=(const WebSocketServer&) = delete;

    /**
     * Register embedded web files for HTTP serving.
     */
    void set_web_files(const WebFile* files, size_t count);

    /**
     * Set WebSocket message handler.
     */
    void set_message_callback(WsMessageCallback cb);

    /**
     * Set HTTP POST handler (e.g., for /api/player/upload).
     * Called for all POST requests before falling through to 404.
     */
    void set_http_post_handler(HttpPostCallback cb);

    /**
     * Start the server on the given port.
     * Runs in a background thread.
     */
    bool start(uint16_t port = 8400);

    /**
     * Enable TLS (HTTPS/WSS) with certificate and private key files.
     * Must be called before start(). Uses OpenSSL when SOLUNA_HAS_TLS is defined.
     */
    bool enable_tls(const std::string& cert_path, const std::string& key_path);

    /**
     * Stop the server.
     */
    void stop();

    /**
     * Check if server is running.
     */
    bool is_running() const;

    /**
     * Broadcast a text message to all connected WebSocket clients.
     */
    void broadcast(const std::string& message);

    /**
     * Broadcast a binary frame to all connected WebSocket clients.
     * Used for raw audio streaming (PCM S16LE).
     */
    void broadcast_binary(const uint8_t* data, size_t len);

    /**
     * Get number of connected WebSocket clients.
     */
    size_t client_count() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

/**
 * Build an HTTP response header.
 */
std::string http_response(int status_code, const std::string& content_type,
                          size_t content_length,
                          const std::string& extra_headers = "");

/**
 * Parse an HTTP request line.
 * Returns the method, path, and whether it's a WebSocket upgrade.
 */
struct HttpRequest {
    std::string method;
    std::string path;
    bool is_websocket_upgrade = false;
    std::string ws_key;  // Sec-WebSocket-Key
};

bool parse_http_request(const std::string& raw, HttpRequest& req);

/**
 * Compute WebSocket accept key from client key (RFC 6455).
 */
std::string ws_accept_key(const std::string& client_key);

/**
 * Build a WebSocket text frame.
 */
std::vector<uint8_t> ws_build_text_frame(const std::string& text);

/**
 * Build a WebSocket binary frame (opcode 0x02).
 */
std::vector<uint8_t> ws_build_binary_frame(const uint8_t* data, size_t len);

/**
 * Parse a WebSocket frame.
 * Returns payload text for text frames, empty on error or non-text.
 */
struct WsFrame {
    uint8_t opcode = 0;
    std::string payload;
    bool valid = false;
};

WsFrame ws_parse_frame(const uint8_t* data, size_t len, size_t& consumed);

} // namespace soluna::control
