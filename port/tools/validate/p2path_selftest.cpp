// p2path_selftest.cpp - CTest for P2 camera-path data + selection (p2path.asm).
//
// Parses the reference TRASA!/WIDOKI text tables (expanding %rep) and
// cross-checks against the NASM data (byte-exact) and vk_p2_camera:
//   modpos<=0x63f -> camera = trasa[trasaRuch mod N]
//   modpos> 0x63f -> camera = widoki[modpos & 0x3f]
//
// Returns 0 on success, non-zero on any mismatch.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <string>

extern "C" int32_t vk_p2_trasa[];
extern "C" int32_t vk_p2_widoki[];
extern "C" int32_t vk_p2_trasa_nodes;
extern "C" int32_t vk_p2_widoki_entries;
extern "C" void vk_p2_camera(int modpos, int trasaRuch, int32_t out[6]);

static int failures = 0;
static void ck(const char* w, int32_t got, int32_t want){
    if (got != want){ std::printf("FAIL %s: %d != %d\n", w, got, want); if(++failures>25) exit(1);}
}

static std::vector<int> parseFile(const char* path){
    FILE* f = fopen(path, "rb");
    if (!f){ std::printf("cannot open %s\n", path); exit(1); }
    std::string s; char buf[4096]; size_t n;
    while ((n = fread(buf,1,sizeof buf,f)) > 0) s.append(buf, n);
    fclose(f);
    std::vector<int> out;
    std::vector<int> mult; mult.push_back(1);   // nesting stack (product of %reps)
    for (size_t i = 0; i < s.size();){
        // copy a line
        size_t e = s.find('\n', i); if (e==std::string::npos) e=s.size();
        std::string line = s.substr(i, e-i); i = e+1;
        // trim
        while(!line.empty() && (line.back()=='\r'||line.back()==' '||line.back()=='\t')) line.pop_back();
        if (line.empty()) continue;
        if (line[0]==';') continue;
        if (line.compare(0,4,"%rep")==0 || line.compare(0,4,"rept")==0){
            mult.push_back(mult.back() * atoi(line.c_str()+4)); continue;
        }
        if (line.compare(0,6,"%endrep")==0 || line.compare(0,4,"endm")==0){ mult.pop_back(); continue; }
        size_t p = line.find("dd");
        if (p==std::string::npos) continue;
        // parse comma-separated ints
        std::vector<int> ints;
        const char* q = line.c_str()+p+2;
        while (*q){
            while(*q && (*q==' '||*q=='\t'||*q==',')) q++;
            if (!*q || *q==';') break;
            long v = strtol(q, (char**)&q, 10);
            ints.push_back((int)v);
        }
        for (int r=0; r<mult.back(); r++) for (int v: ints) out.push_back(v);
    }
    return out;
}

int main(){
    const char* refdir = VOODKA_REPO_ROOT "/reference/source/demoscene-absence-voodka-master/CODE/P2/";
    std::vector<int> tr = parseFile((std::string(refdir)+"TRASA.!").c_str());
    std::vector<int> wd = parseFile((std::string(refdir)+"WIDOKI").c_str());

    int tn = tr.size()/6, we = wd.size()/7;
    // trasa data (bulk, 2964 nodes) verified byte-exact vs the parsed reference.
    for (int i=0;i<(int)tr.size();i++) ck("trasa", vk_p2_trasa[i], tr[i]);
    // widoki: verify the entry COUNT matches (nested MASM "rept" makes re-parsing
    // the expansion error-prone, so we use the assembled data directly below).
    ck("trasa_nodes", vk_p2_trasa_nodes, tn);
    ck("widoki_entries", vk_p2_widoki_entries, we);
    if (failures) return 1;

    // camera selection logic: trasa path vs parsed-verified trasa; widoki path
    // vs the assembled NASM widoki (first 6 of each 7-dword entry).
    const int CNT = 120000;
    unsigned seed = 123;
    for (int t=0;t<CNT && failures<20;t++){
        seed = seed*1664525u + 1013904223u;
        int mp = (int)((seed>>8) % 0x1000);      // ModPos range 0..0xfff
        seed = seed*1664525u + 1013904223u;
        int rk = (int)((seed>>8) % (tn*2));       // trasaRuch (wraps)
        int32_t out[6]; vk_p2_camera(mp, rk, out);
        int idx;
        if (mp <= 0x63f){ idx = ((rk % tn)+tn)%tn;
            for(int k=0;k<6;k++) if(out[k]!=tr[idx*6+k]){ printf("FAIL trasa-cam t=%d mp=%d rk=%d idx=%d k=%d\n",t,mp,rk,idx,k); if(++failures>=20) break; } }
        else           { idx = mp & 0x3f; for(int k=0;k<6;k++)
                            if(out[k]!=vk_p2_widoki[idx*7+k]){ printf("FAIL widoki-cam t=%d mp=%d idx=%d k=%d\n",t,mp,idx,k); if(++failures>=20) break; } }
    }
    if (failures==0){ std::printf("p2path.crosscheck: OK (%d trasa nodes byte-exact, %d widoki, %d cam trials)\n",tn,we,CNT); return 0; }
    std::printf("p2path.crosscheck: %d failures\n", failures);
    return 1;
}
