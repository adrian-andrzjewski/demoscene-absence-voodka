# platform/CMakeLists.txt - the C++ Windows integration layer.

set(VOODKA_PLATFORM_COMMON_SOURCES
    app.cpp
    arena.cpp
    log.cpp
    input.cpp
    timer.cpp
    d3d11_present.cpp
    audio_asm.cpp
    progress.cpp
    timeline.cpp
    pause.cpp
    bridge.cpp
)

set(VOODKA_PLATFORM_SOURCES
    ${VOODKA_PLATFORM_COMMON_SOURCES}
    audio_dispatch.cpp
)

set(VOODKA_REFERENCE_SOURCES
    ${VOODKA_PLATFORM_COMMON_SOURCES}
    audio.cpp
)

add_executable(VOODKA WIN32 ${VOODKA_PLATFORM_SOURCES})

function(configure_voodka_platform_target target)
target_include_directories(${target} PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
target_include_directories(${target} PRIVATE "${CMAKE_SOURCE_DIR}/tools/validate")
target_link_libraries(${target} PRIVATE voodka_core)

if(MSVC)
    target_compile_options(${target} PRIVATE /W4)
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

# Non-shipped behavioral oracle. This target is intentionally separate from
# VOODKA so libxmp cannot enter the production dependency graph.
add_executable(VOODKA_REFERENCE WIN32 ${VOODKA_REFERENCE_SOURCES})
configure_voodka_platform_target(VOODKA_REFERENCE)
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
