// 相机信息数据结构
#ifndef CAMERA_INFO_HLSL
#define CAMERA_INFO_HLSL

struct CameraInfo {
  float4x4 screen_to_camera;
  float4x4 camera_to_world;
};

struct HoverInfo {
  int hovered_entity_id;
};

#endif // CAMERA_INFO_HLSL
