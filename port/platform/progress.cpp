// progress.cpp - centralized demo-run progress reporting.
//
// Drives the window title and a structured console log from the actual demo
// timeline (ModPos, as maintained by the audio subsystem and read back from the
// ASM core's GetModPos). Updated once per VBL frame from waitVbl(), so it is
// synchronized with whatever part/scene is currently rendering.
//
// Only emits when the active scene (part/scene/effect) actually changes, so
// logging stays sparse and correlates cleanly with what is on screen.

#include "platform_abi.h"
#include "scene_names.h"
#include "window_title.h"
#include <windows.h>
#include <cstdio>
#include <cstdarg>

#if defined(VOODKA_ASSEMBLY_PLATFORM)
extern "C" int asm_log_vformat(char*, unsigned, const char*, const char*);
#endif

namespace vk {

namespace {

struct Scene {
    uint32_t modpos;     // first ModPos at which this scene is active
    SceneId  id;         // canonical scene identity
    const char* scene;   // scene name
    const char* effect;  // major effect within the scene (may be element)
};

// Ascending by modpos. The boundary values come from the same timeline the
// parts use (see app.cpp kPartStartModPos + per-part ModPos thresholds).
const Scene kScenes[] = {
    { 0x0000, SceneId::OkoSzklo,             kOkoSzkloName,             "Znik fade-in"          },
    { 0x0100, SceneId::OkoSzklo,             kOkoSzkloName,             "Texture-mapped head"   },
    { 0x0200, SceneId::OkoSzklo,             kOkoSzkloName,             "Logo overlay"          },
    { 0x0300, SceneId::OkoSzklo,             kOkoSzkloName,             "Palette fade"          },
    { 0x0400, SceneId::SwiatyniaCity,       kSwiatyniaCityName,        "Camera fly-through"    },
    { 0x0730, SceneId::SwiatyniaCity,       kSwiatyniaCityName,        "Reflective water"      },
    { 0x0B40, SceneId::TunelWygibasy,       kTunelWygibasyName,        "Twisted landscape"     },
    { 0x1400, SceneId::TorusUstepVillage,   kTorusUstepVillageName,    "Torus over water"      },
    { 0x1B40, SceneId::Gratki,              kGratkiName,               "2D bump mapping"       },
    { 0x1C40, SceneId::GratkiWoda,          kGratkiWodaName,           "7-phase water"         },
    { 0x2040, SceneId::NadCzerwonymLampa,   kNadCzerwonymLampaName,    "Rotating object view"  },
};
const int kSceneCount = (int)(sizeof(kScenes) / sizeof(kScenes[0]));

HWND g_hwnd = nullptr;
int  g_lastScene = -1;      // index of the last scene emitted (-1 = none yet)
long g_transitionCount = 0; // running scene index (monotonic transition id)

#if defined(VOODKA_ASSEMBLY_PLATFORM)
void formatAssembly(char* out, unsigned capacity, const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    (void)asm_log_vformat(out, capacity, fmt, ap);
    va_end(ap);
}
#endif

void formatElapsed(char* out, size_t n, double sec) {
    int mm = (int)(sec / 60.0);
    int ss = (int)sec % 60;
    int tt = (int)(sec * 10.0) % 10;
#if defined(VOODKA_ASSEMBLY_PLATFORM)
    formatAssembly(out, static_cast<unsigned>(n), "%02d:%02d.%d", mm, ss, tt);
#else
    snprintf(out, n, "%02d:%02d.%d", mm, ss, tt);
#endif
}

} // namespace

void progressInit(void* hwnd) {
    g_hwnd = (HWND)hwnd;
    g_lastScene = -1;
    g_transitionCount = 0;
}

void progressUpdate() {
    uint32_t mp = getModPos();
    timelineFrame(getFrameCounter(), getQpcUs(), mp);

    // find the active scene: the last boundary <= current ModPos
    int idx = 0;
    for (int i = 0; i < kSceneCount; i++) {
        if (mp >= kScenes[i].modpos) idx = i;
        else break;
    }

    if (idx == g_lastScene) return;      // no meaningful transition
    g_lastScene = idx;
    g_transitionCount++;

    const Scene& s = kScenes[idx];
    char tbuf[32];
    formatElapsed(tbuf, sizeof tbuf, audioElapsedSec());

#if defined(VOODKA_DEBUG_TITLE)
    char title[256];
#if defined(VOODKA_ASSEMBLY_PLATFORM)
    formatAssembly(title, sizeof title,
                   "VOODKA (Absence) - Scene %d/8  %s  [%s]  t=%s  scene#%ld",
                   scenePart(s.id), s.scene, s.effect, tbuf, g_transitionCount);
#else
    snprintf(title, sizeof title,
             "VOODKA (Absence) - Scene %d/8  %s  [%s]  t=%s  scene#%ld",
             scenePart(s.id), s.scene, s.effect, tbuf, g_transitionCount);
#endif
    if (g_hwnd) SetWindowTextA(g_hwnd, title);
#else
    if (g_hwnd) SetWindowTextW(g_hwnd, kProductionWindowTitle);
#endif

    logPrint("[scene] part=%d/8 scene=\"%s\" effect=\"%s\" elapsed=%s "
             "modpos=0x%x scene_index=%ld\n",
             scenePart(s.id), s.scene, s.effect, tbuf, mp, g_transitionCount);
}

} // namespace vk
