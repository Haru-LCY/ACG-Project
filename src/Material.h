#pragma once
#include "long_march.h"

// Simple material structure for ray tracing
struct Material {
    glm::vec3 base_color;
    float roughness;
    float metallic;
    float transmission;  // 透明度：0=不透明, 1=完全透明
    float ior;           // 折射率 (Index of Refraction)
    float padding[2];    // 对齐到16字节边界

    Material()
        : base_color(0.8f, 0.8f, 0.8f)
        , roughness(0.5f)
        , metallic(0.0f)
        , transmission(0.0f)
        , ior(1.5f)
        , padding{0.0f, 0.0f} {}

    Material(const glm::vec3& color, float rough = 0.5f, float metal = 0.0f, float trans = 0.0f, float index_of_refraction = 1.5f)
        : base_color(color)
        , roughness(glm::clamp(rough, 0.01f, 1.0f))  // 避免除零
        , metallic(glm::clamp(metal, 0.0f, 1.0f))
        , transmission(glm::clamp(trans, 0.0f, 1.0f))
        , ior(glm::clamp(index_of_refraction, 1.0f, 3.0f))
        , padding{0.0f, 0.0f} {}
};

