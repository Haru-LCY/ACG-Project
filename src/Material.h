#pragma once
#include "long_march.h"

// Principled BSDF材质结构体（用于光线追踪）
// 基于Disney的Principled BSDF模型
// Principled BSDF material structure for ray tracing
// Based on Disney's Principled BSDF model
struct Material {
    // ========== 基础属性 ==========
    glm::vec3 base_color;        // 基础颜色（RGB，范围0-1）
    float roughness;             // 粗糙度（0-1，0=完全光滑，1=完全粗糙）
    
    float metallic;              // 金属度（0-1，0=非金属，1=金属）
    float specular;              // 镜面反射强度（0-1）
    float specular_tint;         // 镜面反射色调（0-1，用基础颜色着色镜面反射）
    float anisotropic;           // 各向异性反射（0-1）
    
    float anisotropic_rotation;  // 各向异性旋转角度（0-1）
    float sheen;                 // 光泽效果（用于类布料材质，0-1）
    float sheen_tint;            // 光泽色调（0-1，用基础颜色着色光泽）
    float clearcoat;             // 清漆层强度（0-1）
    
    float clearcoat_roughness;   // 清漆粗糙度（0-1）
    float transmission;          // 透射/透明度（0-1，0=不透明，1=完全透明）
    float transmission_roughness; // 透射粗糙度（0-1）
    float ior;                   // 折射率（Index of Refraction）
    
    glm::vec3 transmission_color; // 透射颜色/吸收（RGB）
    float subsurface;            // 次表面散射强度（0-1）
    
    glm::vec3 subsurface_color;  // 次表面散射颜色（RGB）
    float padding1;              // 填充（用于16字节对齐）
    
    glm::vec3 subsurface_radius; // 次表面散射半径（RGB，单位：米）
    float padding2;               // 填充（用于16字节对齐）
    
    glm::vec3 emission_color;    // 自发光颜色（RGB）
    float emission_strength;     // 自发光强度
    
    float alpha_threshold;       // Alpha阴影阈值（0-1）
    float has_alpha_map;         // 是否有Alpha贴图标志（>0.5=true）
    int texture_id;              // 纹理ID（-1=无纹理）
    float padding3;              // 填充（用于16字节对齐）

    // 默认构造函数：使用默认材质参数
    Material()
        : base_color(0.8f, 0.8f, 0.8f)      // 浅灰色基础颜色
        , roughness(0.5f)                   // 中等粗糙度
        , metallic(0.0f)                    // 非金属
        , specular(0.5f)                    // 默认镜面反射
        , specular_tint(0.0f)              // 无镜面色调
        , anisotropic(0.0f)                 // 无各向异性
        , anisotropic_rotation(0.0f)        // 无旋转
        , sheen(0.0f)                       // 无光泽
        , sheen_tint(0.5f)                  // 默认光泽色调
        , clearcoat(0.0f)                   // 无清漆
        , clearcoat_roughness(0.03f)        // 清漆粗糙度（如果启用）
        , transmission(0.0f)                // 不透明
        , transmission_roughness(0.0f)      // 无透射粗糙度
        , ior(1.45f)                        // 默认折射率（玻璃）
        , transmission_color(1.0f, 1.0f, 1.0f)  // 白色透射
        , subsurface(0.0f)                 // 无次表面散射
        , subsurface_color(0.8f, 0.8f, 0.8f) // 浅灰色次表面
        , padding1(0.0f)
        , subsurface_radius(1.0f, 1.0f, 1.0f)  // 默认半径
        , padding2(0.0f)
        , emission_color(0.0f, 0.0f, 0.0f)  // 无自发光
        , emission_strength(0.0f)
        , alpha_threshold(0.5f)             // 默认Alpha阈值
        , has_alpha_map(0.0f)               // 无Alpha贴图
        , texture_id(-1)                     // 无纹理
        , padding3(0.0f) {
    }

    // 常用构造函数：颜色、粗糙度、金属度
    // color: 基础颜色
    // rough: 粗糙度（会被限制在0.001-1.0范围内）
    // metal: 金属度（会被限制在0.0-1.0范围内）
    Material(const glm::vec3& color, float rough, float metal)
        : base_color(color)
        , roughness(glm::clamp(rough, 0.001f, 1.0f))
        , metallic(glm::clamp(metal, 0.0f, 1.0f))
        , specular(0.5f)
        , specular_tint(0.0f)
        , anisotropic(0.0f)
        , anisotropic_rotation(0.0f)
        , sheen(0.0f)
        , sheen_tint(0.5f)
        , clearcoat(0.0f)
        , clearcoat_roughness(0.03f)
        , transmission(0.0f)
        , transmission_roughness(0.0f)
        , ior(1.45f)
        , transmission_color(1.0f, 1.0f, 1.0f)
        , subsurface(0.0f)
        , subsurface_color(0.8f, 0.8f, 0.8f)
        , padding1(0.0f)
        , subsurface_radius(1.0f, 1.0f, 1.0f)
        , padding2(0.0f)
        , emission_color(0.0f, 0.0f, 0.0f)
        , emission_strength(0.0f)
        , alpha_threshold(0.5f)
        , has_alpha_map(0.0f)
        , texture_id(-1)
        , padding3(0.0f) {
    }

    // 遗留构造函数（用于向后兼容）
    // color: 基础颜色
    // rough: 粗糙度（会被限制在0.001-1.0范围内）
    // metal: 金属度（会被限制在0.0-1.0范围内）
    // trans: 透射度（会被限制在0.0-1.0范围内）
    // index_of_refraction: 折射率（会被限制在1.0-3.0范围内）
    Material(const glm::vec3& color, float rough, float metal, float trans, float index_of_refraction)
        : base_color(color)
        , roughness(glm::clamp(rough, 0.001f, 1.0f))
        , metallic(glm::clamp(metal, 0.0f, 1.0f))
        , specular(0.5f)
        , specular_tint(0.0f)
        , anisotropic(0.0f)
        , anisotropic_rotation(0.0f)
        , sheen(0.0f)
        , sheen_tint(0.5f)
        , clearcoat(0.0f)
        , clearcoat_roughness(0.03f)
        , transmission(glm::clamp(trans, 0.0f, 1.0f))
        , transmission_roughness(0.0f)
        , ior(glm::clamp(index_of_refraction, 1.0f, 3.0f))
        , transmission_color(color)
        , subsurface(0.0f)
        , subsurface_color(0.8f, 0.8f, 0.8f)
        , padding1(0.0f)
        , subsurface_radius(1.0f, 1.0f, 1.0f)
        , padding2(0.0f)
        , emission_color(0.0f, 0.0f, 0.0f)
        , emission_strength(0.0f)
        , alpha_threshold(0.5f)
        , has_alpha_map(0.0f)
        , texture_id(-1)
        , padding3(0.0f) {
    }
};

// 验证结构体大小与HLSL布局一致（每行必须16字节对齐）
// Verify struct size is consistent with HLSL layout (must be 16 byte aligned per row)
static_assert(sizeof(Material) == 144, "Material size mismatch: C++ Material must match HLSL layout (144 bytes)");

