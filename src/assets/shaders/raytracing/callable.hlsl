#include "common.hlsli"

[shader("callable")] void Main(inout ShadingColor payload) {
  payload.color = payload.color * float3(0.6, 0.7, 0.8);
}
