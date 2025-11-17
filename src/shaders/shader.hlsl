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
		
		// Hit: shading and throughput update (保持现有简化 PBR)
		Material mat = materials[payload.material_idx];
		float3 N = normalize(payload.normal);
		float3 V = normalize(-rayDir);
		if (dot(N, V) < 0.0) N = -N;
		
		float3 F0 = lerp(float3(0.04,0.04,0.04), mat.base_color, mat.metallic);
		float cosTheta = max(dot(N, V), 0.0);
		float3 F = FresnelSchlick(cosTheta, F0);
		float specularProb = (F.x + F.y + F.z) / 3.0;
		specularProb = lerp(specularProb, 1.0, mat.metallic);
		
		float rselect = Rand01(seed);
		if (rselect < specularProb) {
			float3 perfectReflect = reflect(-V, N);
			if (mat.roughness < 0.01) {
				rayDir = perfectReflect;
			} else {
				float3 perturbedDir = SampleCosineHemisphere(perfectReflect, seed);
				rayDir = normalize(lerp(perfectReflect, perturbedDir, mat.roughness));
			}
			rayOrigin = payload.hit_pos + N * 0.001;
			throughput *= F / max(specularProb, 0.001);
		} else {
			rayDir = SampleCosineHemisphere(N, seed);
			rayOrigin = payload.hit_pos + N * 0.001;
			throughput *= mat.base_color * (1.0 - F) / max(1.0 - specularProb, 0.001);
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
	
	// 改进的法线估算：使用对象空间位置
	float3 worldPos = payload.hit_pos;
	float3 objectPos = mul(WorldToObject3x4(), float4(worldPos, 1.0)).xyz;
	
	// 根据对象类型推断法线
	float3 objectNormal;
	
	// 检测平面（y 接近常数）
	if (abs(objectPos.y + 1.0) < 0.15 || abs(objectPos.y) < 0.15 || abs(objectPos.y - 1.0) < 0.15) {
		objectNormal = float3(0, sign(objectPos.y + 0.5), 0);
	}
	// 检测盒子（一个坐标的绝对值接近 1）
	else if (abs(abs(objectPos.x) - 1.0) < 0.15 || abs(abs(objectPos.y) - 1.0) < 0.15 || abs(abs(objectPos.z) - 1.0) < 0.15) {
		float3 absPos = abs(objectPos);
		if (absPos.x > absPos.y && absPos.x > absPos.z) {
			objectNormal = float3(sign(objectPos.x), 0, 0);
		} else if (absPos.y > absPos.z) {
			objectNormal = float3(0, sign(objectPos.y), 0);
		} else {
			objectNormal = float3(0, 0, sign(objectPos.z));
		}
	}
	// 默认：球体或其他凸物体，使用径向法线
	else {
		objectNormal = normalize(objectPos);
	}
	
	// 转换到世界空间
	float3x3 objectToWorld = (float3x3)ObjectToWorld3x4();
	payload.normal = normalize(mul(objectToWorld, objectNormal));
	
	// 确保法线朝向光线来源
	if (dot(payload.normal, -WorldRayDirection()) < 0) {
		payload.normal = -payload.normal;
	}
}