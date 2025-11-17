struct CameraInfo {
  float4x4 screen_to_camera;
  float4x4 camera_to_world;
};

struct Material {
  float3 base_color;
  float roughness;
  float metallic;
};

struct HoverInfo {
  int hovered_entity_id;
};

RaytracingAccelerationStructure as : register(t0, space0);
RWTexture2D<float4> output : register(u0, space1);
ConstantBuffer<CameraInfo> camera_info : register(b0, space2);
StructuredBuffer<Material> materials : register(t0, space3);
ConstantBuffer<HoverInfo> hover_info : register(b0, space4);
RWTexture2D<int> entity_id_output : register(u0, space5);
RWTexture2D<float4> accumulated_color : register(u0, space6);
RWTexture2D<int> accumulated_samples : register(u0, space7);

struct RayPayload {
	float3 radiance;
	float3 throughput;
	bool hit;
	uint material_idx;
	float3 hit_pos;
	float3 normal;
	float2 barycentrics;
	uint primitive_id;
};

// 改进的 PCG RNG
uint PCGHash(inout uint state) {
	uint prev = state * 747796405u + 2891336453u;
	uint word = ((prev >> ((prev >> 28u) + 4u)) ^ prev) * 277803737u;
	state = prev;
	return (word >> 22u) ^ word;
}

float Rand01(inout uint state) {
	return float(PCGHash(state)) / 4294967296.0;
}

// Lambertian 漫反射采样
float3 SampleCosineHemisphere(float3 n, inout uint seed) {
	float u1 = Rand01(seed);
	float u2 = Rand01(seed);
	float r = sqrt(u1);
	float theta = 2.0 * 3.14159265359 * u2;
	float x = r * cos(theta);
	float y = r * sin(theta);
	float z = sqrt(max(0.0, 1.0 - u1));
	
	float3 up = abs(n.z) < 0.999 ? float3(0, 0, 1) : float3(1, 0, 0);
	float3 t = normalize(cross(up, n));
	float3 b = cross(n, t);
	return normalize(x * t + y * b + z * n);
}

