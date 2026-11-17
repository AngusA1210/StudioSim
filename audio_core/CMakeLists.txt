cmake_minimum_required(VERSION 3.22)
project(studiosim_audio LANGUAGES C CXX)
if(APPLE)
    enable_language(OBJCXX)  # hosting Audio Units and showing their windows
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
if(APPLE)
    set(CMAKE_OSX_DEPLOYMENT_TARGET 12.0)
endif()
# On Windows, Microsoft's C++ runtime built in (/MT), for everything here (godot-cpp, Opus, the VST 3 hosting too): the
# app then needs no Visual C++ Redistributable installed, and so its installer needs no administrator's rights. (Steam
# Audio's DLL carries its own already.) Set before any target is made, as each takes it as it is made.
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>" CACHE STRING "Microsoft's C++ runtime, built in")
set(CMAKE_POLICY_DEFAULT_CMP0091 NEW)  # (and for the libraries whose own CMake files predate it, Opus among them)
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

set(GAME_BIN_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../game/bin" CACHE PATH "Where the Godot extension (and Steam Audio beside it) is put")
set(STEAMAUDIO_DIR "${CMAKE_CURRENT_SOURCE_DIR}/thirdparty/steamaudio")
set(VST3SDK_DIR "${CMAKE_CURRENT_SOURCE_DIR}/thirdparty/vst3sdk")
if(NOT EXISTS "${STEAMAUDIO_DIR}/include/phonon.h" OR NOT EXISTS "${VST3SDK_DIR}/pluginterfaces/base/funknown.h")
    message(FATAL_ERROR "Steam Audio or the VST 3 SDK is missing. Run tools/fetch_deps.sh first.")
endif()
if(MSVC)
    add_compile_options(/utf-8 /bigobj)  # (the sources are UTF-8)
    add_compile_definitions(NOMINMAX _CRT_SECURE_NO_WARNINGS)
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

# ── What a VST3 host needs of the VST 3 SDK (MIT) ───────────────────────────────────────────────────────────
add_library(vst3_hosting STATIC
    ${VST3SDK_DIR}/pluginterfaces/base/conststringtable.cpp
    ${VST3SDK_DIR}/pluginterfaces/base/coreiids.cpp
    ${VST3SDK_DIR}/pluginterfaces/base/funknown.cpp
    ${VST3SDK_DIR}/pluginterfaces/base/ustring.cpp
    ${VST3SDK_DIR}/public.sdk/source/common/commoniids.cpp
    ${VST3SDK_DIR}/public.sdk/source/common/commonstringconvert.cpp
    ${VST3SDK_DIR}/public.sdk/source/common/memorystream.cpp
    ${VST3SDK_DIR}/public.sdk/source/vst/hosting/eventlist.cpp
    ${VST3SDK_DIR}/public.sdk/source/vst/hosting/hostclasses.cpp
    ${VST3SDK_DIR}/public.sdk/source/vst/hosting/module.cpp
    ${VST3SDK_DIR}/public.sdk/source/vst/hosting/parameterchanges.cpp
    ${VST3SDK_DIR}/public.sdk/source/vst/hosting/pluginterfacesupport.cpp
    ${VST3SDK_DIR}/public.sdk/source/vst/hosting/processdata.cpp
    ${VST3SDK_DIR}/public.sdk/source/vst/moduleinfo/moduleinfoparser.cpp
    ${VST3SDK_DIR}/public.sdk/source/vst/utility/stringconvert.cpp
    ${VST3SDK_DIR}/public.sdk/source/vst/vstinitiids.cpp
)
target_include_directories(vst3_hosting PUBLIC "${VST3SDK_DIR}")
if(APPLE)
    target_sources(vst3_hosting PRIVATE ${VST3SDK_DIR}/public.sdk/source/vst/hosting/module_mac.mm)
    set_source_files_properties(${VST3SDK_DIR}/public.sdk/source/vst/hosting/module_mac.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
elseif(WIN32)
    target_sources(vst3_hosting PRIVATE ${VST3SDK_DIR}/public.sdk/source/vst/hosting/module_win32.cpp)
    target_link_libraries(vst3_hosting PUBLIC ole32 shell32)
else()
    target_sources(vst3_hosting PRIVATE ${VST3SDK_DIR}/public.sdk/source/vst/hosting/module_linux.cpp)
    target_link_libraries(vst3_hosting PUBLIC dl)
endif()

# ── Opus (BSD), for the sound between players ───────────────────────────────────────────────────────────────
set(OPUS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/thirdparty/opus")
if(NOT EXISTS "${OPUS_DIR}/include/opus.h")
    message(FATAL_ERROR "Opus is missing. Run tools/fetch_deps.sh first.")
endif()
set(OPUS_BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(OPUS_BUILD_PROGRAMS OFF CACHE BOOL "" FORCE)
set(OPUS_INSTALL_PKG_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
set(OPUS_INSTALL_CMAKE_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
add_subdirectory("${OPUS_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/opus" EXCLUDE_FROM_ALL)

# ── The engine-agnostic audio core ──────────────────────────────────────────────────────────────────────────
add_library(sr_core STATIC
    src/core/engine.cpp
    src/core/instruments.cpp
    src/core/mix.cpp
    src/core/room_geometry.cpp
    src/core/materials.cpp
    src/core/amp.cpp
    src/core/looper.cpp
    src/core/pedals.cpp
    src/core/plugin_synth.cpp
    src/core/recorder.cpp
    src/core/wav.cpp
    src/core/disk_stream.cpp
    src/core/microphones.cpp
    src/core/radiation.cpp
    src/core/interpolation.cpp
    src/core/net_audio.cpp
    src/core/desktop_audio.cpp
    src/core/plugin_category.cpp
    src/core/plugin_host.cpp
    src/core/plugin_host_vst3.cpp
    src/core/sequencer.cpp
    src/core/spatializer.cpp
    src/core/miniaudio_impl.c
)
target_include_directories(sr_core PUBLIC src/core thirdparty/miniaudio)
target_link_libraries(sr_core PUBLIC phonon vst3_hosting opus)
if(APPLE)
    target_sources(sr_core PRIVATE src/core/midi_input_coremidi.cpp src/core/plugin_host_mac.mm src/core/plugin_window_mac.mm
                                   src/core/plugin_panel_mac.mm src/core/desktop_audio_mac.mm)
    set_source_files_properties(src/core/plugin_host_mac.mm src/core/plugin_window_mac.mm src/core/plugin_panel_mac.mm
                                src/core/desktop_audio_mac.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
    target_link_libraries(sr_core PUBLIC "-framework CoreAudio" "-framework AudioToolbox" "-framework CoreFoundation"
                                         "-framework CoreMIDI" "-framework AppKit" "-framework CoreAudioKit"
                                         "-framework AVFoundation")
elseif(WIN32)
    target_sources(sr_core PRIVATE src/core/midi_input_win.cpp src/core/plugin_window_win.cpp)
    target_link_libraries(sr_core PUBLIC winmm user32 gdi32 ws2_32)
else()
    target_sources(sr_core PRIVATE src/core/midi_input_stub.cpp src/core/plugin_window_stub.cpp)
endif()
# ASIO, for interfaces whose Windows drivers want it: only with Steinberg's ASIO SDK, which isn't fetched (it is
# licensed by agreement with Steinberg). Download it from steinberg.net and unpack it as thirdparty/asiosdk.
set(ASIOSDK_DIR "${CMAKE_CURRENT_SOURCE_DIR}/thirdparty/asiosdk")
if(WIN32 AND EXISTS "${ASIOSDK_DIR}/common/iasiodrv.h")
    message(STATUS "ASIO: on (${ASIOSDK_DIR})")
    target_sources(sr_core PRIVATE src/core/asio_device_win.cpp)
    target_include_directories(sr_core PRIVATE "${ASIOSDK_DIR}/common")
    target_compile_definitions(sr_core PRIVATE SR_ASIO)
    target_link_libraries(sr_core PUBLIC ole32 advapi32)
elseif(WIN32)
    message(STATUS "ASIO: off (no ASIO SDK in ${ASIOSDK_DIR})")
endif()
if(NOT MSVC)
    target_compile_options(sr_core PRIVATE $<$<COMPILE_LANGUAGE:CXX>:-Wall -Wextra>)
endif()

# ── Offline tests ───────────────────────────────────────────────────────────────────────────────────────────
add_executable(engine_tests tests/engine_tests.cpp)
target_link_libraries(engine_tests PRIVATE sr_core)
# Its checks each make a room of their own (an engine, some 13 KB) in main's blocks, which Visual Studio doesn't always
# lay over one another: more than Windows' 1 MB stack holds. (macOS gives a program 8 MB.)
if(MSVC)
    target_link_options(engine_tests PRIVATE /STACK:16777216)
endif()
# A VST3 plug-in of the checks' own (tests/vst3_test_plugin.cpp), so that they never load anyone's: a bundle on macOS,
# a .vst3 file on Windows, in the build's vst3 folder, which is where the checks look for plug-ins.
set(TEST_VST3_DIR "${CMAKE_BINARY_DIR}/vst3")
add_library(srtest_vst3 MODULE
    tests/vst3_test_plugin.cpp
    ${VST3SDK_DIR}/pluginterfaces/base/conststringtable.cpp
    ${VST3SDK_DIR}/pluginterfaces/base/coreiids.cpp
    ${VST3SDK_DIR}/pluginterfaces/base/funknown.cpp
    ${VST3SDK_DIR}/pluginterfaces/base/ustring.cpp
    ${VST3SDK_DIR}/public.sdk/source/vst/vstinitiids.cpp
)
target_include_directories(srtest_vst3 PRIVATE "${VST3SDK_DIR}")
set_target_properties(srtest_vst3 PROPERTIES OUTPUT_NAME "SRTest" PREFIX "" LIBRARY_OUTPUT_DIRECTORY "${TEST_VST3_DIR}")
foreach(cfg DEBUG RELEASE RELWITHDEBINFO MINSIZEREL)
    set_target_properties(srtest_vst3 PROPERTIES LIBRARY_OUTPUT_DIRECTORY_${cfg} "${TEST_VST3_DIR}")
endforeach()
if(APPLE)
    set_target_properties(srtest_vst3 PROPERTIES BUNDLE TRUE BUNDLE_EXTENSION "vst3")
    target_link_libraries(srtest_vst3 PRIVATE "-framework CoreFoundation")
else()
    set_target_properties(srtest_vst3 PROPERTIES SUFFIX ".vst3")
endif()
add_dependencies(engine_tests srtest_vst3)
target_compile_definitions(engine_tests PRIVATE SR_TEST_VST3_DIR="${TEST_VST3_DIR}")
if(APPLE)
    set_target_properties(engine_tests PROPERTIES BUILD_RPATH "${STEAMAUDIO_DIR}/lib/osx")
elseif(WIN32)  # (Windows finds a DLL beside the program)
    add_custom_command(TARGET engine_tests POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different "${PHONON_LIBRARY}" "$<TARGET_FILE_DIR:engine_tests>/")
endif()

# ── The session server (src/server: players meet through it, on a machine the internet can reach) ──────────────
find_package(Threads REQUIRED)
add_library(sr_session_server STATIC src/server/session_server.cpp)
target_include_directories(sr_session_server PUBLIC src/server)
target_link_libraries(sr_session_server PUBLIC Threads::Threads)
if(WIN32)
    target_link_libraries(sr_session_server PUBLIC ws2_32)
endif()
add_executable(studiosim_session_server src/server/main.cpp)
target_link_libraries(studiosim_session_server PRIVATE sr_session_server)
set_target_properties(studiosim_session_server PROPERTIES OUTPUT_NAME "studiosim-session-server" RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}")
foreach(cfg DEBUG RELEASE RELWITHDEBINFO MINSIZEREL)  # (in the build folder itself, where the game's checks look for it)
    set_target_properties(studiosim_session_server PROPERTIES RUNTIME_OUTPUT_DIRECTORY_${cfg} "${CMAKE_BINARY_DIR}")
endforeach()
add_executable(session_server_tests tests/session_server_tests.cpp)
target_link_libraries(session_server_tests PRIVATE sr_session_server)
# A plug-in's window on a Mac and the keyboard (tests/plugin_panel_tests.mm): two windows of its own, brought up briefly.
if(APPLE)
    add_executable(plugin_panel_tests tests/plugin_panel_tests.mm src/core/plugin_panel_mac.mm)
    target_include_directories(plugin_panel_tests PRIVATE src/core)
    target_compile_options(plugin_panel_tests PRIVATE -fobjc-arc)
    target_link_libraries(plugin_panel_tests PRIVATE "-framework AppKit")
endif()

# ── Godot extension ─────────────────────────────────────────────────────────────────────────────────────────
add_subdirectory(thirdparty/godot-cpp EXCLUDE_FROM_ALL)
add_library(studiosim_audio SHARED
    src/godot/register_types.cpp
    src/godot/studiosim_audio.cpp
)
target_link_libraries(studiosim_audio PRIVATE sr_core godot::cpp)
# Godot's release runtime (an exported StudioSim, made by tools/export.sh) needs the extension's godot-cpp built for it:
# that one is built in a folder of its own, with -DGODOTCPP_TARGET=template_release, and named apart (.release),
# beside the one the editor and the checks load (studiosim_audio.gdextension says which is which).
set(EXTENSION_NAME "studiosim_audio")
if(GODOTCPP_TARGET STREQUAL "template_release")
    set(EXTENSION_NAME "studiosim_audio.release")
endif()
set_target_properties(studiosim_audio PROPERTIES
    OUTPUT_NAME "${EXTENSION_NAME}"
    LIBRARY_OUTPUT_DIRECTORY "${GAME_BIN_DIR}"
    RUNTIME_OUTPUT_DIRECTORY "${GAME_BIN_DIR}"
)
foreach(cfg DEBUG RELEASE RELWITHDEBINFO MINSIZEREL)
    set_target_properties(studiosim_audio PROPERTIES
        LIBRARY_OUTPUT_DIRECTORY_${cfg} "${GAME_BIN_DIR}" RUNTIME_OUTPUT_DIRECTORY_${cfg} "${GAME_BIN_DIR}")
endforeach()
if(APPLE)
    # Find libphonon.dylib next to the extension at runtime (and only there: not where this computer keeps it).
    set_target_properties(studiosim_audio PROPERTIES BUILD_WITH_INSTALL_RPATH TRUE INSTALL_RPATH "@loader_path")
endif()
add_custom_command(TARGET studiosim_audio POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different "${PHONON_LIBRARY}" "${GAME_BIN_DIR}/"
    COMMENT "Copying Steam Audio next to the extension")
