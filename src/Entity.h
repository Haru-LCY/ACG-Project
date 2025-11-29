#pragma once
#include "long_march.h"
#include "Material.h"

// Entity represents a mesh instance with a material and transform
class Entity {
public:
    Entity(const std::string& obj_file_path, 
           const Material& material = Material(),
           const glm::mat4& transform = glm::mat4(1.0f),
           const std::string& texture_path = "");

    ~Entity();

    // Load mesh from OBJ file
    bool LoadMesh(const std::string& obj_file_path);
    
    // Load texture from file
    bool LoadTexture(grassland::graphics::Core* core, const std::string& texture_path);

    // Getters
    grassland::graphics::Buffer* GetVertexBuffer() const { return vertex_buffer_.get(); }
    grassland::graphics::Buffer* GetIndexBuffer() const { return index_buffer_.get(); }
    grassland::graphics::Buffer* GetNormalBuffer() const { return normal_buffer_.get(); }
    grassland::graphics::Image* GetTexture() const { return texture_.get(); }
    const Material& GetMaterial() const { return material_; }
    const glm::mat4& GetTransform() const { return transform_; }
    grassland::graphics::AccelerationStructure* GetBLAS() const { return blas_.get(); }
    bool HasTexture() const { return texture_ != nullptr; }
    
    // Motion blur: 获取物体速度
    const glm::vec3& GetVelocity() const { return velocity_; }

    // Setters
    void SetMaterial(const Material& material) { material_ = material; }
    void SetTransform(const glm::mat4& transform) { transform_ = transform; }
    void SetTextureId(int id) { material_.texture_id = id; }
    
    // Motion blur: 设置物体速度（世界空间，单位：单位/帧）
    void SetVelocity(const glm::vec3& velocity) { velocity_ = velocity; }

    // Create BLAS for this entity's mesh
    void BuildBLAS(grassland::graphics::Core* core);

    // Check if mesh is loaded
    bool IsValid() const { return mesh_loaded_; }

    // Get mesh data (for building global buffers)
    const grassland::Mesh<float>& GetMesh() const { return mesh_; }

private:
    grassland::Mesh<float> mesh_;
    Material material_;
    glm::mat4 transform_;
    std::string texture_path_;

    std::unique_ptr<grassland::graphics::Buffer> vertex_buffer_;
    std::unique_ptr<grassland::graphics::Buffer> index_buffer_;
    std::unique_ptr<grassland::graphics::Buffer> normal_buffer_;
    std::unique_ptr<grassland::graphics::Image> texture_;
    std::unique_ptr<grassland::graphics::AccelerationStructure> blas_;

    bool mesh_loaded_;
    
    // Motion blur: 物体速度（世界空间，单位：单位/帧）
    glm::vec3 velocity_ = glm::vec3(0.0f);
};

