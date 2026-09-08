// SPDX-License-Identifier: MIT
#include "../src/terminalpolicy.h"
#include <iostream>

int main(int argc, char **argv) {
    if (argc != 3) {
        return 2;
    }
    const bool expected = std::string(argv[2]) == "blocked";
    const bool actual = quickemoji::terminalBlocked(argv[1]);
    if (actual != expected) {
        std::cerr << argv[1] << ": expected " << argv[2] << '\n';
        return 1;
    }
}
