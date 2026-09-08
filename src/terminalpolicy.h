// SPDX-License-Identifier: MIT
#pragma once

#include <cstdlib>
#include <fstream>
#include <string>
#include <vector>

namespace quickemoji {

// Fcitx frontends may identify a terminal by its app ID or executable name.
inline bool terminalBlocked(const std::string &program) {
    const char *home = std::getenv("HOME");
    const char *state = std::getenv("XDG_STATE_HOME");
    if (state && *state) {
        if (std::ifstream flag(std::string(state) +
                               "/quick-emoji/terminals-enabled");
            flag.good()) {
            return false;
        }
    } else if (home) {
        if (std::ifstream flag(std::string(home) +
                               "/.local/state/quick-emoji/terminals-enabled");
            flag.good()) {
            return false;
        }
    }
    static const std::vector<std::string> blocklist = {
        "Alacritty", "kitty", "foot", "ghostty",
        "org.wezfurlong.wezterm", "gnome-terminal",
        "org.kde.konsole", "konsole", "xterm",
    };
    if (!program.empty()) {
        for (const auto &name : blocklist) {
            if (program.find(name) != std::string::npos) {
                return true;
            }
        }
    }
    return false;
}

} // namespace quickemoji
