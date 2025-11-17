#pragma once
#include "long_march.h"
#include "Material.h"

// Entity represents a mesh instance with a material and transform
class Entity {
public:
    Entity(const std::string& obj_file_path, 
           const Material& material = Material(),
           const glm::mat4& transform = glm::mat4(1.0f));

    ~Entity();

    // Load mesh from OBJ file
    bool LoadMesh(const std::string& obj_file_path);

    // Getters
    grassland::graphics::Buffer* GetVertexBuffer() const { return vertex_buffer_.get(); }
    grassland::graphics::Buffer* GetIndexBuffer() const { return index_buffer_.get(); }
    grassland::graphics::Buffer* GetNormalBuffer() const { return normal_buffer_.get(); }
    const Material& GetMaterial() const { return material_; }
    const glm::mat4& GetTransform() const { return transform_; }
    grassland::graphics::AccelerationStructure* GetBLAS() const { return blas_.get(); }

    // Setters
    void SetMaterial(const Material& material) { material_ = material; }
    void SetTransform(const glm::mat4& transform) { transform_ = transform; }

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

    std::unique_ptr<grassland::graphics::Buffer> vertex_buffer_;
    std::unique_ptr<grassland::graphics::Buffer> index_buffer_;
    std::unique_ptr<grassland::graphics::Buffer> normal_buffer_;
    std::unique_ptr<grassland::graphics::AccelerationStructure> blas_;

    bool mesh_loaded_;
};

