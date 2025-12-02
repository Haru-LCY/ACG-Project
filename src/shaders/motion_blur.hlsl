// ==================== Motion Blur ====================
// 运动模糊效果实现
// 通过在时间域上采样来模拟物体运动或相机运动产生的模糊效果

#ifndef MOTION_BLUR_HLSL
#define MOTION_BLUR_HLSL

#include "common.hlsl"
#include "rng.hlsl"

// ==================== Motion Blur 参数 ====================

// Motion Blur 模式
#define MOTION_BLUR_MODE_OFF        0   // 关闭运动模糊
#define MOTION_BLUR_MODE_CAMERA     1   // 相机运动模糊（模拟快门时间内的相机移动）
#define MOTION_BLUR_MODE_OBJECT     2   // 物体运动模糊（需要物体速度信息）
#define MOTION_BLUR_MODE_RADIAL     3   // 径向模糊（从中心向外发散）
#define MOTION_BLUR_MODE_DIRECTIONAL 4  // 方向性模糊（沿指定方向）

// Motion Blur 配置结构体（如需要可以添加到常量缓冲区）
struct MotionBlurConfig {
    int mode;               // Motion blur 模式
    float shutter_time;     // 快门时间（0.0 - 1.0，1.0表示整个帧时间）
    float intensity;        // 模糊强度
    float2 direction;       // 方向性模糊的方向（归一化）
    float2 center;          // 径向模糊的中心点（屏幕UV坐标）
    float radial_scale;     // 径向模糊的缩放系数
};

// ==================== 时间采样函数 ====================

// 生成随机时间采样点（用于时间域抗锯齿/运动模糊）
// 返回值范围 [0, 1]，表示当前帧内的时间点
float SampleTime(inout uint seed) {
    seed = PCGHash(seed);
    return Rand01(seed);
}

// 生成分层时间采样点（更均匀的分布）
// sample_index: 当前采样索引
// total_samples: 总采样数
// seed: 随机种子（用于抖动）
float SampleTimeStratified(int sample_index, int total_samples, inout uint seed) {
    float stratum_size = 1.0 / float(total_samples);
    float stratum_start = float(sample_index) * stratum_size;
    seed = PCGHash(seed);
    float jitter = Rand01(seed) * stratum_size;
    return stratum_start + jitter;
}

// ==================== 相机运动模糊 ====================

// 计算相机运动模糊偏移
// 基于相机前一帧和当前帧的变换矩阵，在时间t处插值
// prev_camera_to_world: 前一帧的相机到世界变换矩阵
// curr_camera_to_world: 当前帧的相机到世界变换矩阵
// t: 时间参数 [0, 1]，0表示帧开始，1表示帧结束
float4x4 InterpolateCameraTransform(float4x4 prev_camera_to_world, float4x4 curr_camera_to_world, float t) {
    // 简单的线性插值（对于小幅度运动足够精确）
    // 对于大幅度旋转，应该使用四元数插值
    return prev_camera_to_world * (1.0 - t) + curr_camera_to_world * t;
}

// ==================== 径向运动模糊 ====================

// 计算径向模糊的光线方向偏移
// uv: 当前像素的UV坐标 [0, 1]
// center: 模糊中心（UV坐标）
// intensity: 模糊强度
// t: 时间参数 [0, 1]
float2 ComputeRadialBlurOffset(float2 uv, float2 center, float intensity, float t) {
    float2 dir = uv - center;
    float dist = length(dir);
    if (dist < 0.001) return float2(0, 0);
    
    float2 normalized_dir = dir / dist;
    // 径向模糊：越远离中心，模糊越强
    float blur_amount = dist * intensity * (t - 0.5) * 2.0;
    return normalized_dir * blur_amount;
}

// ==================== 方向性运动模糊 ====================

// 计算方向性模糊的UV偏移
// direction: 模糊方向（归一化）
// intensity: 模糊强度
// t: 时间参数 [0, 1]
float2 ComputeDirectionalBlurOffset(float2 direction, float intensity, float t) {
    // 将时间 [0, 1] 映射到 [-0.5, 0.5]
    float time_offset = t - 0.5;
    return direction * intensity * time_offset;
}

// ==================== 物体运动模糊辅助函数 ====================

