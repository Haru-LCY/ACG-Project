#include "Scene.h"
#include <algorithm>
#include <cmath>
#include <functional>

// 构造函数：初始化场景对象
Scene::Scene(grassland::graphics::Core* core)
    : core_(core) {
}

// 析构函数：清理所有资源
Scene::~Scene() {
    Clear();
}

// 向场景添加实体
// entity: 实体共享指针
// 功能：验证实体有效性，构建BLAS，添加到实体列表
void Scene::AddEntity(std::shared_ptr<Entity> entity) {
    // 检查实体是否有效
    if (!entity || !entity->IsValid()) {
        grassland::LogError("Cannot add invalid entity to scene");
        return;
    }

    // 为实体构建BLAS（底层加速结构）
    entity->BuildBLAS(core_);
    
    // 添加到实体列表
    entities_.push_back(entity);
    grassland::LogInfo("Added entity to scene (total: {})", entities_.size());
}

// 清除场景中的所有实体和资源
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

// 构建/重建顶层加速结构（TLAS）
// 功能：从所有实体构建TLAS，构建全局几何缓冲区，收集纹理，更新材质缓冲区
void Scene::BuildAccelerationStructures() {
    // 检查是否有实体
    if (entities_.empty()) {
        grassland::LogWarning("No entities to build acceleration structures");
        return;
    }

    // 构建TLAS实例列表
    std::vector<grassland::graphics::RayTracingInstance> instances;
    instances.reserve(entities_.size());
    
    // 为每个实体创建TLAS实例
    for (size_t i = 0; i < entities_.size(); ++i) {
        auto& entity = entities_[i];
        if (entity->GetBLAS()) {
            // 将4x4变换矩阵转换为4x3格式（GPU要求）
            glm::mat4x3 transform_3x4 = glm::mat4x3(entity->GetTransform());
            // 创建实例（使用实体索引作为ID）
            auto instance = entity->GetBLAS()->MakeInstance(
                transform_3x4,
                static_cast<uint32_t>(i),  // 实例ID（实体索引）
                0xFF,                       // 掩码（全部启用）
                0,                          // 偏移量
                grassland::graphics::RAYTRACING_INSTANCE_FLAG_NONE
            );
            instances.push_back(instance);
        }
    }
    
    // 创建顶层加速结构
    core_->CreateTopLevelAccelerationStructure(instances, &tlas_);
    grassland::LogInfo("Built TLAS with {} instances", instances.size());

    // 构建全局几何缓冲区（合并所有实体的几何数据）
    BuildGlobalGeometryBuffers();
    
    // 从实体收集纹理
    CollectTextures();

    // 更新材质缓冲区（必须在收集纹理之后执行，以便设置纹理ID）
    UpdateMaterialsBuffer();
}

