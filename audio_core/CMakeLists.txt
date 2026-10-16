cmake_minimum_required(VERSION 3.22)
project(soundroom_audio LANGUAGES C CXX)
if(APPLE)
    enable_language(OBJCXX)  # hosting Audio Units and showing their windows
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
if(APPLE)
    set(CMAKE_OSX_DEPLOYMENT_TARGET 12.0)
endif()
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

set(GAME_BIN_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../game/bin")
set(STEAMAUDIO_DIR "${CMAKE_CURRENT_SOURCE_DIR}/thirdparty/steamaudio")
if(NOT EXISTS "${STEAMAUDIO_DIR}/include/phonon.h")
    message(FATAL_ERROR "Steam Audio is missing. Run tools/fetch_deps.sh first.")
endif()

# ── Steam Audio (prebuilt) ──────────────────────────────────────────────────────────────────────────────────
add_library(phonon SHARED IMPORTED)
if(APPLE)
    set(PHONON_LIBRARY "${STEAMAUDIO_DIR}/lib/osx/libphonon.dylib")
    set_target_properties(phonon PROPERTIES IMPORTED_LOCATION "${PHONON_LIBRARY}")
elseif(WIN32)
    set(PHONON_LIBRARY "${STEAMAUDIO_DIR}/lib/windows-x64/phonon.dll")
    set_target_properties(phonon PROPERTIES IMPORTED_LOCATION "${PHONON_LIBRARY}"
                                            IMPORTED_IMPLIB "${STEAMAUDIO_DIR}/lib/windows-x64/phonon.lib")
else()
    set(PHONON_LIBRARY "${STEAMAUDIO_DIR}/lib/linux-x64/libphonon.so")
    set_target_properties(phonon PROPERTIES IMPORTED_LOCATION "${PHONON_LIBRARY}")
endif()
target_include_directories(phonon INTERFACE "${STEAMAUDIO_DIR}/include")

# ── The engine-agnostic audio core ──────────────────────────────────────────────────────────────────────────
add_library(sr_core STATIC
    src/core/engine.cpp
    src/core/instruments.cpp
    src/core/mix.cpp
    src/core/room_geometry.cpp
    src/core/amp.cpp
    src/core/looper.cpp
    src/core/pedals.cpp
    src/core/sequencer.cpp
    src/core/spatializer.cpp
    src/core/miniaudio_impl.c
)
target_include_directories(sr_core PUBLIC src/core thirdparty/miniaudio)
target_link_libraries(sr_core PUBLIC phonon)
if(APPLE)
    target_sources(sr_core PRIVATE src/core/midi_input_coremidi.cpp src/core/plugin_host_mac.mm)
    set_source_files_properties(src/core/plugin_host_mac.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
    target_link_libraries(sr_core PUBLIC "-framework CoreAudio" "-framework AudioToolbox" "-framework CoreFoundation"
                                         "-framework CoreMIDI" "-framework AppKit" "-framework CoreAudioKit")
else()
    target_sources(sr_core PRIVATE src/core/midi_input_stub.cpp src/core/plugin_host_stub.cpp)
endif()
if(NOT MSVC)
    target_compile_options(sr_core PRIVATE $<$<COMPILE_LANGUAGE:CXX>:-Wall -Wextra>)
endif()

# ── Offline tests ───────────────────────────────────────────────────────────────────────────────────────────
add_executable(engine_tests tests/engine_tests.cpp)
target_link_libraries(engine_tests PRIVATE sr_core)
if(APPLE)
    set_target_properties(engine_tests PROPERTIES BUILD_RPATH "${STEAMAUDIO_DIR}/lib/osx")
endif()

# ── Godot extension ─────────────────────────────────────────────────────────────────────────────────────────
add_subdirectory(thirdparty/godot-cpp EXCLUDE_FROM_ALL)
add_library(soundroom_audio SHARED
    src/godot/register_types.cpp
    src/godot/sound_room_audio.cpp
)
target_link_libraries(soundroom_audio PRIVATE sr_core godot::cpp)
set_target_properties(soundroom_audio PROPERTIES
    OUTPUT_NAME "soundroom_audio"
    LIBRARY_OUTPUT_DIRECTORY "${GAME_BIN_DIR}"
    RUNTIME_OUTPUT_DIRECTORY "${GAME_BIN_DIR}"
)
foreach(cfg DEBUG RELEASE RELWITHDEBINFO MINSIZEREL)
    set_target_properties(soundroom_audio PROPERTIES
        LIBRARY_OUTPUT_DIRECTORY_${cfg} "${GAME_BIN_DIR}" RUNTIME_OUTPUT_DIRECTORY_${cfg} "${GAME_BIN_DIR}")
endforeach()
if(APPLE)
    # Find libphonon.dylib next to the extension at runtime.
    set_target_properties(soundroom_audio PROPERTIES BUILD_RPATH "@loader_path" INSTALL_RPATH "@loader_path")
endif()
add_custom_command(TARGET soundroom_audio POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different "${PHONON_LIBRARY}" "${GAME_BIN_DIR}/"
    COMMENT "Copying Steam Audio next to the extension")
