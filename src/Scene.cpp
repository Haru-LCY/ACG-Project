#include "Scene.h"

Scene::Scene(grassland::graphics::Core* core)
    : core_(core) {
}

Scene::~Scene() {
    Clear();
}

void Scene::AddEntity(std::shared_ptr<Entity> entity) {
    if (!entity || !entity->IsValid()) {
        grassland::LogError("Cannot add invalid entity to scene");
        return;
    }

    // Build BLAS for the entity
    entity->BuildBLAS(core_);
    
    entities_.push_back(entity);
    grassland::LogInfo("Added entity to scene (total: {})", entities_.size());
}

void Scene::Clear() {
    entities_.clear();
    tlas_.reset();
    materials_buffer_.reset();
    global_vertex_buffer_.reset();
    global_normal_buffer_.reset();
    global_index_buffer_.reset();
    entity_offsets_buffer_.reset();
}

void Scene::BuildAccelerationStructures() {
    if (entities_.empty()) {
        grassland::LogWarning("No entities to build acceleration structures");
        return;
    }

    // Create TLAS instances from all entities
    std::vector<grassland::graphics::RayTracingInstance> instances;
    instances.reserve(entities_.size());

    for (size_t i = 0; i < entities_.size(); ++i) {
        auto& entity = entities_[i];
        if (entity->GetBLAS()) {
            // Create instance with entity's transform
            // instanceCustomIndex is used to index into materials buffer
            // Convert mat4 to mat4x3 (drop the last row which is always [0,0,0,1] for affine transforms)
            glm::mat4x3 transform_3x4 = glm::mat4x3(entity->GetTransform());
            
            auto instance = entity->GetBLAS()->MakeInstance(
                transform_3x4,
                static_cast<uint32_t>(i),  // instanceCustomIndex for material lookup
                0xFF,                       // instanceMask
                0,                          // instanceShaderBindingTableRecordOffset
                grassland::graphics::RAYTRACING_INSTANCE_FLAG_NONE
            );
            instances.push_back(instance);
        }
    }

    // Build TLAS
    core_->CreateTopLevelAccelerationStructure(instances, &tlas_);
    grassland::LogInfo("Built TLAS with {} instances", instances.size());

    // Build global geometry buffers
    BuildGlobalGeometryBuffers();

    // Update materials buffer
    UpdateMaterialsBuffer();
}

void Scene::UpdateInstances() {
    if (!tlas_ || entities_.empty()) {
        return;
    }

    // Recreate instances with updated transforms
    std::vector<grassland::graphics::RayTracingInstance> instances;
    instances.reserve(entities_.size());

    for (size_t i = 0; i < entities_.size(); ++i) {
        auto& entity = entities_[i];
        if (entity->GetBLAS()) {
            // Convert mat4 to mat4x3
            glm::mat4x3 transform_3x4 = glm::mat4x3(entity->GetTransform());
            
            auto instance = entity->GetBLAS()->MakeInstance(
                transform_3x4,
                static_cast<uint32_t>(i),
                0xFF,
                0,
                grassland::graphics::RAYTRACING_INSTANCE_FLAG_NONE
            );
            instances.push_back(instance);
        }
    }

    // Update TLAS
    tlas_->UpdateInstances(instances);
}

void Scene::UpdateMaterialsBuffer() {
    if (entities_.empty()) {
        return;
    }

    // Collect all materials
    std::vector<Material> materials;
    materials.reserve(entities_.size());

    for (const auto& entity : entities_) {
        materials.push_back(entity->GetMaterial());
    }

    // Create/update materials buffer
    size_t buffer_size = materials.size() * sizeof(Material);
    
    if (!materials_buffer_) {
        core_->CreateBuffer(buffer_size, 
                          grassland::graphics::BUFFER_TYPE_DYNAMIC, 
                          &materials_buffer_);
    }
    
    materials_buffer_->UploadData(materials.data(), buffer_size);
    grassland::LogInfo("Updated materials buffer with {} materials", materials.size());
}

