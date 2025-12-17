// ==================== Common Structures and Resources ====================
// 通用结构体定义和资源声明

#ifndef COMMON_HLSL
#define COMMON_HLSL

// ==================== Constants ====================
#define MAX_TEXTURES 64  // 纹理数组最大数量（必须与C++端保持一致）

struct CameraInfo {
  float4x4 screen_to_camera;
  float4x4 camera_to_world;
  float aperture;        // 光圈大小
  float focus_distance;  // 焦距
  float exposure;       // 曝光乘数（亮度缩放）
  int samples_per_pixel; // 每帧每像素样本数
  int debug_mode;        // 0=off,1=show-only-debug-point-light
  int debug_point_index; // which point light index to debug (0..N-1)
  int msaa_mode;         // MSAA 模式: 0=Off, 1=2x, 2=4x, 3=8x, 4=Random
  int accumulated_frames; // 累积帧数（用于时间累积 MSAA）
  // Motion Blur 参数
  int motion_blur_mode;     // 0=Off, 1=Camera, 2=Object, 3=Radial, 4=Directional
  float motion_blur_intensity; // 运动模糊强度
  float2 motion_blur_direction; // 方向性模糊的方向
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
  int normal_map_id;
  float height_scale;  // 高度贴图缩放系数（0=禁用，通常 0.01-0.1）
  float padding3;
};

struct HoverInfo {
    int hovered_entity_id;
};

// 实体偏移信息结构体（用于全局缓冲区，必须与C++端保持一致）
struct EntityOffset {
    uint vertex_offset;  // 在全局缓冲区中的起始顶点索引
    uint index_offset;   // 在全局缓冲区中的起始索引
    uint padding[2];     // 填充以对齐到16字节（GPU要求）
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

// Skybox / Environment Map 信息
struct SkyboxInfo {
    // 程序化天空颜色
    float3 zenith_color;      // 天顶颜色
    float has_environment_map; // 是否有环境贴图 (>0.5 = true)
    
    float3 horizon_color;     // 地平线颜色
    float environment_intensity; // 环境光强度
    
    float3 ground_color;      // 地面颜色
    float environment_rotation; // 环境贴图旋转角度（弧度）
    
    // 太阳/方向光设置
    float3 sun_direction;     // 太阳方向（归一化）
    float sun_intensity;      // 太阳强度
    
    float3 sun_color;         // 太阳颜色
    float sun_angular_radius; // 太阳角半径（弧度）
};

// 体积雾信息结构体
struct VolumetricFogInfo {
    float fog_top_height;           // 雾的顶部高度（高于此高度无雾）
    float fog_density_multiplier;   // 雾密度倍增系数
    float volume_step_size;         // 体积采样步长（越小越精确但性能越低）
    float padding1;
    
    float3 fog_absorption_color;    // 体积吸收颜色（RGB，影响雾的颜色）
    float padding2;
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
Texture2D textures[MAX_TEXTURES] : register(t0, space10);  // 纹理数组 (最多MAX_TEXTURES个)
SamplerState texSampler : register(s0, space11);  // 纹理采样器
StructuredBuffer<float4> entity_velocities : register(t0, space15);  // 实体速度数组 (xyz=velocity, w=padding)

// Skybox / Environment Map 资源
ConstantBuffer<SkyboxInfo> skybox_info : register(b0, space16);    // 天空盒信息
Texture2D environment_map : register(t0, space17);                  // HDR 环境贴图
SamplerState envSampler : register(s0, space18);                    // 环境贴图采样器

// 全局几何缓冲区（用于从OBJ文件加载的几何数据）
StructuredBuffer<float3> global_vertices : register(t0, space19);      // 全局顶点缓冲区
StructuredBuffer<float3> global_normals : register(t0, space20);       // 全局法线缓冲区
StructuredBuffer<float2> global_texcoords : register(t0, space21);     // 全局UV坐标缓冲区
StructuredBuffer<uint> global_indices : register(t0, space22);         // 全局索引缓冲区
StructuredBuffer<EntityOffset> entity_offsets : register(t0, space23); // 实体偏移缓冲区

// 体积雾参数
ConstantBuffer<VolumetricFogInfo> fog_info : register(b0, space24);   // 体积雾信息

//t，u，space分别表示纹理寄存器、采样器寄存器和常量缓冲区寄存器的空间索引

// ==================== Constants ====================
static const float SHADOW_DEBUG_BOOST = 1.0; //1.0相当于正常
static const float PI = 3.14159265359;

// 路径追踪和阴影追踪的最大弹射次数
#define MAX_PATH_BOUNCES 8      // 路径追踪最大弹射次数
#define MAX_SHADOW_BOUNCES 6    // 阴影追踪最大弹射次数（用于透明材质）

// ==================== 射线追踪精度常量 ====================
static const float RAY_TMIN = 0.0001;           // 射线起始最小距离（防止自相交）
static const float RAY_EPSILON = 0.001;         // 射线偏移量（阴影射线、反射等）
static const float MIN_VISIBILITY = 0.001;      // 最小可见度阈值（低于此值提前终止）
static const float MIN_DENSITY_THRESHOLD = 0.001; // 体积密度阈值
static const float MIN_DISTANCE_THRESHOLD = 0.001; // 最小距离阈值

// ==================== 材质判断阈值 ====================
static const float TRANSMISSION_THRESHOLD = 0.01;  // 透射材质判断阈值
static const float ALPHA_MAP_THRESHOLD = 0.5;      // alpha 贴图存在判断阈值
static const float MIN_VISIBILITY_CUTOFF = 0.001;  // 可见度截止阈值

// ==================== RGB 亮度转换权重 ====================
static const float3 RGB_LUMINANCE_WEIGHTS = float3(0.299, 0.587, 0.114); // ITU-R BT.601标准

// ==================== 光照计算常量 ====================
static const int NUM_AREA_LIGHT_SAMPLES = 1;      // 面光源采样次数
static const float EPSILON_DIVIDE_ZERO = 1e-8;    // 防止除零的极小值
static const float MIN_LIGHT_DISTANCE = 0.05;     // 点光源最小距离（数值稳定性）
static const float MIN_LIGHT_RADIUS = 0.01;       // 点光源最小半径
static const float MAX_ATTENUATION = 1e4;         // 光源衰减最大值（防止过曝）
static const float MAX_RADIANCE_PER_LIGHT = 100.0; // 单光源最大辐射度（防止异常亮点）

#endif // COMMON_HLSL

