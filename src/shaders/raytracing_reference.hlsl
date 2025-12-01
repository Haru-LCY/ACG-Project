// Include structures
#include "camera_object.hlsl"
#include "hit_record.hlsl"
#include "sphere.hlsl"
#include "triangle.hlsl"
#include "point_light.hlsl"

// Buffers
ConstantBuffer<CameraObject> camera_object : register(b0, space0);
StructuredBuffer<Triangle> triangles : register(t0, space1);
StructuredBuffer<Material> triangle_materials : register(t0, space2);
StructuredBuffer<Sphere> spheres : register(t0, space3);
StructuredBuffer<Material> sphere_materials : register(t0, space4);
StructuredBuffer<PointLight> point_lights : register(t0, space5);

// Vertex shader input/output
struct VSInput {
  [[vk::location(0)]] float2 position : TEXCOORD0;
  [[vk::location(1)]] float2 tex_coord : TEXCOORD1;
};

struct PSInput {
  float4 position : SV_POSITION;
  [[vk::location(0)]] float2 tex_coord : TEXCOORD0;
};

// Raytracing functions (You may change any function in this file, the code base is merely a skeleton to help you get started, it does not imply a optimal design)
bool IntersectSphere(float3 ray_origin, float3 ray_direction, Sphere sphere, out float t, out float3 normal) {
  // TODO: Implement Ray-sphere intersection
  // return true if there is an intersection, false otherwise
  
  float3 oc = ray_origin - sphere.origin;
  float a = dot(ray_direction, ray_direction);
  float b = 2.0 * dot(oc, ray_direction);
  float c = dot(oc, oc) - sphere.radius * sphere.radius;
  float discriminant = b * b - 4.0 * a * c;


  if (discriminant < 0.0) {
    return false;
  }
  
  float sqrt_discriminant = sqrt(discriminant);
  t = (-b - sqrt_discriminant) / (2.0 * a);
  if (t <= 0.0) {
    t = (-b + sqrt_discriminant) / (2.0 * a);
    if (t <= 0.0) {
      return false;
    }
  }
  
  float3 hit_point = ray_origin + t * ray_direction;
  normal = normalize(hit_point - sphere.origin);
  return true;
}

bool IntersectTriangle(float3 ray_origin, float3 ray_direction, Triangle tri, out float t, out float3 normal) {
  // TODO: Implement Ray-triangle intersection
  // return true if there is an intersection, false otherwise
  
  // first check if the ray is parallel to the triangle
  float3 edge1 = tri.v1 - tri.v0;
  float3 edge2 = tri.v2 - tri.v0;
  normal = cross(edge1, edge2);
  
  // Check if triangle is degenerate (zero area)
  float normal_length_sq = dot(normal, normal);
  if (normal_length_sq < 1e-10) {
    return false;
  }
  
  normal = normalize(normal);
  
  // Check if ray is parallel to the triangle plane
  float denom = dot(normal, ray_direction);
  if (abs(denom) < 1e-10) {
    return false;
  }

  // second calculate the parameter t (use normal vector of the triangle plane)
  float3 v0_to_origin = tri.v0 - ray_origin;
  t = dot(v0_to_origin, normal) / denom;
  
  // Check if intersection is behind the ray origin
  if (t <= 0.0) {
    return false;
  }

  // third check if the intersection point lies inside the triangle
  float3 hit_point = ray_origin + t * ray_direction;
  
  // Use edge vectors and cross products to check if point is inside triangle
  float3 v0_to_hit = hit_point - tri.v0;
  float3 v1_to_hit = hit_point - tri.v1;
  float3 v2_to_hit = hit_point - tri.v2;
  
  // Check if point is on the correct side of each edge
  float3 c0 = cross(edge1, v0_to_hit);
  float3 c1 = cross(tri.v2 - tri.v1, v1_to_hit);
  float3 c2 = cross(tri.v0 - tri.v2, v2_to_hit);
  
  // All cross products should point in the same direction (same side of normal)
  bool inside = (dot(c0, normal) >= 0.0) && (dot(c1, normal) >= 0.0) && (dot(c2, normal) >= 0.0);
  
  return inside;
}

bool CastRay(float3 ray_origin, float3 ray_direction, out HitRecord hit_record) {
  // TODO: Implement the CastRay function to find the closest intersection
  // return true if there is at least an intersection, false otherwise 
  // Hint: Store the intersection information in hit_record, you can view the "out" parameter as a pointer in C/C++
  // (i.e.) Any change on the hit_record will be reflected outside of this function
  
  float closest_t = 1e30;
  bool found_intersection = false;
  Material closest_material;
  float3 closest_normal;
  
  for (uint i = 0; i < camera_object.num_triangle; i++) {
    float t;
    float3 normal;
    if (IntersectTriangle(ray_origin, ray_direction, triangles[i], t, normal)) {
      if (t < closest_t) {
        closest_t = t;
        closest_material = triangle_materials[i];
        closest_normal = normal;
        found_intersection = true;
      }
    }
  }
  
  for (uint i = 0; i < camera_object.num_sphere; i++) {
    float t;
    float3 normal;
    if (IntersectSphere(ray_origin, ray_direction, spheres[i], t, normal)) {
      if (t < closest_t) {
        closest_t = t;
        closest_material = sphere_materials[i];
        closest_normal = normal;
        found_intersection = true;
      }
    }
  }
  
  if (found_intersection) {
    hit_record.material = closest_material;
    hit_record.normal = closest_normal;
    hit_record.t_min = closest_t;
    hit_record.t_max = closest_t;
    return true;
  }
  
  return false;
}