void Scene::BuildGlobalGeometryBuffers() {
    if (entities_.empty()) {
        return;
    }

    // Collect all vertices, normals, and indices from all entities
    std::vector<glm::vec3> all_vertices;
    std::vector<glm::vec3> all_normals;
    std::vector<uint32_t> all_indices;
    std::vector<EntityOffset> entity_offsets;
    
    uint32_t current_vertex_offset = 0;
    uint32_t current_index_offset = 0;
    
    for (const auto& entity : entities_) {
        if (!entity->IsValid()) continue;
        
        // Store offset for this entity
        EntityOffset offset;
        offset.vertex_offset = current_vertex_offset;
        offset.index_offset = current_index_offset;
        offset.padding[0] = 0;
        offset.padding[1] = 0;
        entity_offsets.push_back(offset);
        
        // Get mesh data from entity
        const auto& mesh = entity->GetMesh();
        size_t num_vertices = mesh.NumVertices();
        size_t num_indices = mesh.NumIndices();
        
        // Add vertices
        const glm::vec3* positions = reinterpret_cast<const glm::vec3*>(mesh.Positions());
        for (size_t i = 0; i < num_vertices; ++i) {
            all_vertices.push_back(positions[i]);
        }
        
        // Add normals (use geometric normals if not available)
        const glm::vec3* normals = reinterpret_cast<const glm::vec3*>(mesh.Normals());
        if (normals) {
            for (size_t i = 0; i < num_vertices; ++i) {
                all_normals.push_back(normals[i]);
            }
        } else {
            // Generate placeholder normals (will be computed geometrically in shader)
            for (size_t i = 0; i < num_vertices; ++i) {
                all_normals.push_back(glm::vec3(0.0f, 1.0f, 0.0f)); // Placeholder
            }
        }
        
        // Add indices (no offset needed here since we're building a continuous buffer)
        const uint32_t* indices = mesh.Indices();
        for (size_t i = 0; i < num_indices; ++i) {
            all_indices.push_back(indices[i] + current_vertex_offset);
        }
        
        current_vertex_offset += static_cast<uint32_t>(num_vertices);
        current_index_offset += static_cast<uint32_t>(num_indices);
    }
    
    // Create global vertex buffer
    size_t vertex_buffer_size = all_vertices.size() * sizeof(glm::vec3);
    core_->CreateBuffer(vertex_buffer_size, 
                       grassland::graphics::BUFFER_TYPE_DYNAMIC, 
                       &global_vertex_buffer_);
    global_vertex_buffer_->UploadData(all_vertices.data(), vertex_buffer_size);
    
    // Create global normal buffer
    size_t normal_buffer_size = all_normals.size() * sizeof(glm::vec3);
    core_->CreateBuffer(normal_buffer_size, 
                       grassland::graphics::BUFFER_TYPE_DYNAMIC, 
                       &global_normal_buffer_);
    global_normal_buffer_->UploadData(all_normals.data(), normal_buffer_size);
    
    // Create global index buffer
    size_t index_buffer_size = all_indices.size() * sizeof(uint32_t);
    core_->CreateBuffer(index_buffer_size, 
                       grassland::graphics::BUFFER_TYPE_DYNAMIC, 
                       &global_index_buffer_);
    global_index_buffer_->UploadData(all_indices.data(), index_buffer_size);
    
    // Create entity offsets buffer
    size_t offsets_buffer_size = entity_offsets.size() * sizeof(EntityOffset);
    core_->CreateBuffer(offsets_buffer_size, 
                       grassland::graphics::BUFFER_TYPE_DYNAMIC, 
                       &entity_offsets_buffer_);
    entity_offsets_buffer_->UploadData(entity_offsets.data(), offsets_buffer_size);
    
    grassland::LogInfo("Built global geometry buffers: {} vertices, {} normals, {} indices, {} entities", 
                       all_vertices.size(), all_normals.size(), all_indices.size(), entity_offsets.size());
}

