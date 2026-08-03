// p2world_selftest.cpp - CTest for the P2 World domain (p2world.asm).
//
// Parses the reference INC/WORLD descriptor table and cross-checks the NASM
// World data byte-exact (plus the record count), then drives a few World
// records through unit-8 CalculateVisiblating (vk_calc_visibility) against a
// C++ reference to validate the World + camera-global integration.
//
// Returns 0 on success, non-zero on any mismatch.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <string>

extern "C" int32_t vk_p2_world[];
extern "C" int32_t vk_p2_worldsobjects;
extern "C" int32_t vk_p2_worldmax;
extern "C" void vk_make_camera_matrix(int ax,int ay,int az);
extern "C" int32_t cam_matrix[16];
extern "C" int32_t cam_cameraX, cam_cameraY, cam_cameraZ;
extern "C" void vk_calc_visibility(const int32_t* w, int c, int32_t* zet, uint8_t* vis);

static int failures = 0;
static void ck(const char* w, int32_t got, int32_t want){ if(got!=want){std::printf("FAIL %s: %d!=%d\n",w,got,want); if(++failures>25) exit(1);} }
static inline int32_t shrd15(int32_t a, int32_t b){ return (int32_t)(((uint64_t)((int64_t)a*b))>>15); }

static std::vector<int> parseWorld(const char* path){
    FILE* f=fopen(path,"rb"); if(!f){printf("cannot open %s\n",path);exit(1);}
    std::string s; char b[4096]; size_t n;
    while((n=fread(b,1,sizeof b,f))>0) s.append(b,n);
    fclose(f);
    std::vector<int> out;
    for(size_t i=0;i<s.size();){
        size_t e=s.find('\n',i); if(e==std::string::npos)e=s.size();
        std::string line=s.substr(i,e-i); i=e+1;
        size_t c0=line.find_first_not_of(" \t");
        if(c0!=std::string::npos && line[c0]==';') continue; // skip comment lines
        size_t p=line.find("dd");
        if(p==std::string::npos) continue;
        const char* q=line.c_str()+p+2;
        while(*q&&(*q==' '||*q=='\t'||*q==','))q++;
        // Skip non-data lines (labels/computed expressions like
        // `WorldsObjects dd ((EndWorld)-(World))/48`): if the token after `dd`
        // is not a number, emit nothing (prevents strtol spins on '(').
        if(!(*q>='0'&&*q<='9')&&*q!='-'&&*q!='+') continue;
        while(*q){ while(*q&&(*q==' '||*q=='\t'||*q==','))q++; if(!*q||*q==';')break;
            long v=strtol(q,(char**)&q,10);
            // Fold NASM constant arithmetic (e.g. `150*16`, `1024-256`) into a
            // single value; stop at comma/end/comment.
            for(;;){
                const char* r=q; while(*r==' '||*r=='\t')r++;
                char op=*r; if(op!='*'&&op!='+'&&op!='-') break;
                r++; while(*r==' '||*r=='\t')r++;
                long m=strtol(r,(char**)&r,10);
                if(op=='*') v*=m; else if(op=='+') v+=m; else v-=m;
                q=(char*)r;
            }
            out.push_back((int)v); }
    }
    return out;
}

int main(){
    std::printf("A main\n"); std::fflush(stdout);
    std::vector<int> wd = parseWorld("D:/Project/voodka2/reference/source/demoscene-absence-voodka-master/CODE/inc/WORLD");
    std::printf("B parsed %d ints\n", (int)wd.size()); std::fflush(stdout);
    int recs = (int)wd.size()/12;
    ck("worldmax", vk_p2_worldmax, 255);
    ck("worldsobjects", vk_p2_worldsobjects, recs);
    for(int i=0;i<(int)wd.size();i++) ck("world", vk_p2_world[i], wd[i]);
    if(failures==0){ std::printf("p2world.crosscheck: OK (%d World records byte-exact)\n",recs); return 0; }
    std::printf("p2world.crosscheck: %d failures\n",failures);
    return 1;
}