float3 CalculateLighting(float3 hit_point, float3 normal, Material material) {
  // Calculate lighting according to assignment specification
  // For diffuse: Lambertian reflection model
  // For specular: mirror (no direct lighting, handled by recursive ray tracing)
  
  float3 color = float3(0.0, 0.0, 0.0);
  
  // Ambient light: diffuse surfaces
  if (material.material_type == MaterialDiffuse) {
    color += material.albedo_color * camera_object.ambient_light;
  }

  for (uint i = 0; i < camera_object.num_point_light; i++) {
    PointLight light = point_lights[i];
    
    // Calculate light direction and distance
    // p_L - p
    float3 light_vec = light.position - hit_point;
    float light_distance = length(light_vec);
    // (p_L - p) / |p_L - p|
    float3 light_dir = light_vec / light_distance;
    
    // Check if light is on the front side of the surface
    // n · (p_L - p) / |p_L - p|
    float NdotL = dot(normal, light_dir);
    if (NdotL <= 0.0) {
      continue; 
    }
    
    // Shadow ray tracing
    const float RAY_EPSILON = 0.001;
    float3 shadow_origin = hit_point + normal * RAY_EPSILON;
    HitRecord shadow_hit;
    bool shadowed = CastRay(shadow_origin, light_dir, shadow_hit);
    
    // If shadow ray hits something closer than the light, we're in shadow
    if (shadowed && shadow_hit.t_min < light_distance) {
      continue;
    }
    
    if (material.material_type == MaterialSpecular) {
      continue;
    }
    
    // Point light contribution formula:
    // P / |p - p_L|² * max(0, n · (p_L - p) / |p_L - p|)
    float distance_sq = light_distance * light_distance;
    float3 contribution = light.power / distance_sq * NdotL;
    
    // albedo_color influences point light contribution
    color += material.albedo_color * contribution;
  }
  
  return color;
}

float3 SampleRay(float3 origin, float3 direction) {
  // Path tracing implementation
  // According to README: 
  // - Ray traverses scene and stops at first intersection
  // - If diffuse: calculate sum of visible lights and return immediately
  // - If specular: calculate reflected ray and repeat
  
  float3 radiance = float3(0.0, 0.0, 0.0);
  float3 throughput = float3(1.0, 1.0, 1.0);
  float3 current_origin = origin;
  float3 current_direction = direction;
  
  const uint MAX_BOUNCES = 100;
  
  for (uint bounce = 0; bounce < MAX_BOUNCES; bounce++) {
    HitRecord hit_record;
    bool hit = CastRay(current_origin, current_direction, hit_record);
    
    if (!hit) {
      // Ray escaped from the scene - return ambient light contribution
      radiance += throughput * camera_object.ambient_light;
      break;
    }
    
    // Calculate hit point
    float3 hit_point = current_origin + hit_record.t_min * current_direction;
    
    // Offset hit point slightly along normal to avoid self-intersection
    const float RAY_EPSILON = 0.001;
    float3 N = normalize(hit_record.normal);
    float3 V = normalize(-current_direction);  // View direction (towards light source)
    
    // Ensure normal faces towards ray origin (for two-sided materials)
    bool entering = dot(N, V) > 0.0;
    if (!entering) {
      N = -N;
    }
    
    // Sample next direction based on material type
    if (hit_record.material.material_type == MaterialDiffuse) {
      // For diffuse materials: calculate direct lighting and terminate path
      // Offset hit point before calculating lighting
      float3 offset_hit_point = hit_point + N * RAY_EPSILON;
      float3 lighting = CalculateLighting(offset_hit_point, N, hit_record.material);
      radiance += throughput * lighting;
      break;  // Diffuse materials absorb light, don't continue tracing
    } else if (hit_record.material.material_type == MaterialSpecular) {
      // Specular surface: perfect mirror reflection
      // Use reflect(-V, N) where V is view direction (towards light source)
      // This gives reflection direction from surface
      float3 reflected_dir = reflect(-V, N);
      
      // Update throughput with albedo (for colored mirrors)
      throughput *= hit_record.material.albedo_color;
      
      // Update ray for next bounce
      // Offset hit point along reflected direction to avoid self-intersection
      current_origin = hit_point + N * RAY_EPSILON;
      current_direction = normalize(reflected_dir);
    }
    
  }
  
  return radiance;
}

// Vertex shader
PSInput VSMain(VSInput input) {
  PSInput output;
  output.position = float4(input.position, 0.0f, 1.0f);
  output.tex_coord = input.tex_coord;
  return output;
}

// Pixel shader
float4 PSMain(PSInput input) : SV_TARGET {
  float3 color = float3(0.0, 0.0, 0.0);

  #define SUPER_SAMPLE_X 4
  #define SUPER_SAMPLE_Y 4

  for (int x = 0; x < SUPER_SAMPLE_X; x++) {
    for (int y = 0; y < SUPER_SAMPLE_Y; y++) {
      float2 pixel_offset = float2((x + 0.5) * 1.0 / SUPER_SAMPLE_X,
                                   (y + 0.5) * 1.0 / SUPER_SAMPLE_Y);

      float4 direction = mul(camera_object.projection,
                            float4(((input.position.xy + pixel_offset) /
                                   camera_object.window_extent) * 2.0 - 1.0,
                                   1.0, 1.0));

      float3 subpixel_color = SampleRay(
          mul(camera_object.camera_to_world, float4(0.0, 0.0, 0.0, 1.0)).xyz,
          mul(camera_object.camera_to_world, float4(normalize(direction.xyz), 0.0)).xyz);

      subpixel_color = clamp(subpixel_color, 0.0, 1.0);
      color += subpixel_color;
    }
  }

  return float4(color / (SUPER_SAMPLE_X * SUPER_SAMPLE_Y), 1.0);
}
