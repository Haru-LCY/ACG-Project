// ==================== Main Shader File ====================
// 主着色器文件，包含所有模块并实现入口点

// 包含所有模块
#include "common.hlsl"
#include "rng.hlsl"
#include "msaa.hlsl"
#include "bsdf.hlsl"
#include "lighting.hlsl"
#include "raytracing.hlsl"
#include "geometry.hlsl"
#include "motion_blur.hlsl"
#include "normal_map.hlsl"
#include "raygen.hlsl"

[shader("raygeneration")] void RayGenMain() {
    uint2 dispatchIndex = DispatchRaysIndex().xy;
    int prev_samples = accumulated_samples[dispatchIndex];
    uint seed = (uint)dispatchIndex.x * 1973u + (uint)dispatchIndex.y * 9277u + (uint)prev_samples * 26699u;
    seed = PCGHash(seed);
    seed = PCGHash(seed);

    // 获取 MSAA 模式和采样数
    int msaa_mode = camera_info.msaa_mode;
    int msaa_sample_count = GetMSAASampleCount(msaa_mode);
    
    // 计算实际采样数：MSAA 采样数 * 用户设置的 SPP
    int user_spp = max(1, camera_info.samples_per_pixel);
    int total_spp = (msaa_mode == MSAA_MODE_OFF || msaa_mode == MSAA_MODE_RANDOM) 
                    ? user_spp 
                    : msaa_sample_count * max(1, user_spp / msaa_sample_count);
    
    float3 radianceSum = float3(0,0,0);
    RayPayload lastPayload; // keep last payload for debug

    // --- Deterministic pick ray for stable entity ID (no jitter, no DOF)
    RayPayload pickPayload;
    pickPayload.hit = false;
    pickPayload.material_idx = 0;    
    {
        float3 pickOrigin, pickDir;
        GeneratePickRay(dispatchIndex, pickOrigin, pickDir);

        RayDesc pickRay;
        pickRay.Origin = pickOrigin;
        pickRay.Direction = pickDir;
        pickRay.TMin = 0.001;
        pickRay.TMax = 10000.0;
        TraceRay(as, RAY_FLAG_NONE, 0xFF, 0, 1, 0, pickRay, pickPayload);
        // Write depth (distance) into the depth buffer (0.0 if no hit)
        float dval = 0.0;
        if (pickPayload.hit) {
            dval = length(pickPayload.hit_pos - pickOrigin);
        }
        depth_output[dispatchIndex] = dval;
    }

    // 主采样循环
    for (int s = 0; s < total_spp; ++s) {
        // 根据 MSAA 模式获取子像素偏移
        float2 jitter;
        if (msaa_mode == MSAA_MODE_RANDOM) {
            // 随机抖动模式（原有行为）
            seed = PCGHash(seed);
            float jitter_x = Rand01(seed) - 0.5;
            float jitter_y = Rand01(seed) - 0.5;
            jitter = float2(jitter_x, jitter_y);
        } else if (msaa_mode == MSAA_MODE_OFF) {
            // 无 MSAA，单采样时使用随机抖动
            if (total_spp > 1) {
                seed = PCGHash(seed);
                float jitter_x = Rand01(seed) - 0.5;
                float jitter_y = Rand01(seed) - 0.5;
                jitter = float2(jitter_x, jitter_y);
            } else {
                jitter = float2(0.0, 0.0);
            }
        } else {
            // 标准 MSAA 模式 (2x, 4x, 8x)
            // 使用时间累积 MSAA：结合固定模式和帧间偏移
            jitter = GetTemporalMSAASampleOffset(
                msaa_mode, 
                s % msaa_sample_count, 
                camera_info.accumulated_frames + s / msaa_sample_count,
                seed
            );
        }

        // 生成带景深效果的相机光线
        float3 rayOrigin, rayDir;
        GenerateCameraRayWithDOF(dispatchIndex, jitter, seed, rayOrigin, rayDir);
        
        // 应用相机/径向/方向运动模糊效果（非物体模糊）
        if (camera_info.motion_blur_mode > 0 && camera_info.motion_blur_mode != MOTION_BLUR_MODE_OBJECT && 
            camera_info.motion_blur_intensity > 0.001) {
            float2 uv = (float2(dispatchIndex) + float2(0.5, 0.5)) / float2(DispatchRaysDimensions().xy);
            ApplyMotionBlur(
                rayOrigin, 
                rayDir, 
                uv, 
                1.0,  // shutter_time = 1.0 (full frame)
                camera_info.motion_blur_intensity, 
                camera_info.motion_blur_mode, 
                seed
            );
        }
        
        // 物体运动模糊的屏幕空间模拟：
        // 对于每个采样，我们随机选择一个时间点，然后在追踪路径时
        // 会根据该时间点来偏移有速度物体的光照计算位置
        float3 radiance;
        if (camera_info.motion_blur_mode == MOTION_BLUR_MODE_OBJECT && 
            camera_info.motion_blur_intensity > 0.001) {
            // 物体运动模糊：使用多次短程追踪来模拟
            radiance = TracePathObjectMotionBlur(rayOrigin, rayDir, seed);
        } else {
            // 执行标准路径追踪
            radiance = TracePath(rayOrigin, rayDir, seed);
        }
        
        // 关键修复：限制单个采样radiance的最大值，防止异常采样导致亮点
        // 即使throughput和pointLightContrib都有保护，某些极端角度组合仍可能产生异常值
        const float MAX_SAMPLE_RADIANCE = 1000.0; // 大幅降低单个采样的最大radiance值，更严格地防止异常亮点
        float maxRadiance = max(max(radiance.r, radiance.g), radiance.b);
        if (maxRadiance > MAX_SAMPLE_RADIANCE) {
            // 如果radiance过大，进行裁剪（避免异常亮点污染累积结果）
            float scale = MAX_SAMPLE_RADIANCE / maxRadiance;
            radiance *= scale;
        }
        
        // accumulate this sample
        radianceSum += radiance;
        lastPayload = pickPayload;
    }
    
    // ================== 最终输出处理 (Tone Mapping) ==================
    
    // 累积颜色
    float4 prev_color = accumulated_color[dispatchIndex];
    // 注意：Radiance 可能非常大 (HDR)，需要累积 HDR 值
    float4 new_sum = prev_color + float4(radianceSum, (float)total_spp);
    int new_count = prev_samples + total_spp;
    
    accumulated_color[dispatchIndex] = new_sum;
    accumulated_samples[dispatchIndex] = new_count;
    
    // 计算平均值
    float3 hdrColor = new_sum.rgb / float(new_count);

    // Apply global exposure multiplier from camera settings
    hdrColor *= camera_info.exposure;
    
    // [关键] 应用 Tone Mapping (HDR -> LDR)
    // 这将把 (20, 50, 20) 这样的亮度映射回 (0.9, 1.0, 0.9) 而不是截断
    float3 mappedColor = ACESFilm(hdrColor);
    
    // Gamma 校正
    mappedColor = pow(mappedColor, 1.0 / 2.2);
    
    output[dispatchIndex] = float4(mappedColor, 1.0);
    entity_id_output[dispatchIndex] = pickPayload.hit ? (int)pickPayload.material_idx : -1;
}

