#pragma once
#include "long_march.h"

// Principled BSDF material structure for ray tracing
// Based on Disney's Principled BSDF model
struct Material {
    // Base properties
    glm::vec3 base_color;
    float roughness;
    
    float metallic;
    float specular;              // Specular reflection strength (0-1)
    float specular_tint;         // Tint specular reflection with base color (0-1)
    float anisotropic;           // Anisotropic reflection (0-1)
    
    float anisotropic_rotation;  // Anisotropic rotation angle (0-1)
    float sheen;                
     // Sheen effect for cloth-like materials (0-1)
    float sheen_tint;            // Tint sheen with base color (0-1)
    float clearcoat;             // Clearcoat layer strength (0-1)
    
    float clearcoat_roughness;   // Clearcoat roughness (0-1)
    float transmission;          // Glass/transparency (0-1)
    float transmission_roughness; // Roughness of transmission (0-1)
    float ior;                   // Index of refraction
    
    glm::vec3 transmission_color; // Transmission color/absorption
    float subsurface;            // Subsurface scattering strength (0-1)
    
    glm::vec3 subsurface_color;  // Subsurface scattering color
    float padding1;
    
    glm::vec3 subsurface_radius; // Subsurface scattering radius (RGB)
    float padding2;
    
    glm::vec3 emission_color;    // Emission color
    float emission_strength;     // Emission strength
    
    float alpha_threshold;       // Alpha shadow threshold (0-1)
    float has_alpha_map;         // Has alpha map flag
    int texture_id;              // Texture ID (-1 = no texture)
    float padding3;

    Material()
        : base_color(0.8f, 0.8f, 0.8f)
        , roughness(0.5f)
        , metallic(0.0f)
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

    // Constructor for common use case: color, roughness, metallic
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

    // Legacy constructor for backward compatibility
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
// Verify struct size is consistent with HLSL layout (must be 16 byte aligned per row)
static_assert(sizeof(Material) == 144, "Material size mismatch: C++ Material must match HLSL layout (144 bytes)");

