// ==================== Skybox / Environment Lighting Module ====================
// HDR 环境贴图采样和环境光照计算
// 支持等距柱状投影 (Equirectangular) HDR 环境贴图

#ifndef SKYBOX_HLSL
#define SKYBOX_HLSL

#include "common.hlsl"

// 前向声明
float3 GetProceduralSky(float3 direction);

// ==================== 环境贴图采样 ====================

// 将方向向量转换为等距柱状投影 UV 坐标
// direction: 归一化的世界空间方向向量
// 返回: UV 坐标 (u, v) 范围 [0, 1]
float2 DirectionToEquirectangularUV(float3 direction) {
    // 计算球坐标
    // phi: 水平角度 (-PI 到 PI)
    // theta: 垂直角度 (0 到 PI)
    float phi = atan2(direction.z, direction.x);    // 水平角 [-PI, PI]
    float theta = acos(clamp(direction.y, -1.0, 1.0)); // 垂直角 [0, PI]
    
    // 转换为 UV 坐标
    // u = phi / (2*PI) + 0.5, 范围 [0, 1]
    // v = theta / PI, 范围 [0, 1]
    float u = phi / (2.0 * PI) + 0.5;
    float v = theta / PI;
    
    return float2(u, v);
}

// 从等距柱状投影 UV 坐标转换回方向向量
// uv: UV 坐标 (u, v) 范围 [0, 1]
// 返回: 归一化的世界空间方向向量
float3 EquirectangularUVToDirection(float2 uv) {
    float phi = (uv.x - 0.5) * 2.0 * PI;    // 水平角 [-PI, PI]
    float theta = uv.y * PI;                 // 垂直角 [0, PI]
    
    // 球坐标转笛卡尔坐标
    float sinTheta = sin(theta);
    float cosTheta = cos(theta);
    float sinPhi = sin(phi);
    float cosPhi = cos(phi);
    
    return float3(
        sinTheta * cosPhi,  // x
        cosTheta,           // y (up)
        sinTheta * sinPhi   // z
    );
}

// 采样 HDR 环境贴图
// direction: 归一化的世界空间方向向量
// 返回: HDR 辐射度值
float3 SampleEnvironmentMap(float3 direction) {
    // 检查是否有环境贴图
    if (skybox_info.has_environment_map < 0.5) {
        // 没有环境贴图，返回程序化天空
        return GetProceduralSky(direction);
    }
    
    // 应用旋转（绕 Y 轴旋转）
    float rotation = skybox_info.environment_rotation;
    float cosR = cos(rotation);
    float sinR = sin(rotation);
    float3 rotatedDir = float3(
        direction.x * cosR - direction.z * sinR,
        direction.y,
        direction.x * sinR + direction.z * cosR
    );
    
    // 将方向转换为 UV 坐标
    float2 uv = DirectionToEquirectangularUV(normalize(rotatedDir));
    
    // 采样环境贴图
    float3 envColor = environment_map.SampleLevel(envSampler, uv, 0).rgb;
    
    // 应用强度
    envColor *= skybox_info.environment_intensity;
    
    return envColor;
}

// 带 LOD 的环境贴图采样（用于模糊反射）
// direction: 归一化的世界空间方向向量
// lod: mipmap 级别（0 = 最清晰，越大越模糊）
float3 SampleEnvironmentMapLOD(float3 direction, float lod) {
    if (skybox_info.has_environment_map < 0.5) {
        return GetProceduralSky(direction);
    }
    
    // 应用旋转（绕 Y 轴旋转）
    float rotation = skybox_info.environment_rotation;
    float cosR = cos(rotation);
    float sinR = sin(rotation);
    float3 rotatedDir = float3(
        direction.x * cosR - direction.z * sinR,
        direction.y,
        direction.x * sinR + direction.z * cosR
    );
    
    float2 uv = DirectionToEquirectangularUV(normalize(rotatedDir));
    float3 envColor = environment_map.SampleLevel(envSampler, uv, lod).rgb;
    envColor *= skybox_info.environment_intensity;
    
    return envColor;
}

// 程序化天空（作为后备或调试）
float3 GetProceduralSky(float3 direction) {
    float3 dir = normalize(direction);
    float t = 0.5 * (dir.y + 1.0);
    
    // 地平线颜色
    float3 horizonColor = skybox_info.horizon_color;
    // 天顶颜色
    float3 zenithColor = skybox_info.zenith_color;
    // 地面颜色
    float3 groundColor = skybox_info.ground_color;
    
    // 根据方向混合颜色
    if (dir.y >= 0.0) {
        // 天空部分：从地平线到天顶
        float skyT = pow(dir.y, 0.5); // 非线性过渡，天顶区域更广
        return lerp(horizonColor, zenithColor, skyT) * skybox_info.environment_intensity;
    } else {
        // 地面部分：从地平线到地面
        float groundT = pow(-dir.y, 0.5);
        return lerp(horizonColor, groundColor, groundT) * skybox_info.environment_intensity;
    }
}

// ==================== 环境光照计算 ====================

// 计算漫反射环境光照（粗糙的半球采样近似）
// normal: 表面法线
// 返回: 环境漫反射辐照度
float3 GetEnvironmentIrradiance(float3 normal) {
    // 简单近似：直接采样法线方向，带有一定的 LOD
    // 更精确的方法是预计算辐照度贴图或使用球谐函数
    float lod = 4.0; // 使用较高 LOD 获得模糊的漫反射
    return SampleEnvironmentMapLOD(normal, lod);
}

