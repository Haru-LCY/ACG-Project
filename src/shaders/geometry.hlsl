// ==================== Geometry Utilities ====================
// 几何计算工具函数：法线计算、UV坐标计算等
//
// ==================== 当前实现说明 ====================
// 
// 法线计算逻辑：
// 1. 优先使用OBJ文件中定义的顶点法线（vn）
// 2. 如果法线为 (0,0,0)（占位符），则计算面法线（使用三角形顶点叉积）
// 3. 不再根据 entity_id 判断几何类型
//
// UV坐标计算逻辑：
// 1. 优先使用OBJ文件中定义的UV坐标（vt）
// 2. 如果UV为 (-1,-1)（占位符），则计算UV坐标
// 3. 不再根据 entity_id 判断几何类型
//
// ==================== 实现细节 ====================
// - 面法线通过三角形三个顶点的叉积计算：normalize(cross(v1-v0, v2-v0))
// - UV计算：如果没有提供UV，使用简单的平面投影或球面投影
// - 所有计算都在物体空间进行，然后转换到世界空间

#ifndef GEOMETRY_HLSL
#define GEOMETRY_HLSL

#include "common.hlsl"

// ==================== 法线计算 ====================

// 计算三角形的面法线（使用顶点叉积）
// v0, v1, v2: 三角形的三个顶点（物体空间）
// 返回：归一化的面法线（物体空间）
float3 ComputeFaceNormal(float3 v0, float3 v1, float3 v2) {
    float3 edge1 = v1 - v0;
    float3 edge2 = v2 - v0;
    float3 normal = cross(edge1, edge2);
    float len = length(normal);
    if (len < 1e-6) {
        // 退化三角形，返回默认法线
        return float3(0, 1, 0);
    }
    return normalize(normal);
}

// 从全局缓冲区获取顶点法线
// entity_id: 实体ID
// primitive_id: 图元ID（三角形索引）
// barycentrics: 重心坐标
// 返回：归一化的法线（物体空间）
float3 GetVertexNormal(uint entity_id, uint primitive_id, float2 barycentrics) {
    // 获取实体偏移
    EntityOffset offset = entity_offsets[entity_id];
    
    // 获取三角形的三个顶点索引
    uint idx0 = global_indices[offset.index_offset + primitive_id * 3 + 0];
    uint idx1 = global_indices[offset.index_offset + primitive_id * 3 + 1];
    uint idx2 = global_indices[offset.index_offset + primitive_id * 3 + 2];
    
    // 获取三个顶点的法线
    float3 n0 = global_normals[idx0];
    float3 n1 = global_normals[idx1];
    float3 n2 = global_normals[idx2];
    
    // 使用重心坐标插值
    float u = barycentrics.x;
    float v = barycentrics.y;
    float w = 1.0 - u - v;
    
    float3 interpolated_normal = w * n0 + u * n1 + v * n2;
    
    // 检查是否为占位符 (0,0,0)
    if (length(interpolated_normal) < 0.001) {
        // 计算面法线
        float3 v0 = global_vertices[idx0];
        float3 v1 = global_vertices[idx1];
        float3 v2 = global_vertices[idx2];
        return ComputeFaceNormal(v0, v1, v2);
    }
    
    return normalize(interpolated_normal);
}

// ==================== UV坐标计算 ====================

// 计算简单的UV坐标（基于顶点位置）
// objectPos: 物体空间位置
// normal: 物体空间法线
// 返回：UV坐标
float2 ComputeSimpleUV(float3 objectPos, float3 normal) {
    // 简单的平面投影：根据法线的主要方向选择投影面
    float3 absNormal = abs(normal);
    float maxComp = max(max(absNormal.x, absNormal.y), absNormal.z);
    
    if (absNormal.x == maxComp) {
        // X面投影
        return float2(objectPos.z * 0.5 + 0.5, objectPos.y * 0.5 + 0.5);
    } else if (absNormal.y == maxComp) {
        // Y面投影
        return float2(objectPos.x * 0.5 + 0.5, objectPos.z * 0.5 + 0.5);
    } else {
        // Z面投影
        return float2(objectPos.x * 0.5 + 0.5, objectPos.y * 0.5 + 0.5);
    }
}

// 从全局缓冲区获取UV坐标
// entity_id: 实体ID
// primitive_id: 图元ID（三角形索引）
// barycentrics: 重心坐标
// objectPos: 物体空间位置（用于计算UV）
// normal: 物体空间法线（用于计算UV）
// 返回：UV坐标
float2 GetVertexUV(uint entity_id, uint primitive_id, float2 barycentrics, float3 objectPos, float3 normal) {
    // 获取实体偏移
    EntityOffset offset = entity_offsets[entity_id];
    
    // 获取三角形的三个顶点索引
    uint idx0 = global_indices[offset.index_offset + primitive_id * 3 + 0];
    uint idx1 = global_indices[offset.index_offset + primitive_id * 3 + 1];
    uint idx2 = global_indices[offset.index_offset + primitive_id * 3 + 2];
    
    // 获取三个顶点的UV
    float2 uv0 = global_texcoords[idx0];
    float2 uv1 = global_texcoords[idx1];
    float2 uv2 = global_texcoords[idx2];
    
    // 使用重心坐标插值
    float u = barycentrics.x;
    float v = barycentrics.y;
    float w = 1.0 - u - v;
    
    float2 interpolated_uv = w * uv0 + u * uv1 + v * uv2;
    
    // 检查是否为占位符 (-1,-1)
    if (interpolated_uv.x < -0.5 && interpolated_uv.y < -0.5) {
        // 计算UV
        return ComputeSimpleUV(objectPos, normal);
    }
    
    return interpolated_uv;
}

#endif // GEOMETRY_HLSL
