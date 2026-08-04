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
