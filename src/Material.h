#pragma once
#include "long_march.h"

// Simple material structure for ray tracing
struct Material {
    glm::vec3 base_color;
    float roughness;
    float metallic;

    Material()
        : base_color(0.8f, 0.8f, 0.8f)
        , roughness(0.5f)
        , metallic(0.0f) {}

    Material(const glm::vec3& color, float rough = 0.5f, float metal = 0.0f)
        : base_color(color)
        , roughness(glm::clamp(rough, 0.01f, 1.0f))  // 避免除零
        , metallic(glm::clamp(metal, 0.0f, 1.0f)) {}
};