// 计算镜面反射环境光照
// reflectionDir: 反射方向
// roughness: 表面粗糙度
// 返回: 环境镜面辐射度
float3 GetEnvironmentReflection(float3 reflectionDir, float roughness) {
    // 根据粗糙度选择 LOD
    // 粗糙度越高，采样越模糊
    float maxLod = 7.0; // 假设环境贴图有 8 级 mipmap
    float lod = roughness * maxLod;
    return SampleEnvironmentMapLOD(reflectionDir, lod);
}

// ==================== 重要性采样辅助函数 ====================

// 生成余弦加权半球采样方向（用于漫反射 IBL）
// u1, u2: [0, 1] 范围的随机数
// normal: 表面法线
float3 CosineSampleHemisphere(float u1, float u2, float3 normal) {
    // 在局部坐标系生成余弦加权方向
    float r = sqrt(u1);
    float theta = 2.0 * PI * u2;
    
    float x = r * cos(theta);
    float y = r * sin(theta);
    float z = sqrt(1.0 - u1);
    
    // 构建切空间基
    float3 up = abs(normal.y) < 0.999 ? float3(0, 1, 0) : float3(1, 0, 0);
    float3 tangent = normalize(cross(up, normal));
    float3 bitangent = cross(normal, tangent);
    
    // 转换到世界空间
    return normalize(tangent * x + bitangent * y + normal * z);
}

// GGX 重要性采样（用于镜面 IBL）
// u1, u2: [0, 1] 范围的随机数
// normal: 表面法线
// roughness: 表面粗糙度
float3 ImportanceSampleGGX(float u1, float u2, float3 normal, float roughness) {
    float a = roughness * roughness;
    
    float phi = 2.0 * PI * u1;
    float cosTheta = sqrt((1.0 - u2) / (1.0 + (a * a - 1.0) * u2));
    float sinTheta = sqrt(1.0 - cosTheta * cosTheta);
    
    // 球坐标转笛卡尔坐标（切空间）
    float3 H;
    H.x = sinTheta * cos(phi);
    H.y = sinTheta * sin(phi);
    H.z = cosTheta;
    
    // 构建切空间基
    float3 up = abs(normal.y) < 0.999 ? float3(0, 1, 0) : float3(1, 0, 0);
    float3 tangent = normalize(cross(up, normal));
    float3 bitangent = cross(normal, tangent);
    
    // 转换到世界空间
    return normalize(tangent * H.x + bitangent * H.y + normal * H.z);
}

// ==================== 环境光照主函数 ====================

// 计算完整的环境光照贡献（IBL）
// hitPos: 击中点位置
// normal: 表面法线
// viewDir: 观察方向
// material: 材质信息
// seed: 随机种子
float3 ComputeEnvironmentLighting(float3 hitPos, float3 normal, float3 viewDir, Material material, inout uint seed) {
    float3 totalEnvLight = float3(0.0, 0.0, 0.0);
    
    // 1. 漫反射环境光
    float3 irradiance = GetEnvironmentIrradiance(normal);
    float3 diffuseColor = material.base_color * (1.0 - material.metallic);
    float3 diffuseEnv = diffuseColor * irradiance;
    
    // 2. 镜面反射环境光
    float3 reflectDir = reflect(-viewDir, normal);
    float3 prefilteredColor = GetEnvironmentReflection(reflectDir, material.roughness);
    
    // Fresnel 近似（Schlick）
    float NdotV = max(dot(normal, viewDir), 0.0);
    float3 F0 = lerp(float3(0.04, 0.04, 0.04), material.base_color, material.metallic);
    float3 F = F0 + (float3(1.0, 1.0, 1.0) - F0) * pow(1.0 - NdotV, 5.0);
    
    // 简化的环境 BRDF 近似
    float2 envBRDF = float2(1.0 - material.roughness, material.roughness);
    float3 specularEnv = prefilteredColor * (F * envBRDF.x + envBRDF.y);
    
    // 组合漫反射和镜面反射
    totalEnvLight = diffuseEnv * (1.0 - F) + specularEnv;
    
    return totalEnvLight;
}

// ==================== 太阳/方向光计算 ====================

// 计算来自环境贴图的"太阳"方向光（最亮区域）
// 注意：这是一个简化版本，完整实现需要预计算
float3 GetSunDirection() {
    // 返回配置的太阳方向
    return normalize(skybox_info.sun_direction);
}

float3 GetSunColor() {
    // 返回配置的太阳颜色
    return skybox_info.sun_color * skybox_info.sun_intensity;
}

// 计算太阳直接光照贡献
float3 ComputeSunLighting(float3 hitPos, float3 normal, float3 viewDir, Material material, inout uint seed) {
    if (skybox_info.sun_intensity < 0.001) {
        return float3(0.0, 0.0, 0.0);
    }
    
    float3 sunDir = GetSunDirection();
    float3 sunColor = GetSunColor();
    
    // 计算 NdotL
    float NdotL = max(dot(normal, sunDir), 0.0);
    if (NdotL <= 0.0) {
        return float3(0.0, 0.0, 0.0);
    }
    
    // 阴影检测（使用现有的阴影射线函数）
    // 这里简化为不检测阴影，因为太阳通常在场景外部
    // 实际实现中应该调用 TraceAlphaShadowRGB
    
    // 简单的 Lambertian 漫反射
    float3 diffuse = material.base_color * (1.0 - material.metallic) / PI;
    
    // 简单的镜面反射（Blinn-Phong 近似）
    float3 halfVec = normalize(sunDir + viewDir);
    float NdotH = max(dot(normal, halfVec), 0.0);
    float specPower = max(2.0 / (material.roughness * material.roughness) - 2.0, 1.0);
    float spec = pow(NdotH, specPower);
    float3 F0 = lerp(float3(0.04, 0.04, 0.04), material.base_color, material.metallic);
    float3 specular = F0 * spec;
    
    return (diffuse + specular) * sunColor * NdotL;
}

#endif // SKYBOX_HLSL