// 更新TLAS实例（用于动画）
// 功能：使用更新后的变换矩阵重建所有TLAS实例
void Scene::UpdateInstances() {
    // 检查TLAS和实体是否存在
    if (!tlas_ || entities_.empty()) {
        return;
    }

    // 使用更新后的变换重新创建实例
    std::vector<grassland::graphics::RayTracingInstance> instances;
    instances.reserve(entities_.size());

    // 为每个实体重新创建实例
    for (size_t i = 0; i < entities_.size(); ++i) {
        auto& entity = entities_[i];
        if (entity->GetBLAS()) {
            // 将4x4变换矩阵转换为4x3格式
            glm::mat4x3 transform_3x4 = glm::mat4x3(entity->GetTransform());
            
            // 创建新实例
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

    // 更新TLAS实例
    tlas_->UpdateInstances(instances);
}

// 更新材质缓冲区（公共接口）
// 功能：暴露私有UpdateMaterialsBuffer()功能
void Scene::UpdateMaterials() {
    UpdateMaterialsBuffer();
}

// 更新材质缓冲区（内部实现）
// 功能：收集所有实体的材质，创建或更新GPU材质缓冲区
void Scene::UpdateMaterialsBuffer() {
    // 检查是否有实体
    if (entities_.empty()) {
        return;
    }

    // 收集所有实体的材质
    std::vector<Material> materials;
    materials.reserve(entities_.size());

    for (const auto& entity : entities_) {
        materials.push_back(entity->GetMaterial());
    }

    // 创建或更新材质缓冲区
    size_t buffer_size = materials.size() * sizeof(Material);
    
    // 如果缓冲区不存在，创建它
    if (!materials_buffer_) {
        core_->CreateBuffer(buffer_size, 
                          grassland::graphics::BUFFER_TYPE_DYNAMIC, 
                          &materials_buffer_);
    }
    
    // 上传材质数据到GPU
    materials_buffer_->UploadData(materials.data(), buffer_size);
    grassland::LogInfo("Updated materials buffer with {} materials", materials.size());
}

// 构建全局几何缓冲区
// 功能：合并所有实体的顶点、法线、索引数据到全局缓冲区，并记录每个实体的偏移量
void Scene::BuildGlobalGeometryBuffers() {
    // 检查是否有实体
    if (entities_.empty()) {
        return;
    }

    // 收集所有实体的顶点、法线、索引数据
    std::vector<glm::vec3> all_vertices;
    std::vector<glm::vec3> all_normals;
    std::vector<uint32_t> all_indices;
    std::vector<EntityOffset> entity_offsets;
    
    uint32_t current_vertex_offset = 0;  // 当前顶点偏移量
    uint32_t current_index_offset = 0;    // 当前索引偏移量
    
    // 遍历所有实体，合并几何数据
    for (const auto& entity : entities_) {
        if (!entity->IsValid()) continue;
        
        // 存储此实体的偏移量
        EntityOffset offset;
        offset.vertex_offset = current_vertex_offset;
        offset.index_offset = current_index_offset;
        offset.padding[0] = 0;
        offset.padding[1] = 0;
        entity_offsets.push_back(offset);
        
        // 从实体获取网格数据
        const auto& mesh = entity->GetMesh();
        size_t num_vertices = mesh.NumVertices();
        size_t num_indices = mesh.NumIndices();
        
        // 添加顶点
        const glm::vec3* positions = reinterpret_cast<const glm::vec3*>(mesh.Positions());
        for (size_t i = 0; i < num_vertices; ++i) {
            all_vertices.push_back(positions[i]);
        }
        
        // 添加法线（如果没有法线数据，使用占位符，将在shader中几何计算）
        const glm::vec3* normals = reinterpret_cast<const glm::vec3*>(mesh.Normals());
        if (normals) {
            for (size_t i = 0; i < num_vertices; ++i) {
                all_normals.push_back(normals[i]);
            }
        } else {
            // 生成占位符法线（将在shader中几何计算）
            for (size_t i = 0; i < num_vertices; ++i) {
                all_normals.push_back(glm::vec3(0.0f, 1.0f, 0.0f)); // 占位符
            }
        }
        
        // 添加索引（需要加上当前顶点偏移量，因为我们在构建连续缓冲区）
        const uint32_t* indices = mesh.Indices();
        for (size_t i = 0; i < num_indices; ++i) {
            all_indices.push_back(indices[i] + current_vertex_offset);
        }
        
        // 更新偏移量
        current_vertex_offset += static_cast<uint32_t>(num_vertices);
        current_index_offset += static_cast<uint32_t>(num_indices);
    }
    
    // 创建全局顶点缓冲区
    size_t vertex_buffer_size = all_vertices.size() * sizeof(glm::vec3);
    core_->CreateBuffer(vertex_buffer_size, 
                       grassland::graphics::BUFFER_TYPE_DYNAMIC, 
                       &global_vertex_buffer_);
    global_vertex_buffer_->UploadData(all_vertices.data(), vertex_buffer_size);
    
    // 创建全局法线缓冲区
    size_t normal_buffer_size = all_normals.size() * sizeof(glm::vec3);
    core_->CreateBuffer(normal_buffer_size, 
                       grassland::graphics::BUFFER_TYPE_DYNAMIC, 
                       &global_normal_buffer_);
    global_normal_buffer_->UploadData(all_normals.data(), normal_buffer_size);
    
    // 创建全局索引缓冲区
    size_t index_buffer_size = all_indices.size() * sizeof(uint32_t);
    core_->CreateBuffer(index_buffer_size, 
                       grassland::graphics::BUFFER_TYPE_DYNAMIC, 
                       &global_index_buffer_);
    global_index_buffer_->UploadData(all_indices.data(), index_buffer_size);
    
    // 创建实体偏移缓冲区
    size_t offsets_buffer_size = entity_offsets.size() * sizeof(EntityOffset);
    core_->CreateBuffer(offsets_buffer_size, 
                       grassland::graphics::BUFFER_TYPE_DYNAMIC, 
                       &entity_offsets_buffer_);
    entity_offsets_buffer_->UploadData(entity_offsets.data(), offsets_buffer_size);
    
    // 创建速度缓冲区（用于运动模糊）
    // 每个实体一个速度向量（vec4用于对齐：xyz=速度，w=填充）
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

// 收集所有实体的纹理
// 功能：从所有实体收集纹理，分配纹理ID，填充纹理数组到16个以满足D3D12静态描述符要求
void Scene::CollectTextures() {
    textures_.clear();
    
    // 从所有实体收集唯一纹理
    for (auto& entity : entities_) {
        if (entity->HasTexture()) {
            // 将纹理添加到数组，并在实体的材质中设置纹理ID
            int texture_id = static_cast<int>(textures_.size());
            textures_.push_back(entity->GetTexture());
            entity->SetTextureId(texture_id);
            
            grassland::LogInfo("Assigned texture ID {} to entity with texture", texture_id);
        }
    }
    
    // 将纹理数组填充到最大大小（16）以满足D3D12的静态描述符要求
    // 如果不这样做，描述符表将包含未初始化的描述符，导致崩溃
    if (!textures_.empty()) {
        size_t current_texture_count = textures_.size();
        const size_t max_textures = 16;
        if (current_texture_count < max_textures) {
            // 使用第一个可用纹理作为后备纹理
            grassland::graphics::Image* fallback_texture = textures_[0];
            for (size_t i = current_texture_count; i < max_textures; ++i) {
                textures_.push_back(fallback_texture);
            }
            grassland::LogInfo("Padded texture array from {} to {} with a fallback texture.", current_texture_count, textures_.size());
        }
    }
    
    grassland::LogInfo("Collected {} textures from scene (padded to 16 for GPU binding)", textures_.size());
}

