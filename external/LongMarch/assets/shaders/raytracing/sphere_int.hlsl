#include "common.hlsli"

[shader("intersection")] void Main() {
  float3 origin = WorldRayOrigin();
  float3 dir = WorldRayDirection();
  float3 sphere_center = float3(0, 0, 0);
  float sphere_radius = 1.0;

  origin = mul(WorldToObject3x4(), float4(origin, 1));
  dir = mul(WorldToObject3x4(), float4(dir, 0));

  float3 oc = origin - sphere_center;
  float a = dot(dir, dir);
  float b = 2.0 * dot(oc, dir);
  float c = dot(oc, oc) - sphere_radius * sphere_radius;
  float discriminant = b * b - 4 * a * c;

  if (discriminant < 0) {
    return;  // No intersection
  }

  float t = (-b - sqrt(discriminant)) / (2.0 * a);
  if (t > RayTMin()) {
    SphereIntersectionAttributes attr;
    attr.normal = (origin + t * dir) - sphere_center;
    attr.normal = normalize(mul(WorldToObject4x3(), attr.normal).xyz);
    ReportHit(t, 0, attr);
  }

  t = (-b + sqrt(discriminant)) / (2.0 * a);
  if (t > RayTMin()) {
    SphereIntersectionAttributes attr;
    attr.normal = (origin + t * dir) - sphere_center;
    attr.normal = normalize(mul(WorldToObject4x3(), attr.normal).xyz);
    ReportHit(t, 0, attr);
  }
}
