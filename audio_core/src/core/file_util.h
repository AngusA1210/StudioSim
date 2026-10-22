#pragma once

// Files by their names in UTF-8 (as the game gives them) on every platform: Windows wants them as wide strings, and
// would read a plain one in its old code page, losing any letter outside it.

#include <cstdio>
#include <cstring>
#include <filesystem>
#include <string>

namespace sr {

inline std::filesystem::path pathOf(const std::string& utf8) {
#if defined(_WIN32)
    return std::filesystem::u8path(utf8);
#else
    return std::filesystem::path(utf8);
#endif
}

inline std::FILE* openFile(const std::string& utf8, const char* mode) {
#if defined(_WIN32)
    const std::wstring wide_mode(mode, mode + std::strlen(mode));
    return _wfopen(pathOf(utf8).c_str(), wide_mode.c_str());
#else
    return std::fopen(utf8.c_str(), mode);
#endif
}

}  // namespace sr
