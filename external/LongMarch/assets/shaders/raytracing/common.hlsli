
struct CameraInfo {
  float4x4 screen_to_camera;
  float4x4 camera_to_world;
};

struct RayPayload {
  float3 color;
  bool hit;
  float a;
  float3 b;
};

struct SphereIntersectionAttributes {
  float3 normal;
};

struct ShadingColor {
  float3 color;
};

RaytracingAccelerationStructure as : register(t0, space0);
RWTexture2D<float4> output : register(u0, space1);
ConstantBuffer<CameraInfo> camera_info : register(b0, space2);