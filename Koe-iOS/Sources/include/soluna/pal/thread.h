#pragma once

#include <functional>
#include <string>
#include <memory>

namespace soluna::pal {

enum class ThreadPriority {
    Normal,
    High,
    Realtime,
};

class Thread {
public:
    virtual ~Thread() = default;

    virtual bool start(std::function<void()> func) = 0;
    virtual void join() = 0;
    virtual bool is_running() const = 0;

    static std::unique_ptr<Thread> create(const std::string& name, ThreadPriority priority = ThreadPriority::Normal);

    // Set current thread to realtime priority (best effort)
    static bool set_realtime_priority();
};

} // namespace soluna::pal