[shader("miss")] void MissMain(inout RayPayload payload) {
	// 使用环境贴图或程序化天空
	float3 rayDir = normalize(WorldRayDirection());
	float3 sky;
	if (skybox_info.has_environment_map > 0.5) {
		sky = SampleEnvironmentMap(rayDir);
	} else {
		sky = GetProceduralSky(rayDir);
	}
	payload.radiance = sky;
	payload.hit = false;
	payload.material_idx = 0xFFFFFFFF;
}

[shader("closesthit")] void ClosestHitMain(inout RayPayload payload, in BuiltInTriangleIntersectionAttributes attr) {
	payload.hit = true;
	payload.material_idx = InstanceID();
	payload.primitive_id = PrimitiveIndex();
	payload.barycentrics = attr.barycentrics;
	
	float t = RayTCurrent();
	payload.hit_pos = WorldRayOrigin() + WorldRayDirection() * t;
	
	// 获取实体ID和图元ID
	uint entity_id = InstanceID();
	uint primitive_id = PrimitiveIndex();
	
	// 转换到物体空间
	float3 worldPos = payload.hit_pos;
	float3 objectPos = mul(WorldToObject3x4(), float4(worldPos, 1.0)).xyz;
	
	// 从全局缓冲区获取法线（优先使用OBJ文件中的vn，否则计算面法线）
	float3 objectNormal = GetVertexNormal(entity_id, primitive_id, attr.barycentrics);
	
	// 转换到世界空间（法线变换需要使用逆转置矩阵）
	float3x3 worldToObject = (float3x3)WorldToObject3x4();
	float3x3 objectToWorldNormal = transpose(worldToObject);
	payload.normal = normalize(mul(objectToWorldNormal, objectNormal));
	
	// 确保法线朝向光线来源
	if (dot(payload.normal, -WorldRayDirection()) < 0) {
		payload.normal = -payload.normal;
	}
	
	// 从全局缓冲区获取UV坐标（优先使用OBJ文件中的vt，否则计算UV）
	payload.uv = GetVertexUV(entity_id, primitive_id, attr.barycentrics, objectPos, objectNormal);
	
	// 应用 Normal Mapping（如果材质有法线贴图）
	Material mat = materials[payload.material_idx];
	if (mat.normal_map_id >= 0) {
		// 获取三角形的三个顶点（用于计算切线）
		EntityOffset entity_offset = entity_offsets[entity_id];
		uint idx0 = global_indices[entity_offset.index_offset + primitive_id * 3 + 0];
		uint idx1 = global_indices[entity_offset.index_offset + primitive_id * 3 + 1];
		uint idx2 = global_indices[entity_offset.index_offset + primitive_id * 3 + 2];
		
		float3 p0 = global_vertices[entity_offset.vertex_offset + idx0];
		float3 p1 = global_vertices[entity_offset.vertex_offset + idx1];
		float3 p2 = global_vertices[entity_offset.vertex_offset + idx2];
		
		// 转换到世界空间
		p0 = mul(ObjectToWorld3x4(), float4(p0, 1.0)).xyz;
		p1 = mul(ObjectToWorld3x4(), float4(p1, 1.0)).xyz;
		p2 = mul(ObjectToWorld3x4(), float4(p2, 1.0)).xyz;
		
		// 获取UV坐标
		float2 uv0 = global_texcoords[entity_offset.vertex_offset + idx0];
		float2 uv1 = global_texcoords[entity_offset.vertex_offset + idx1];
		float2 uv2 = global_texcoords[entity_offset.vertex_offset + idx2];
		
		// 计算切线和副切线
		float3 edge1 = p1 - p0;
		float3 edge2 = p2 - p0;
		float2 deltaUV1 = uv1 - uv0;
		float2 deltaUV2 = uv2 - uv0;
		
		// 计算分母，添加容错处理
		float det = deltaUV1.x * deltaUV2.y - deltaUV2.x * deltaUV1.y;
		float3 T, B;
		
		// 如果 UV 退化（分母接近0），使用几何法线构建一个合理的切线基
		if (abs(det) < 1e-6) {
			// 使用几何法线构建正交基
			float3 N = payload.normal;
			// 找一个与法线不平行的向量
			float3 up = abs(N.y) < 0.999 ? float3(0, 1, 0) : float3(1, 0, 0);
			T = normalize(cross(up, N));
			B = normalize(cross(N, T));
		} else {

            
			// 正常计算切线和副切线
			float f = 1.0 / det;
			T = f * (deltaUV2.y * edge1 - deltaUV1.y * edge2);
			B = f * (-deltaUV2.x * edge1 + deltaUV1.x * edge2);
			
			// 正交化（Gram-Schmidt 过程）
			float3 N = payload.normal;
			T = normalize(T - N * dot(N, T));
			// 确保 T 有效
			if (length(T) < 0.01) {
				float3 up = abs(N.y) < 0.999 ? float3(0, 1, 0) : float3(1, 0, 0);
				T = normalize(cross(up, N));
			}
			B = normalize(cross(N, T));
		}
		
		// 应用 Height Map / Parallax Mapping（如果启用了高度缩放）
		if (mat.height_scale > 0.001) {
			// 计算视线方向（从击中点指向相机/光线起点）
			float3 viewDir = normalize(-WorldRayDirection());
			// 应用视差偏移
			payload.uv = ParallaxMapping(textures[mat.normal_map_id], payload.uv, viewDir, T, B, payload.normal, mat.height_scale);
		}
		
		// 从法线贴图采样（使用 SampleLevel 代替 Sample，因为在 closesthit shader 中不能使用隐式导数）
		float3 normalMapSample = textures[mat.normal_map_id].SampleLevel(texSampler, payload.uv, 0).rgb;
		float3 tangentNormal = normalMapSample * 2.0 - 1.0;
		
		// 构建 TBN 矩阵并转换到世界空间
		float3x3 TBN = float3x3(T, B, payload.normal);
		float3 perturbedNormal = normalize(mul(tangentNormal, TBN));
		
		// 应用法线扰动，但减小强度以避免过度扭曲
		payload.normal = normalize(perturbedNormal);
	}
}
