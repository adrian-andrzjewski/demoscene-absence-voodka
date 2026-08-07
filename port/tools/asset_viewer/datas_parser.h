// datas_parser.h - CODE/DATAS compile-time mesh loader.
//
// The DATAS files are assembly-time TEXT includes (TASM strides them into
// raw 16-bit word tables inside the part OBJ). Format (docs/ASSET_FORMATS.md
// §4.5):
//   vertex table (*_S.INC):  first line ";Vertices: N", then N rows of
//                            "dw x,y,z"  -> 6 B/vertex, signed 16-bit
//                            object-space units (NO x16 scale).
//   face table   (*_C.INC):  first line ";Faces: M", then M rows of
//                            "dw i0,i1,i2" -> 6 B/face, 0-based indices.
// The parser reads both text files, validates row counts against the header
// comments and every index against the vertex count, and builds a V3DAsset.

#pragma once

#include "v3d_parser.h"

#include <optional>
#include <string>

// Load a vertex/face pair. Returns std::nullopt on parse error (prints the
// reason to stderr).
std::optional<V3DAsset> loadDatasMesh(const std::string& vertInc,
                                      const std::string& faceInc,
                                      const std::string& name);