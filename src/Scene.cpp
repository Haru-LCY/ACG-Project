#include "Scene.h"
#include <algorithm>
#include <cmath>
#include <functional>

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
    velocities_buffer_.reset();
}

void Scene::BuildAccelerationStructures() {
    if (entities_.empty()) {
        grassland::LogWarning("No entities to build acceleration structures");
        return;
    }

    // 构建TLAS
    std::vector<grassland::graphics::RayTracingInstance> instances;
    instances.reserve(entities_.size());
    
    for (size_t i = 0; i < entities_.size(); ++i) {
        auto& entity = entities_[i];
        if (entity->GetBLAS()) {
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
    
    core_->CreateTopLevelAccelerationStructure(instances, &tlas_);
    grassland::LogInfo("Built TLAS with {} instances", instances.size());

    // Build global geometry buffers
    BuildGlobalGeometryBuffers();
    
    // Collect textures from entities
    CollectTextures();

    // Update materials buffer (must be done after collecting textures to set texture IDs)
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

void Scene::UpdateMaterials() {
    // Expose private UpdateMaterialsBuffer() functionality
    UpdateMaterialsBuffer();
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
    
    // Create velocities buffer for motion blur
    // 每个实体一个速度向量 (vec4 for alignment: xyz=velocity, w=padding)
    std::vector<glm::vec4> velocities;
    velocities.reserve(std::max(entities_.size(), (size_t)1));
    for (const auto& entity : entities_) {
        glm::vec3 vel = entity->GetVelocity();
        velocities.push_back(glm::vec4(vel, 0.0f));
    }
    // 确保至少有一个元素，避免创建空缓冲区
    if (velocities.empty()) {
        velocities.push_back(glm::vec4(0.0f));
    }
    size_t velocities_buffer_size = velocities.size() * sizeof(glm::vec4);
    core_->CreateBuffer(velocities_buffer_size,
                       grassland::graphics::BUFFER_TYPE_DYNAMIC,
                       &velocities_buffer_);
    velocities_buffer_->UploadData(velocities.data(), velocities_buffer_size);
    
    grassland::LogInfo("Built global geometry buffers: {} vertices, {} normals, {} indices, {} entities", 
                       all_vertices.size(), all_normals.size(), all_indices.size(), entity_offsets.size());
}

void Scene::CollectTextures() {
    textures_.clear();
    
    // Collect all unique textures from entities
    for (auto& entity : entities_) {
        if (entity->HasTexture()) {
            // Add texture to array and set texture ID in entity's material
            int texture_id = static_cast<int>(textures_.size());
            textures_.push_back(entity->GetTexture());
            entity->SetTextureId(texture_id);
            
            grassland::LogInfo("Assigned texture ID {} to entity with texture", texture_id);
        }
    }
    
    // Pad the texture array to the maximum size (16) to satisfy the static descriptor requirement in D3D12.
    // If we don't do this, the descriptor table will have uninitialized descriptors, causing a crash.
    if (!textures_.empty()) {
        size_t current_texture_count = textures_.size();
        const size_t max_textures = 16;
        if (current_texture_count < max_textures) {
            grassland::graphics::Image* fallback_texture = textures_[0]; // Use the first available texture as a fallback
            for (size_t i = current_texture_count; i < max_textures; ++i) {
                textures_.push_back(fallback_texture);
            }
            grassland::LogInfo("Padded texture array from {} to {} with a fallback texture.", current_texture_count, textures_.size());
        }
    }
    
    grassland::LogInfo("Collected {} textures from scene (padded to 16 for GPU binding)", textures_.size());
}

