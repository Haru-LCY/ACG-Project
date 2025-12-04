// ==================== Normal Mapping ====================
// Normal Map 法线贴图实现
// 
// Normal mapping 通过纹理存储表面细节法线，在不增加几何复杂度的情况下
// 显著提升视觉细节。法线贴图通常存储在切线空间（Tangent Space）中。

#ifndef NORMAL_MAP_HLSL
#define NORMAL_MAP_HLSL

#include "common.hlsl"

// ==================== Height Map / Parallax Mapping ====================
// Height Map 高度贴图实现（基础视差贴图）
// 
// Parallax mapping 通过偏移 UV 坐标来模拟表面深度，产生视差效果。
// 高度信息通常存储在法线贴图的 alpha 通道或 R 通道中。

// 基础视差映射：根据高度值偏移 UV 坐标
// normalMap: 法线贴图纹理（高度信息存储在 alpha 通道或 R 通道）
// uv: 原始纹理坐标
// viewDir: 视线方向（世界空间）
// T: 切线（世界空间）
// B: 副切线（世界空间）
// N: 法线（世界空间）
// heightScale: 高度缩放系数（控制视差强度，通常 0.01-0.1）
// 返回: 偏移后的 UV 坐标
float2 ParallaxMapping(Texture2D normalMap, float2 uv, float3 viewDir, float3 T, float3 B, float3 N, float heightScale) {
    // 将视线方向转换到切线空间
    float3x3 TBN = float3x3(
        normalize(T),  // 切线
        normalize(B),  // 副切线
        normalize(N)   // 法线
    );
    float3 viewDirTS = mul(TBN, viewDir);
    
    // 采样高度值
    // 注意：标准的法线贴图（RGB存储法线方向）通常不包含高度信息
    // 要使用 height map，需要：
    // 1. 使用单独的高度贴图纹理（灰度图，白色=高，黑色=低）
    // 2. 或者使用包含高度信息的法线贴图（高度存储在 alpha 通道）
    float4 normalMapSample = normalMap.SampleLevel(texSampler, uv, 0);
    
    // 尝试从 alpha 通道读取高度（如果法线贴图包含高度信息）
    float height = normalMapSample.a;
    
    // 如果 alpha 通道接近 1.0（标准法线贴图的默认值，表示完全不透明）
    // 或者接近 0（没有 alpha 通道），则使用 R 通道作为高度值
    // 注意：如果法线贴图没有高度信息，R 通道存储的是法线的 X 分量，不适合作为高度
    // 这种情况下 height map 效果会很弱或无效
    if (height > 0.95 || height < 0.05) {
        // 使用 R 通道作为高度值（假设是灰度高度图，或法线贴图的 R 通道）
        height = normalMapSample.r;
    }
    
    // 确保高度值在合理范围内（0-1）
    // 高度值越大（越白），表面越突出
    height = saturate(height);
    
    // 防止除零：如果 viewDirTS.z 太小，限制偏移量
    // viewDirTS.z 是视线方向在法线方向的分量
    float parallaxDepth = height * heightScale;
    
    // 计算视差偏移
    // viewDirTS.xy / viewDirTS.z 将视线方向投影到切线平面
    // 乘以高度值得到偏移量
    // 添加小的 epsilon 防止除零
    float2 parallaxOffset = viewDirTS.xy / max(viewDirTS.z, 0.001) * parallaxDepth;
    
    // 返回偏移后的 UV（减去是因为高度值越大，应该向前偏移）
    return uv - parallaxOffset;
}

// 从法线贴图采样并转换到世界空间
// normalMap: 法线贴图纹理
// uv: 纹理坐标
// N: 几何法线（世界空间）
// T: 切线（世界空间）
// B: 副切线（世界空间）
// 返回: 扰动后的世界空间法线
float3 SampleNormalMap(Texture2D normalMap, float2 uv, float3 N, float3 T, float3 B) {
    // 从法线贴图采样 (RGB 值在 [0,1] 范围内)
    // 使用 SampleLevel 因为在光线追踪 shader 中不支持隐式导数
    float3 normalMapSample = normalMap.SampleLevel(texSampler, uv, 0).rgb;
    
    // 将 [0,1] 映射到 [-1,1]
    float3 tangentNormal = normalMapSample * 2.0 - 1.0;
    
    // 构建 TBN 矩阵（切线空间到世界空间的变换矩阵）
    // TBN = [T, B, N] (列向量)
    float3x3 TBN = float3x3(
        normalize(T),  // 切线
        normalize(B),  // 副切线
        normalize(N)   // 法线
    );
    
    // 将切线空间法线转换到世界空间
    float3 worldNormal = mul(tangentNormal, TBN);
    
    return normalize(worldNormal);
}

