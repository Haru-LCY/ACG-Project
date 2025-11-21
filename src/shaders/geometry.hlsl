// ==================== Geometry Utilities ====================
// 几何计算工具函数：法线计算、UV坐标计算等

#ifndef GEOMETRY_HLSL
#define GEOMETRY_HLSL

#include "common.hlsl"

// ==================== 法线计算 ====================

// 计算立方体的面法线（用于墙壁和玻璃立方体）
float3 ComputeBoxFaceNormal(float3 objectPos) {
    float3 absPos = abs(objectPos);
    float maxComp = max(max(absPos.x, absPos.y), absPos.z);
    
    // 找到最大分量对应的面，使用该面的法线
    if (abs(absPos.x - maxComp) < 0.01) {
        return float3(sign(objectPos.x), 0, 0);
    } else if (abs(absPos.y - maxComp) < 0.01) {
        return float3(0, sign(objectPos.y), 0);
    } else if (abs(absPos.z - maxComp) < 0.01) {
        return float3(0, 0, sign(objectPos.z));
    } else {
        return normalize(objectPos);
    }
}

// 计算八面体的平滑法线（归一化位置向量）
float3 ComputeOctahedronNormal(float3 objectPos) {
    return normalize(objectPos);
}

// 根据实体ID计算几何法线
// Entity 0-4: 房间墙壁（立方体，需要平面法线）
// Entity 5-6: 八面体（需要平滑法线）
// Entity 7: 玻璃立方体（需要平面法线）
float3 ComputeGeometryNormal(uint entity_id, float3 objectPos) {
    // 对墙壁(0-4)和玻璃立方体(7)使用面法线
    if (entity_id <= 4 || entity_id == 7) {
        return ComputeBoxFaceNormal(objectPos);
    } else {
        // 八面体(5-6)：使用平滑的归一化法线（金属质感）
        return ComputeOctahedronNormal(objectPos);
    }
}

// ==================== UV坐标计算 ====================

// 计算立方体的UV坐标（平面映射）
float2 ComputeBoxUV(float3 objectPos, float3 worldNormal) {
    float u, v;
    float3 absNormal = abs(worldNormal);
    
    if (absNormal.x > absNormal.y && absNormal.x > absNormal.z) {
        // X面
        if (worldNormal.x > 0) {
            u = (objectPos.z + 1.0) / 2.0;
            v = 1.0 - (objectPos.y + 1.0) / 2.0;
        } else {
            u = (1.0 - objectPos.z) / 2.0;
            v = 1.0 - (objectPos.y + 1.0) / 2.0;
        }
    } else if (absNormal.y > absNormal.z) {
        // Y面
        if (worldNormal.y > 0) {
            u = (objectPos.x + 1.0) / 2.0;
            v = 1.0 - (1.0 - objectPos.z) / 2.0;
        } else {
            u = (objectPos.x + 1.0) / 2.0;
            v = 1.0 - (objectPos.z + 1.0) / 2.0;
        }
    } else {
        // Z面
        if (worldNormal.z > 0) {
            u = (objectPos.x + 1.0) / 2.0;
            v = 1.0 - (objectPos.y + 1.0) / 2.0;
        } else {
            u = (1.0 - objectPos.x) / 2.0;
            v = 1.0 - (objectPos.y + 1.0) / 2.0;
        }
    }
    
    float scale = 1.0;
    u *= scale;
    v *= scale;
    
    return float2(u, v);
}

// 计算八面体的UV坐标（球面映射）
float2 ComputeOctahedronUV(float3 objectPos) {
    float3 normalizedPos = normalize(objectPos);
    float u = 0.5 + atan2(normalizedPos.z, normalizedPos.x) / (2.0 * PI);
    float v = 0.5 - asin(normalizedPos.y) / PI;
    return float2(u, v);
}

// 根据实体ID计算UV坐标
float2 ComputeGeometryUV(uint entity_id, float3 objectPos, float3 worldNormal) {
    // 立方体(0-4, 7)：使用平面UV映射
    if (entity_id <= 4 || entity_id == 7) {
        return ComputeBoxUV(objectPos, worldNormal);
    } else {
        // 八面体(5-6)：使用球面映射
        return ComputeOctahedronUV(objectPos);
    }
}

#endif // GEOMETRY_HLSL

