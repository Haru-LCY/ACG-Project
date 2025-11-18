#pragma once
#include "long_march.h"

// Simple material structure for ray tracing
struct Material {
    glm::vec3 base_color;
    float roughness;
    float metallic;
    float transmission;  // 透射系数：0=不透光, 1=完全透光（标量，用于表示透光强度）
    glm::vec3 transmission_color; // 透射颜色/吸收色（用于有色玻璃的 Beer–Lambert 衰减）
    float ior;           // 折射率 (Index of Refraction)
    float alpha_threshold; // alpha shadow 阈值：0-1，用于决定像素是否透明
    float has_alpha_map;   // 是否有透明度贴图：0=无, 1=有
    int texture_id;        // 纹理ID：-1=无纹理, >=0=纹理在数组中的索引
    float padding[3];      // 对齐到16字节

    Material()
        : base_color(0.8f, 0.8f, 0.8f)
        , roughness(0.5f)
        , metallic(0.0f)
        , transmission(0.0f)
        , transmission_color(1.0f, 1.0f, 1.0f)
        , ior(1.5f)
        , alpha_threshold(0.5f)
        , has_alpha_map(0.0f)
        , texture_id(-1) {
        padding[0] = padding[1] = padding[2] = 0.0f;
    }

    Material(const glm::vec3& color, float rough = 0.5f, float metal = 0.0f, float trans = 0.0f, const glm::vec3& trans_color = glm::vec3(1.0f), float index_of_refraction = 1.5f, float alpha_thresh = 0.5f, float has_alpha = 0.0f)
        : base_color(color)
        , roughness(glm::clamp(rough, 0.01f, 1.0f))  // 避免除零
        , metallic(glm::clamp(metal, 0.0f, 1.0f))
        , transmission(glm::clamp(trans, 0.0f, 1.0f))
        , transmission_color(trans_color)
        , ior(glm::clamp(index_of_refraction, 1.0f, 3.0f))
        , alpha_threshold(glm::clamp(alpha_thresh, 0.0f, 1.0f))
        , has_alpha_map(has_alpha)
        , texture_id(-1) {
        padding[0] = padding[1] = padding[2] = 0.0f;
    }

    // 兼容旧构造签名：Material(color, rough, metal, transmission, ior)
    // 如果没有提供 transmission_color，默认使用 base_color（有色玻璃时建议显式提供 transmission_color）
    Material(const glm::vec3& color, float rough, float metal, float trans, float index_of_refraction)
        : base_color(color)
        , roughness(glm::clamp(rough, 0.01f, 1.0f))
        , metallic(glm::clamp(metal, 0.0f, 1.0f))
        , transmission(glm::clamp(trans, 0.0f, 1.0f))
        , transmission_color(color)
        , ior(glm::clamp(index_of_refraction, 1.0f, 3.0f))
        , alpha_threshold(0.5f)
        , has_alpha_map(0.0f)
        , texture_id(-1) {
        padding[0] = padding[1] = padding[2] = 0.0f;
    }
};

