# V3D asset viewer — standalone validation tool.
#
# Loads every V3D/V3M model from vodka.dat and renders it (flat-shaded or
# wireframe, orbit camera). Targets:
#   - extract_v3d            : pulls the 9 V3D/V3M entries to a data dir
#   - asset_viewer           : the D3D11 viewer
#   - asset_viewer_selftest : CTest v3d.viewer_parse (no GPU, parses only)

set(ASSET_VIEWER_DATA_DIR "${CMAKE_CURRENT_BINARY_DIR}/data")

# ---- extractor: vodka.dat -> flat .v3d/.v3m files ----------------------------
add_executable(extract_v3d extract_v3d.cpp)
if(MSVC)
    target_compile_options(extract_v3d PRIVATE /W4)
endif()

add_custom_command(
    OUTPUT "${ASSET_VIEWER_DATA_DIR}/.stamp"
    COMMAND $<TARGET_FILE:extract_v3d> "${VOODKA_DAT}" "${ASSET_VIEWER_DATA_DIR}"
    COMMAND ${CMAKE_COMMAND} -E touch "${ASSET_VIEWER_DATA_DIR}/.stamp"
    DEPENDS extract_v3d voodka_data
    COMMENT "Extracting V3D/V3M assets from vodka.dat"
)
add_custom_target(extract_v3d_assets DEPENDS "${ASSET_VIEWER_DATA_DIR}/.stamp")

# ---- the viewer ---------------------------------------------------------------
add_executable(asset_viewer WIN32 viewer_main.cpp v3d_parser.cpp renderer.cpp)
target_compile_definitions(asset_viewer PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
target_link_libraries(asset_viewer PRIVATE d3d11 d3dcompiler dxgi)
add_dependencies(asset_viewer extract_v3d_assets)
if(MSVC)
    target_compile_options(asset_viewer PRIVATE /W4)
endif()

# ---- parse selftest (CTest v3d.viewer_parse) ---------------------------------
add_executable(asset_viewer_selftest selftest.cpp v3d_parser.cpp)
target_compile_definitions(asset_viewer_selftest PRIVATE
    NOMINMAX WIN32_LEAN_AND_MEAN
    ASSET_VIEWER_DATA_DIR="${ASSET_VIEWER_DATA_DIR}")
add_dependencies(asset_viewer_selftest extract_v3d_assets)
add_test(NAME v3d.viewer_parse COMMAND asset_viewer_selftest)