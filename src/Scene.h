#pragma once
#include "long_march.h"
#include "Entity.h"
#include "Material.h"
#include <vector>
#include <memory>

// Entity offset information for global buffers
struct EntityOffset {
    uint32_t vertex_offset;  // Starting vertex index in global buffer
    uint32_t index_offset;   // Starting index in global buffer
    uint32_t padding[2];     // Align to 16 bytes for GPU
};

// Scene manages a collection of entities and builds the TLAS
class Scene {
public:
    Scene(grassland::graphics::Core* core);
    ~Scene();

    // Add an entity to the scene
    void AddEntity(std::shared_ptr<Entity> entity);

    // Remove all entities
    void Clear();

    // Build/rebuild the TLAS from all entities
    void BuildAccelerationStructures();

    // Update TLAS instances (e.g., for animation)
    void UpdateInstances();

    // Get the TLAS for rendering
    grassland::graphics::AccelerationStructure* GetTLAS() const { return tlas_.get(); }

    // Get materials buffer for all entities
    grassland::graphics::Buffer* GetMaterialsBuffer() const { return materials_buffer_.get(); }

    // Get global geometry buffers for raytracing
    grassland::graphics::Buffer* GetGlobalVertexBuffer() const { return global_vertex_buffer_.get(); }
    grassland::graphics::Buffer* GetGlobalNormalBuffer() const { return global_normal_buffer_.get(); }
    grassland::graphics::Buffer* GetGlobalIndexBuffer() const { return global_index_buffer_.get(); }
    
    // Get entity offset buffer (stores vertex/index offsets for each entity)
    grassland::graphics::Buffer* GetEntityOffsetsBuffer() const { return entity_offsets_buffer_.get(); }
    
    // Get entity velocities buffer (for motion blur)
    grassland::graphics::Buffer* GetVelocitiesBuffer() const { return velocities_buffer_.get(); }
    
    // Get texture array for raytracing
    const std::vector<grassland::graphics::Image*>& GetTextures() const { return textures_; }
    size_t GetTextureCount() const { return textures_.size(); }

    // Get all entities
    const std::vector<std::shared_ptr<Entity>>& GetEntities() const { return entities_; }

    // Get number of entities
    size_t GetEntityCount() const { return entities_.size(); }

    // Update materials buffer data on GPU from CPU-side materials
    void UpdateMaterials();

private:
    void UpdateMaterialsBuffer();
    void BuildGlobalGeometryBuffers();
    void CollectTextures();

    grassland::graphics::Core* core_;
    std::vector<std::shared_ptr<Entity>> entities_;
    std::unique_ptr<grassland::graphics::AccelerationStructure> tlas_;
    std::unique_ptr<grassland::graphics::Buffer> materials_buffer_;
    
    // Global geometry buffers for all entities combined
    std::unique_ptr<grassland::graphics::Buffer> global_vertex_buffer_;
    std::unique_ptr<grassland::graphics::Buffer> global_normal_buffer_;
    std::unique_ptr<grassland::graphics::Buffer> global_index_buffer_;
    std::unique_ptr<grassland::graphics::Buffer> entity_offsets_buffer_;
    
    // Motion blur: entity velocities buffer
    std::unique_ptr<grassland::graphics::Buffer> velocities_buffer_;
    
    // Texture array (raw pointers owned by entities)
    std::vector<grassland::graphics::Image*> textures_;
};