// 最大支持的实体数量（与 C++ 端保持一致）
#define MAX_ENTITIES 256

// 获取实体的速度向量
// 添加边界检查以避免越界访问导致的崩溃
float3 GetEntityVelocity(uint entity_id) {
    // 边界检查：如果 entity_id 超出合理范围，返回零速度
    if (entity_id >= MAX_ENTITIES) {
        return float3(0.0, 0.0, 0.0);
    }
    return entity_velocities[entity_id].xyz;
}

// 计算物体运动模糊的击中点偏移
// hit_pos: 原始击中点
// entity_id: 实体ID
// t: 时间参数 [0, 1]，0.5表示当前帧中心时刻
// 返回：时间t时刻的估计击中点位置
float3 ComputeObjectMotionBlurPosition(float3 hit_pos, uint entity_id, float t) {
    float3 velocity = GetEntityVelocity(entity_id);
    // 将时间映射到 [-0.5, 0.5]，表示快门时间内的偏移
    float time_offset = t - 0.5;
    return hit_pos + velocity * time_offset;
}

// 计算运动向量（用于后处理运动模糊）
// 需要物体的前一帧位置和当前帧位置
// prev_world_pos: 物体在前一帧的世界位置
// curr_world_pos: 物体在当前帧的世界位置
// view_proj: 当前帧的视图投影矩阵
// prev_view_proj: 前一帧的视图投影矩阵
float2 ComputeMotionVector(
    float3 prev_world_pos, 
    float3 curr_world_pos,
    float4x4 view_proj,
    float4x4 prev_view_proj
) {
    // 将当前位置投影到屏幕空间
    float4 curr_clip = mul(view_proj, float4(curr_world_pos, 1.0));
    float2 curr_ndc = curr_clip.xy / curr_clip.w;
    
    // 将前一帧位置投影到屏幕空间
    float4 prev_clip = mul(prev_view_proj, float4(prev_world_pos, 1.0));
    float2 prev_ndc = prev_clip.xy / prev_clip.w;
    
    // 运动向量 = 当前位置 - 前一帧位置
    return (curr_ndc - prev_ndc) * 0.5; // 转换到 [0, 1] UV空间
}

// ==================== 主要Motion Blur函数 ====================

// 应用运动模糊到光线生成
// 这个函数修改光线的起点和方向，以模拟运动模糊
// base_origin: 基础光线起点
// base_dir: 基础光线方向
// uv: 当前像素UV坐标
// shutter_time: 快门时间（相对于帧时间的比例）
// intensity: 模糊强度
// mode: 运动模糊模式
// seed: 随机种子
void ApplyMotionBlur(
    inout float3 ray_origin,
    inout float3 ray_dir,
    float2 uv,
    float shutter_time,
    float intensity,
    int mode,
    inout uint seed
) {
    if (mode == MOTION_BLUR_MODE_OFF || intensity < 0.001) {
        return; // 不应用任何模糊
    }
    
    // 采样时间点
    float t = SampleTime(seed) * shutter_time;
    
    switch (mode) {
        case MOTION_BLUR_MODE_RADIAL: {
            // 径向模糊：从屏幕中心向外发散
            float2 center = float2(0.5, 0.5); // 屏幕中心
            float2 offset = ComputeRadialBlurOffset(uv, center, intensity, t);
            // 将UV偏移转换为光线方向的偏移
            ray_dir = normalize(ray_dir + float3(offset.x, -offset.y, 0.0) * 0.1);
            break;
        }
        
        case MOTION_BLUR_MODE_DIRECTIONAL: {
            // 方向性模糊：使用camera_info中的方向
            float2 direction = camera_info.motion_blur_direction;
            float2 offset = ComputeDirectionalBlurOffset(direction, intensity, t);
            ray_dir = normalize(ray_dir + float3(offset.x, -offset.y, 0.0) * 0.1);
            break;
        }
        
        case MOTION_BLUR_MODE_CAMERA: {
            // 相机运动模糊：模拟快门时间内的相机移动
            // 这里使用简单的随机抖动来近似相机运动
            float2 random_offset;
            random_offset.x = (Rand01(seed) - 0.5) * intensity * 0.02;
            random_offset.y = (Rand01(seed) - 0.5) * intensity * 0.02;
            ray_dir = normalize(ray_dir + float3(random_offset.x, random_offset.y, 0.0));
            break;
        }
        
        case MOTION_BLUR_MODE_OBJECT:
        default:
            // 物体运动模糊需要额外的速度缓冲区信息
            // 暂时使用简单的抖动
            break;
    }
}