// Schlick Fresnel
float3 FresnelSchlick(float cosTheta, float3 F0) {
	return F0 + (1.0 - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

// GGX importance sampling for specular
float3 SampleGGX(float3 N, float3 V, float roughness, inout uint seed) {
	float a = roughness * roughness;
	float u1 = Rand01(seed);
	float u2 = Rand01(seed);
	
	float theta = atan(a * sqrt(u1) / sqrt(1.0 - u1));
	float phi = 2.0 * 3.14159265359 * u2;
	
	float3 H;
	H.x = sin(theta) * cos(phi);
	H.y = cos(theta);
	H.z = sin(theta) * sin(phi);
	
	// Build tangent space
	float3 up = abs(N.z) < 0.999 ? float3(0, 0, 1) : float3(1, 0, 0);
	float3 T = normalize(cross(up, N));
	float3 B = cross(N, T);
	
	H = normalize(T * H.x + N * H.y + B * H.z);
	return normalize(2.0 * dot(V, H) * H - V);
}

[shader("raygeneration")] void RayGenMain() {
	uint2 dispatchIndex = DispatchRaysIndex().xy;
	int prev_samples = accumulated_samples[dispatchIndex];
	uint seed = (uint)dispatchIndex.x * 1973u + (uint)dispatchIndex.y * 9277u + (uint)prev_samples * 26699u;
	seed = PCGHash(seed);
	seed = PCGHash(seed);
	
	// 生成亚像素抖动 [-0.5, 0.5)
	float jitter_x = Rand01(seed) - 0.5;
	float jitter_y = Rand01(seed) - 0.5;
	float2 pixel_center = (float2)dispatchIndex + float2(0.5 + jitter_x, 0.5 + jitter_y);
	float2 uv = pixel_center / float2(DispatchRaysDimensions().xy);
	uv.y = 1.0 - uv.y;
	float2 d = uv * 2.0 - 1.0;
	
	float4 origin4 = mul(camera_info.camera_to_world, float4(0, 0, 0, 1));
	float4 target = mul(camera_info.screen_to_camera, float4(d, 1, 1));
	float4 direction4 = mul(camera_info.camera_to_world, float4(target.xyz, 0));
	
	float3 rayOrigin0 = origin4.xyz;
	float3 rayDir0 = normalize(direction4.xyz);
	
	const int MAX_BOUNCES = 4; // 保守增加一次反弹
	RayPayload payload;
	payload.radiance = float3(0,0,0);
	payload.throughput = float3(1,1,1);
	payload.hit = false;
	payload.material_idx = 0;
	payload.barycentrics = float2(0, 0);
	payload.primitive_id = 0;
	
	float3 radiance = float3(0,0,0);
	float3 throughput = float3(1,1,1);
	float3 rayOrigin = rayOrigin0;
	float3 rayDir = rayDir0;
	
	for (int bounce = 0; bounce < MAX_BOUNCES; ++bounce) {
		payload.hit = false;
		payload.material_idx = 0;
		payload.hit_pos = float3(0,0,0);
		payload.normal = float3(0,1,0);
		
		RayDesc ray;
		ray.Origin = rayOrigin;
		ray.Direction = rayDir;
		ray.TMin = 0.001;
		ray.TMax = 10000.0;
		
		TraceRay(as, RAY_FLAG_NONE, 0xFF, 0, 1, 0, ray, payload);
		
		if (!payload.hit) {
			// Miss: sample environment / sky
			float3 rayDirNorm = normalize(rayDir);
			float tsky = 0.5 * (rayDirNorm.y + 1.0);
			tsky = smoothstep(0.0, 1.0, tsky);
			float3 sky = lerp(float3(1.0,1.0,1.0), float3(0.5,0.7,1.0), tsky);
			radiance += throughput * sky;
			break;
		}
		
		// 正确的材质处理
		Material mat = materials[payload.material_idx];
		float3 N = normalize(payload.normal);
		float3 V = normalize(-rayDir);
		
		// 确保法线朝向观察方向
		if (dot(N, V) < 0.0) N = -N;
		
		// 计算Fresnel
		float3 F0 = lerp(float3(0.04,0.04,0.04), mat.base_color, mat.metallic);
		float cosTheta = max(dot(N, V), 0.0);
		float3 F = FresnelSchlick(cosTheta, F0);
		
		// 选择镜面或漫反射分支
		float specularProb = max(max(F.x, F.y), F.z);
		specularProb = lerp(specularProb, 1.0, mat.metallic * 0.9); // 金属偏向镜面
		specularProb = clamp(specularProb, 0.1, 0.95); // 避免极端值
		
		float rselect = Rand01(seed);
		
		if (rselect < specularProb) {
			// 镜面反射分支
			if (mat.roughness < 0.05) {
				// 完美镜面
				rayDir = reflect(-V, N);
			} else {
				// 粗糙镜面(GGX采样)
				rayDir = SampleGGX(N, V, mat.roughness, seed);
			}
			
			rayOrigin = payload.hit_pos + N * 0.001;
			
			// 正确的能量补偿
			float NdotL = max(dot(N, rayDir), 0.0);
			if (NdotL > 0.001) {
				throughput *= F * NdotL / specularProb;
			} else {
				break; // 终止无效路径
			}
		} else {
			// 漫反射分支
			rayDir = SampleCosineHemisphere(N, seed);
			rayOrigin = payload.hit_pos + N * 0.001;
			
			// Lambert BRDF: baseColor/π, pdf = cosθ/π, 相消后剩baseColor
			float3 diffuseAlbedo = mat.base_color * (1.0 - mat.metallic);
			throughput *= diffuseAlbedo * (1.0 - F) / (1.0 - specularProb);
		}
		
		// Russian Roulette
		if (bounce >= 2) {
			float p = max(max(throughput.x, throughput.y), throughput.z);
			p = min(p, 0.95);
			if (Rand01(seed) > p) { break; }
			throughput /= max(p, 0.001);
		}
	}
	
	// 累积并输出平均值
	float4 prev_color = accumulated_color[dispatchIndex];
	int prev_samps = prev_samples;
	float4 new_sum = prev_color + float4(radiance, 1);
	int new_count = prev_samps + 1;
	accumulated_color[dispatchIndex] = new_sum;
	accumulated_samples[dispatchIndex] = new_count;
	
	float4 averaged = new_sum / max(1, new_count);
	output[dispatchIndex] = averaged;
	entity_id_output[dispatchIndex] = payload.hit ? (int)payload.material_idx : -1;
}

[shader("miss")] void MissMain(inout RayPayload payload) {
	float t = 0.5 * (normalize(WorldRayDirection()).y + 1.0);
	payload.radiance = lerp(float3(1.0, 1.0, 1.0), float3(0.5, 0.7, 1.0), t);
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
	
	// 使用几何法线(三角形面法线) - 最可靠的方法
	// 如果你的mesh有顶点法线,应该用barycentrics插值
	// 这里先用对象空间几何法线近似
	
	float3 worldPos = payload.hit_pos;
	float3 objectPos = mul(WorldToObject3x4(), float4(worldPos, 1.0)).xyz;
	
	// 简化但更稳健的法线估算
	float3 objectNormal;
	
	// 对于简单几何体,使用径向法线作为默认(适用于球体/凸多面体)
	objectNormal = normalize(objectPos);
	
	// 对于平面(y坐标接近-1的大地面)
	if (abs(objectPos.y + 1.0) < 0.2 && length(objectPos.xz) > 0.5) {
		objectNormal = float3(0, 1, 0);
	}
	// 对于立方体,检测哪个坐标的绝对值最大
	else {
		float3 absPos = abs(objectPos);
		float maxComp = max(max(absPos.x, absPos.y), absPos.z);
		
		if (abs(absPos.x - maxComp) < 0.01) {
			objectNormal = float3(sign(objectPos.x), 0, 0);
		} else if (abs(absPos.y - maxComp) < 0.01) {
			objectNormal = float3(0, sign(objectPos.y), 0);
		} else if (abs(absPos.z - maxComp) < 0.01) {
			objectNormal = float3(0, 0, sign(objectPos.z));
		}
	}
	
	// 转换到世界空间
	float3x3 objectToWorld = (float3x3)ObjectToWorld3x4();
	payload.normal = normalize(mul(objectToWorld, objectNormal));
	
	// 确保法线朝向光线来源(双面材质支持)
	if (dot(payload.normal, -WorldRayDirection()) < 0) {
		payload.normal = -payload.normal;
	}
}