// ==================== Common Structures and Resources ====================
// 通用结构体定义和资源声明

#ifndef COMMON_HLSL
#define COMMON_HLSL

struct CameraInfo {
  float4x4 screen_to_camera;
  float4x4 camera_to_world;
  float aperture;        // 光圈大小
  float focus_distance;  // 焦距
  float exposure;       // 曝光乘数（亮度缩放）
  int samples_per_pixel; // 每帧每像素样本数
  int debug_mode;        // 0=off,1=show-only-debug-point-light
  int debug_point_index; // which point light index to debug (0..N-1)
  int padding0;          // 对齐
};

// Principled BSDF Material (matches C++ struct layout)
struct Material {
  // Base properties
  float3 base_color;
  float roughness;
  
  float metallic;
  float specular;
  float specular_tint;
  float anisotropic;
  
  float anisotropic_rotation;
  float sheen;
  float sheen_tint;
  float clearcoat;
  
  float clearcoat_roughness;
  float transmission;
  float transmission_roughness;
  float ior;
  
  float3 transmission_color;
  float subsurface;
  
  float3 subsurface_color;
  float padding1;
  
  float3 subsurface_radius;
  float padding2;
  
  float3 emission_color;
  float emission_strength;
  
  float alpha_threshold;
  float has_alpha_map;
  int texture_id;
  float padding3;
};

struct HoverInfo {
    int hovered_entity_id;
};

// KDT信息结构体（用于传递节点数量）
struct KDTInfo {
    uint num_nodes;        // KDT节点数量
    uint padding[3];       // 对齐填充
};

// 点光源结构体
struct PointLight {
  float3 position;     // 光源位置
  float strength;      // 光源强度
  float3 color;        // 光源颜色
  float radius;        // 光源半径（用于软阴影）
};

//面光源结构体
struct AreaLight {
    float3 position;     // 光源中心位置
    float strength;      // 总辐射功率（单位：瓦特）
    float3 color;        // 光源颜色 (RGB, 范围0-1)
    float width;         // 光源宽度（米）
    float3 direction;    // 光源法线方向（归一化）
    float height;        // 光源高度（米）
    float3 u_axis;       // 宽度方向轴（归一化）
    float pad1;
    float3 v_axis;       // 高度方向轴（归一化）
    float pad2;
};

struct RayPayload {
	float3 radiance;
	float3 throughput;
	bool hit;
	uint material_idx;
	float3 hit_pos;
	float3 normal;
	float2 barycentrics;
	uint primitive_id;
	float2 uv;  // UV坐标用于纹理采样
};

// KDT节点结构体（与C++中的KDTNodeGPU对应）
struct KDTNode {
	float3 aabb_min;        // AABB最小值
	float3 aabb_max;        // AABB最大值
	int split_axis;         // 分割轴：0=X, 1=Y, 2=Z, -1=叶子节点
	float split_pos;         // 分割位置
	int left_child_idx;     // 左子节点索引（-1表示无子节点）
	int right_child_idx;     // 右子节点索引（-1表示无子节点）
	int entity_start_idx;    // 实体索引列表起始位置（仅在叶子节点有效）
	int entity_count;        // 实体数量（仅在叶子节点有效）
	uint mask;               // 该节点对应的instance mask
	uint padding;            // 对齐填充
};

// ==================== Resources ====================
RaytracingAccelerationStructure as : register(t0, space0);
RWTexture2D<float4> output : register(u0, space1);
ConstantBuffer<CameraInfo> camera_info : register(b0, space2);
StructuredBuffer<Material> materials : register(t0, space3);
ConstantBuffer<HoverInfo> hover_info : register(b0, space4);
RWTexture2D<int> entity_id_output : register(u0, space5);
RWTexture2D<float4> accumulated_color : register(u0, space6);
RWTexture2D<int> accumulated_samples : register(u0, space7);
RWTexture2D<float> depth_output : register(u0, space12);
StructuredBuffer<PointLight> point_lights : register(t0, space8);  // 点光源数组
StructuredBuffer<AreaLight> area_lights : register(t0, space9);  // 面光源数组
Texture2D textures[16] : register(t0, space10);  // 纹理数组 (最多16个)
SamplerState texSampler : register(s0, space11);  // 纹理采样器
StructuredBuffer<KDTNode> kdt_nodes : register(t0, space13);  // KDT节点数组
ConstantBuffer<KDTInfo> kdt_info : register(b0, space14);  // KDT信息（节点数量）
//t，u，space分别表示纹理寄存器、采样器寄存器和常量缓冲区寄存器的空间索引

// ==================== Constants ====================
static const float SHADOW_DEBUG_BOOST = 1.0; //1.0相当于正常
static const float PI = 3.14159265359;

#endif // COMMON_HLSL

