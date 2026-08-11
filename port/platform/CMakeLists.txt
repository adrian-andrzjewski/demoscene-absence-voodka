# platform/CMakeLists.txt - the C++ Windows integration layer.

set(VOODKA_PLATFORM_COMMON_SOURCES
    arena.cpp
    input.cpp
    timer.cpp
    audio_asm.cpp
    audio_controller.asm
    audio_lifecycle.asm
    audio_lookup.asm
    audio_seek.asm
    audio_runtime_state.asm
    audio_sync.asm
    audio_workers.asm
    progress.cpp
    pause.cpp
    bridge.cpp
)

set(VOODKA_PLATFORM_SOURCES
    production_entry.cpp
    ${VOODKA_PLATFORM_COMMON_SOURCES}
    audio_dispatch.asm
    win32_platform_abi.asm
    p4_raster.asm
    win32_d3d_dispatch.asm
)

set(VOODKA_REFERENCE_SOURCES
    app.cpp
    log.cpp
    timeline.cpp
    ${VOODKA_PLATFORM_COMMON_SOURCES}
    d3d11_present.cpp
    audio.cpp
)

add_executable(VOODKA WIN32 ${VOODKA_PLATFORM_SOURCES})

function(configure_voodka_platform_target target)
target_include_directories(${target} PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
target_include_directories(${target} PRIVATE "${CMAKE_SOURCE_DIR}/tools/validate")
target_link_libraries(${target} PRIVATE voodka_core)

if(MSVC)
    # Keep C++ warning flags off NASM sources.  CMake otherwise appends /W4
    # to the NASM command line, where it is parsed as another input file.
    target_compile_options(${target} PRIVATE $<$<COMPILE_LANGUAGE:CXX>:/W4>)
    target_compile_definitions(${target} PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
endif()

# Win32 subsystem + link libs
set_target_properties(${target} PROPERTIES
    VS_DEBUGGER_WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/.."
)
target_link_libraries(${target} PRIVATE
    d3d11 d3dcompiler dxgi
    winmm ole32 oleaut32 uuid avrt kernel32 user32 gdi32
)

# ensure the packed data archive is generated before building the app
add_dependencies(${target} voodka_data)

# Stage runtime data next to the exe so bin/<Config> is self-contained:
#   data/vodka.dat      (packed archive, byte-identical to the release's)
#   music/amnezja2.mod  (the 14-channel ProTracker module the demo plays)
add_custom_command(TARGET ${target} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory
            "$<TARGET_FILE_DIR:${target}>/data" "$<TARGET_FILE_DIR:${target}>/music"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different "${VOODKA_DAT}"
            "$<TARGET_FILE_DIR:${target}>/data/vodka.dat"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${VOODKA_REPO_ROOT}/music/amnezja2.mod"
            "$<TARGET_FILE_DIR:${target}>/music/amnezja2.mod"
)
endfunction()

configure_voodka_platform_target(VOODKA)
target_compile_definitions(VOODKA PRIVATE VOODKA_ASSEMBLY_PLATFORM=1)

# Non-shipped behavioral oracle. This target is intentionally separate from
# VOODKA so libxmp cannot enter the production dependency graph.
add_executable(VOODKA_REFERENCE WIN32 ${VOODKA_REFERENCE_SOURCES})
configure_voodka_platform_target(VOODKA_REFERENCE)
target_compile_definitions(VOODKA_REFERENCE PRIVATE VOODKA_REFERENCE_BUILD=1)
target_link_libraries(VOODKA_REFERENCE PRIVATE xmp_static)

# ---- VIRTUAL viewer (standalone VR-engine test shell) -----------------------
add_executable(VIRTUAL WIN32 virtual_main.cpp arena.cpp log.cpp)
target_include_directories(VIRTUAL PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(VIRTUAL PRIVATE loader_core_objects)
if(MSVC)
    target_compile_options(VIRTUAL PRIVATE /W4)
    target_compile_definitions(VIRTUAL PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
endif()
target_link_libraries(VIRTUAL PRIVATE user32)
add_dependencies(VIRTUAL voodka_world)
add_custom_command(TARGET VIRTUAL POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different "${VOODKA_WORLD}"
            "$<TARGET_FILE_DIR:VIRTUAL>/data/world"
)
add_test(NAME virtual.load COMMAND VIRTUAL --check)
