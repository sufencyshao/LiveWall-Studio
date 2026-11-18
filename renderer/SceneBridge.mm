// Local LiveWall prototype bridge. SPDX-License-Identifier: GPL-3.0-only
#include "Platform/Apple/SceneWallpaperBindings.h"

extern "C" owe_scene_wallpaper* lw_scene_open(
    void* layer, uint32_t width, uint32_t height, double scale, uint32_t display,
    const char* project, const char* assets, const char* cache, float volume, bool muted,
    int32_t scaling
) {
    owe_scene_wallpaper* scene = nullptr;
    if (owe_scene_wallpaper_new(&scene) != 0) return nullptr;
    if (owe_scene_wallpaper_init(scene) != 0 ||
        owe_scene_wallpaper_set_display_id(scene, display) != 0 ||
        owe_scene_wallpaper_init_metal(scene, layer, width, height, 0, 0, scale) != 0 ||
        owe_scene_wallpaper_set_property_int32(scene, owe_property_scaling_mode(), scaling) != 0 ||
        owe_scene_wallpaper_apply_config(scene, project, assets, cache, 30, false, volume, muted, false, nullptr) != 0) {
        owe_scene_wallpaper_delete(scene);
        return nullptr;
    }
    return scene;
}

extern "C" void lw_scene_close(owe_scene_wallpaper* scene) {
    owe_scene_wallpaper_delete(scene);
}

extern "C" void lw_scene_pause(owe_scene_wallpaper* scene, bool paused) {
    owe_scene_wallpaper_set_paused(scene, paused);
}

extern "C" void lw_scene_audio(owe_scene_wallpaper* scene, bool muted, float volume) {
    owe_scene_wallpaper_set_audio_muted(scene, muted);
    owe_scene_wallpaper_set_audio_volume(scene, volume);
}

extern "C" int32_t lw_scene_observe_audio(owe_scene_wallpaper* scene,
    owe_audio_requirement_callback callback, void* context, owe_audio_requirement_callback_drop drop) {
    return owe_scene_wallpaper_set_audio_requirement_callback(scene, callback, context, drop);
}

extern "C" void lw_scene_audio_reactive(owe_scene_wallpaper* scene, bool enabled) {
    owe_scene_wallpaper_set_property_bool(scene, owe_property_audio_response_enabled(), enabled);
    owe_scene_wallpaper_set_target_fps(scene, enabled ? 60 : 30);
}

extern "C" void lw_scene_scaling(owe_scene_wallpaper* scene, int32_t scaling) {
    owe_scene_wallpaper_set_property_int32(scene, owe_property_scaling_mode(), scaling);
}

extern "C" void lw_scene_framing(owe_scene_wallpaper* scene, double x, double y) {
    owe_scene_wallpaper_set_framing(scene, x, y);
}

extern "C" void lw_scene_pointer(owe_scene_wallpaper* scene, double x, double y) {
    owe_scene_wallpaper_mouse_input(scene, x, y);
}

extern "C" uint64_t lw_scene_frames(owe_scene_wallpaper* scene) {
    owe_surface_health health {};
    return owe_scene_wallpaper_surface_health(scene, &health) == 0 ? health.frames_presented : 0;
}
