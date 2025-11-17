#pragma once
#include "long_march.h"

// Simple material structure for ray tracing
struct Material {
    glm::vec3 base_color;
    float roughness;
    float metallic;
    float transmission;  // 透明度：0=不透明, 1=完全透明
    float ior;           // 折射率 (Index of Refraction)
    float alpha_threshold; // alpha shadow 阈值：0-1，用于决定像素是否透明
    float has_alpha_map;   // 是否有透明度贴图：0=无, 1=有

    Material()
        : base_color(0.8f, 0.8f, 0.8f)
        , roughness(0.5f)
        , metallic(0.0f)
        , transmission(0.0f)
        , ior(1.5f)
        , alpha_threshold(0.5f)
        , has_alpha_map(0.0f) {}

    Material(const glm::vec3& color, float rough = 0.5f, float metal = 0.0f, float trans = 0.0f, float index_of_refraction = 1.5f, float alpha_thresh = 0.5f, float has_alpha = 0.0f)
        : base_color(color)
        , roughness(glm::clamp(rough, 0.01f, 1.0f))  // 避免除零
        , metallic(glm::clamp(metal, 0.0f, 1.0f))
        , transmission(glm::clamp(trans, 0.0f, 1.0f))
        , ior(glm::clamp(index_of_refraction, 1.0f, 3.0f))
        , alpha_threshold(glm::clamp(alpha_thresh, 0.0f, 1.0f))
        , has_alpha_map(has_alpha) {}
};

