#include "common.hlsli"

[shader("miss")] void Main(inout RayPayload payload) {
  if (!payload.hit) {
    payload.color = float3(0.8, 0.7, 0.6);
  }
}
