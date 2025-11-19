#include "common.hlsli"

[shader("closesthit")] void Main(inout RayPayload payload, in SphereIntersectionAttributes attr) {
  if (!payload.hit) {
    payload.color = float3(1.0, 1.0, 1.0) * (max(dot(attr.normal, normalize(float3(-3.0, 1.0, 2.0))), 0.0) * 0.5 + 0.5);
    payload.hit = true;
    ShadingColor shading_color;
    shading_color.color = payload.color;
    CallShader(0, shading_color);
    payload.color = shading_color.color;
  }
}