// ==================== 光线时间抖动 ====================

// 为光线添加时间信息（用于运动物体的模糊）
// 这个函数返回一个时间值，可以用于在加速结构中查询运动物体的位置
float GetRayTime(int sample_index, int total_samples, inout uint seed) {
    // 使用分层采样获得更均匀的时间分布
    return SampleTimeStratified(sample_index, total_samples, seed);
}

// ==================== 快门形状函数 ====================

// 不同的快门形状会产生不同的模糊效果
// 返回权重，用于加权平均

// 盒形快门（均匀分布）
float BoxShutter(float t) {
    return 1.0;
}

// 三角形快门（中间权重最大）
float TriangleShutter(float t) {
    // t 在 [0, 1] 范围内
    return 1.0 - abs(t * 2.0 - 1.0);
}

// 高斯快门（更平滑的过渡）
float GaussianShutter(float t) {
    float x = t * 2.0 - 1.0; // 映射到 [-1, 1]
    return exp(-x * x * 2.0);
}

// ==================== 简化的Motion Blur光线生成 ====================

// 生成带运动模糊的相机光线
// 这是一个简化版本，通过在光线方向上添加随机偏移来模拟运动模糊
void GenerateCameraRayWithMotionBlur(
    uint2 dispatch_index,
    float2 jitter,
    float motion_blur_intensity,
    float2 motion_blur_direction,  // 运动方向（屏幕空间）
    inout uint seed,
    out float3 ray_origin,
    out float3 ray_dir
) {
    // 首先计算基础像素坐标
    float2 pixel_center = (float2)dispatch_index + float2(0.5 + jitter.x, 0.5 + jitter.y);
    
    // 采样时间
    float t = SampleTime(seed);
    
    // 根据运动模糊强度和方向添加像素偏移
    float2 motion_offset = motion_blur_direction * motion_blur_intensity * (t - 0.5) * 2.0;
    pixel_center += motion_offset;
    
    // 生成光线
    float2 dims = float2(DispatchRaysDimensions().xy);
    float2 uv = pixel_center / dims;
    uv.y = 1.0 - uv.y;
    float2 d = uv * 2.0 - 1.0;
    
    float4 origin4 = mul(camera_info.camera_to_world, float4(0, 0, 0, 1));
    float4 target = mul(camera_info.screen_to_camera, float4(d, 1, 1));
    float4 direction4 = mul(camera_info.camera_to_world, float4(target.xyz, 0));
    
    ray_origin = origin4.xyz;
    ray_dir = normalize(direction4.xyz);
}

// ==================== 旋转运动模糊 ====================

// 计算旋转模糊的偏移
// center: 旋转中心（UV坐标）
// angular_velocity: 角速度（弧度/帧）
// t: 时间参数
float2 ComputeRotationalBlurOffset(float2 uv, float2 center, float angular_velocity, float t) {
    float2 relative = uv - center;
    float angle = angular_velocity * (t - 0.5) * 2.0;
    
    // 2D旋转
    float cos_a = cos(angle);
    float sin_a = sin(angle);
    float2 rotated;
    rotated.x = relative.x * cos_a - relative.y * sin_a;
    rotated.y = relative.x * sin_a + relative.y * cos_a;
    
    return rotated + center - uv;
}

// ==================== 缩放运动模糊 ====================

// 计算缩放模糊的偏移（dolly zoom效果）
// center: 缩放中心（UV坐标）
// scale_factor: 缩放系数（>1 放大, <1 缩小）
// t: 时间参数
float2 ComputeZoomBlurOffset(float2 uv, float2 center, float scale_factor, float t) {
    float2 relative = uv - center;
    
    // 插值缩放：从1.0到scale_factor
    float current_scale = lerp(1.0, scale_factor, t - 0.5);
    float2 scaled = relative * current_scale;
    
    return scaled + center - uv;
}

#endif // MOTION_BLUR_HLSL
