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
    src/core/plugin_category.cpp
    src/core/plugin_host.cpp
    src/core/plugin_host_vst3.cpp
    src/core/sequencer.cpp
    src/core/spatializer.cpp
    src/core/miniaudio_impl.c
)
target_include_directories(sr_core PUBLIC src/core thirdparty/miniaudio)
target_link_libraries(sr_core PUBLIC phonon vst3_hosting)
if(APPLE)
    target_sources(sr_core PRIVATE src/core/midi_input_coremidi.cpp src/core/plugin_host_mac.mm src/core/plugin_window_mac.mm)
    set_source_files_properties(src/core/plugin_host_mac.mm src/core/plugin_window_mac.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
    target_link_libraries(sr_core PUBLIC "-framework CoreAudio" "-framework AudioToolbox" "-framework CoreFoundation"
                                         "-framework CoreMIDI" "-framework AppKit" "-framework CoreAudioKit"
                                         "-framework AVFoundation")
elseif(WIN32)
    target_sources(sr_core PRIVATE src/core/midi_input_win.cpp src/core/plugin_window_win.cpp)
    target_link_libraries(sr_core PUBLIC winmm user32 gdi32)
else()
    target_sources(sr_core PRIVATE src/core/midi_input_stub.cpp src/core/plugin_window_stub.cpp)
endif()
if(NOT MSVC)
    target_compile_options(sr_core PRIVATE $<$<COMPILE_LANGUAGE:CXX>:-Wall -Wextra>)
endif()

# ── Offline tests ───────────────────────────────────────────────────────────────────────────────────────────
add_executable(engine_tests tests/engine_tests.cpp)
target_link_libraries(engine_tests PRIVATE sr_core)
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
