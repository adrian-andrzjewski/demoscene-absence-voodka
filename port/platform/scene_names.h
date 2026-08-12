// scene_names.h - canonical VOODKA scene terminology.
//
// These names come from the original VOODKA.NFO terminology as confirmed for
// the port. Numeric part identifiers remain available only as stable
// historical numeric selectors (for example, --part 5).

#pragma once

#include <cstdint>
#include <cstring>

namespace vk {

enum class SceneId : uint8_t {
    OkoSzklo = 1,
    SwiatyniaCity = 2,
    TunelWygibasy = 3,
    ProcessorekNevosolek = 4,
    TorusUstepVillage = 5,
    Gratki = 6,
    GratkiWoda = 7,
    NadCzerwonymLampa = 8,
};

constexpr const char* kOkoSzkloName = "oko + szklo";
constexpr const char* kSwiatyniaCityName = "swiatynia city";
constexpr const char* kTunelWygibasyName = "tunel + wygibasy";
constexpr const char* kProcessorekNevosolekName = "processorek Nevosolek";
constexpr const char* kTorusUstepVillageName = "torus ustep village";
constexpr const char* kGratkiName = "gratki";
constexpr const char* kGratkiWodaName = "gratki + woda";
constexpr const char* kNadCzerwonymLampaName = "nad czerwonym lampa";

constexpr const char* sceneName(SceneId id) {
    switch (id) {
    case SceneId::OkoSzklo: return kOkoSzkloName;
    case SceneId::SwiatyniaCity: return kSwiatyniaCityName;
    case SceneId::TunelWygibasy: return kTunelWygibasyName;
    case SceneId::ProcessorekNevosolek: return kProcessorekNevosolekName;
    case SceneId::TorusUstepVillage: return kTorusUstepVillageName;
    case SceneId::Gratki: return kGratkiName;
    case SceneId::GratkiWoda: return kGratkiWodaName;
    case SceneId::NadCzerwonymLampa: return kNadCzerwonymLampaName;
    }
    return "unknown scene";
}

constexpr uint32_t sceneStartModPos(SceneId id) {
    switch (id) {
    case SceneId::OkoSzklo: return 0x0000;
    case SceneId::SwiatyniaCity: return 0x0400;
    case SceneId::TunelWygibasy: return 0x0B40;
    case SceneId::ProcessorekNevosolek: return 0x0D40;
    case SceneId::TorusUstepVillage: return 0x1400;
    case SceneId::Gratki: return 0x1B40;
    case SceneId::GratkiWoda: return 0x1C40;
    case SceneId::NadCzerwonymLampa: return 0x2040;
    }
    return 0;
}

constexpr int scenePart(SceneId id) {
    return static_cast<int>(id);
}

inline bool sceneTokenEquals(const char* token, const char* expected) {
    if (!token || !expected) return false;
    while (*token && *expected) {
        char a = *token++;
        char b = *expected++;
        if (a >= 'A' && a <= 'Z') a = static_cast<char>(a - 'A' + 'a');
        if (b >= 'A' && b <= 'Z') b = static_cast<char>(b - 'A' + 'a');
        if (a == '_') a = '-';
        if (b == '_') b = '-';
        if (a != b) return false;
    }
    return *token == 0 && *expected == 0;
}

inline int scenePartFromToken(const char* token) {
    if (sceneTokenEquals(token, "oko-szklo"))
        return scenePart(SceneId::OkoSzklo);
    if (sceneTokenEquals(token, "swiatynia-city"))
        return scenePart(SceneId::SwiatyniaCity);
    if (sceneTokenEquals(token, "tunel-wygibasy"))
        return scenePart(SceneId::TunelWygibasy);
    if (sceneTokenEquals(token, "processorek-nevosolek"))
        return scenePart(SceneId::ProcessorekNevosolek);
    if (sceneTokenEquals(token, "torus-ustep-village"))
        return scenePart(SceneId::TorusUstepVillage);
    if (sceneTokenEquals(token, "gratki"))
        return scenePart(SceneId::Gratki);
    if (sceneTokenEquals(token, "gratki-woda"))
        return scenePart(SceneId::GratkiWoda);
    if (sceneTokenEquals(token, "nad-czerwonym-lampa"))
        return scenePart(SceneId::NadCzerwonymLampa);
    return 0;
}

} // namespace vk