// 从法线贴图采样（简化版本 - 使用自动计算的切线）
// normalMap: 法线贴图纹理
// uv: 纹理坐标
// worldPos: 世界空间位置
// N: 几何法线（世界空间）
// 返回: 扰动后的世界空间法线
float3 SampleNormalMapSimple(Texture2D normalMap, float2 uv, float3 worldPos, float3 N) {
    // 从法线贴图采样（使用 SampleLevel 因为在光线追踪 shader 中不支持隐式导数）
    float3 normalMapSample = normalMap.SampleLevel(texSampler, uv, 0).rgb;
    float3 tangentNormal = normalMapSample * 2.0 - 1.0;
    
    // 使用屏幕空间导数自动计算切线和副切线
    // 注意：这种方法在光线追踪中不可用，因为没有屏幕空间导数
    // 我们需要手动构建 TBN 矩阵
    
    // 简化实现：假设切线沿 U 方向，副切线沿 V 方向
    float3 T = normalize(cross(N, float3(0, 1, 0)));
    if (length(T) < 0.001) {
        T = normalize(cross(N, float3(1, 0, 0)));
    }
    float3 B = normalize(cross(N, T));
    
    // 构建 TBN 矩阵
    float3x3 TBN = float3x3(T, B, N);
    
    // 转换到世界空间
    float3 worldNormal = mul(tangentNormal, TBN);
    
    return normalize(worldNormal);
}

// 从顶点数据计算切线和副切线（用于光线追踪）
// p0, p1, p2: 三角形顶点位置（世界空间）
// uv0, uv1, uv2: 三角形顶点的 UV 坐标
// N: 几何法线（世界空间）
// outT: 输出切线
// outB: 输出副切线
void ComputeTangentBasis(float3 p0, float3 p1, float3 p2,
                         float2 uv0, float2 uv1, float2 uv2,
                         float3 N,
                         out float3 outT, out float3 outB) {
    // 计算边和 UV 增量
    float3 edge1 = p1 - p0;
    float3 edge2 = p2 - p0;
    float2 deltaUV1 = uv1 - uv0;
    float2 deltaUV2 = uv2 - uv0;
    
    // 计算切线和副切线
    float f = 1.0 / (deltaUV1.x * deltaUV2.y - deltaUV2.x * deltaUV1.y);
    
    outT = f * (deltaUV2.y * edge1 - deltaUV1.y * edge2);
    outB = f * (-deltaUV2.x * edge1 + deltaUV1.x * edge2);
    
    // 正交化（Gram-Schmidt 过程）
    outT = normalize(outT - N * dot(N, outT));
    outB = normalize(outB - N * dot(N, outB) - outT * dot(outT, outB));
}

// 从法线贴图采样（完整版本 - 使用三角形顶点数据）
// normalMap: 法线贴图纹理
// uv: 插值后的 UV 坐标
// p0, p1, p2: 三角形顶点位置（世界空间）
// uv0, uv1, uv2: 三角形顶点的 UV 坐标
// N: 几何法线（世界空间）
// 返回: 扰动后的世界空间法线
float3 SampleNormalMapFull(Texture2D normalMap, float2 uv,
                           float3 p0, float3 p1, float3 p2,
                           float2 uv0, float2 uv1, float2 uv2,
                           float3 N) {
    // 从法线贴图采样（使用 SampleLevel 因为在光线追踪 shader 中不支持隐式导数）
    float3 normalMapSample = normalMap.SampleLevel(texSampler, uv, 0).rgb;
    float3 tangentNormal = normalMapSample * 2.0 - 1.0;
    
    // 计算切线和副切线
    float3 T, B;
    ComputeTangentBasis(p0, p1, p2, uv0, uv1, uv2, N, T, B);
    
    // 构建 TBN 矩阵
    float3x3 TBN = float3x3(T, B, N);
    
    // 转换到世界空间
    float3 worldNormal = mul(tangentNormal, TBN);
    
    return normalize(worldNormal);
}

#endif // NORMAL_MAP_HLSL
