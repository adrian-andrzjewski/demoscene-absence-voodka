// datas_entries.h - the 16 CODE/DATAS vertex/face mesh pairs.
//
// Each pair is a vertex table (*_S.INC: dw x,y,z rows) plus its matching
// face table (*_C.INC: dw i0,i1,i2 rows), assembled straight into the demo
// EXE at TASM time (never packed into vodka.dat). Consumed by P1/P3/P4/P8;
// the *_3/4 and SHAPE/CONSTR/TOR/SHD/CND entries are orphaned dev artifacts
// (see docs/ASSET_FORMATS.md §4.5). The viewer renders all of them.

#pragma once

struct DatasPair {
    const char* name;   // display name (lowercase)
    const char* verts;  // *S.INC vertex file
    const char* faces;  // *C.INC face file
};

inline constexpr DatasPair kDatasPairs[] = {
    // --- consumed by the shipped demo link -------------------------------
    {"shape3+constr3",    "SHAPE3.INC", "CONSTR3.INC"},  // P1 shape/con
    {"log_s+log_c",       "LOG_S.INC",  "LOG_C.INC"},    // P3 logo mesh
    {"vws_1+vwc_1",       "VWS_1.INC",  "VWC_1.INC"},    // P4 morph base
    {"vws_2+vwc_2",       "VWS_2.INC",  "VWC_2.INC"},    // P4 src1
    {"vws_3+vwc_3",       "VWS_3.INC",  "VWC_3.INC"},    // P4 src2
    {"vws_4+vwc_4",       "VWS_4.INC",  "VWC_4.INC"},    // P4 src3
    {"sw_s_1+sw_c_1",     "SW_S_1.INC", "SW_C_1.INC"},   // P8 morph base
    {"sw_s_2+sw_c_2",     "SW_S_2.INC", "SW_C_2.INC"},   // P8 s2
    {"ob_s_1+ob_c_1",     "OB_S_1.INC", "OB_C_1.INC"},   // P8 src3
    {"ob_s_2+ob_c_2",     "OB_S_2.INC", "OB_C_2.INC"},   // P8 src4
    {"ob_s_3+ob_c_3",     "OB_S_3.INC", "OB_C_3.INC"},   // P8 src5
    // --- orphaned dev artifacts (referenced by no current source) ---------
    {"shape+constr",      "SHAPE.INC",  "CONSTR.INC"},
    {"tor_s+tor_c",       "TOR_S.INC",  "TOR_C.INC"},
    {"shd+cnd",           "SHD.INC",    "CND.INC"},
    {"sw_s_3+sw_c_3",     "SW_S_3.INC", "SW_C_3.INC"},
    {"sw_s_4+sw_c_4",     "SW_S_4.INC", "SW_C_4.INC"},
};

inline constexpr int kDatasPairCount =
    (int)(sizeof(kDatasPairs) / sizeof(kDatasPairs[0]));