#include "common.hlsli"

[shader("closesthit")] void Main(inout RayPayload payload, in BuiltInTriangleIntersectionAttributes attr) {
  float3 barycentrics =
      float3(1.0 - attr.barycentrics.x - attr.barycentrics.y, attr.barycentrics.x, attr.barycentrics.y);
  if (!payload.hit) {
    payload.color = payload.a * barycentrics + payload.b;
    payload.hit = true;
  }
}