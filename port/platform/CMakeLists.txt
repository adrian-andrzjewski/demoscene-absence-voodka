# platform/CMakeLists.txt - the C++ Windows integration layer.

set(VOODKA_PLATFORM_SOURCES
    app.cpp
    arena.cpp
    log.cpp
    input.cpp
    timer.cpp
    d3d11_present.cpp
    audio.cpp
    progress.cpp
    timeline.cpp
    pause.cpp
    bridge.cpp
)

add_executable(VOODKA WIN32 ${VOODKA_PLATFORM_SOURCES})

target_include_directories(VOODKA PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(VOODKA PRIVATE xmp_static voodka_core)

if(MSVC)
    target_compile_options(VOODKA PRIVATE /W4)
    target_compile_definitions(VOODKA PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
endif()

# Win32 subsystem + link libs
set_target_properties(VOODKA PROPERTIES
    VS_DEBUGGER_WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/.."
)
target_link_libraries(VOODKA PRIVATE
    d3d11 d3dcompiler dxgi
    winmm ole32 oleaut32 uuid avrt kernel32 user32 gdi32
)

# ensure the packed data archive is generated before building the app
add_dependencies(VOODKA voodka_data)

# Stage runtime data next to the exe so bin/<Config> is self-contained:
#   data/vodka.dat      (packed archive, byte-identical to the release's)
#   music/amnezja2.mod  (the 14-channel ProTracker module the demo plays)
add_custom_command(TARGET VOODKA POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory
            "$<TARGET_FILE_DIR:VOODKA>/data" "$<TARGET_FILE_DIR:VOODKA>/music"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different "${VOODKA_DAT}"
            "$<TARGET_FILE_DIR:VOODKA>/data/vodka.dat"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${VOODKA_REPO_ROOT}/music/amnezja2.mod"
            "$<TARGET_FILE_DIR:VOODKA>/music/amnezja2.mod"
)

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
