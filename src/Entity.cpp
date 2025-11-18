#include "Entity.h"

Entity::Entity(const std::string& obj_file_path, 
               const Material& material,
               const glm::mat4& transform,
               const std::string& texture_path)
    : material_(material)
    , transform_(transform)
    , texture_path_(texture_path)
    , mesh_loaded_(false) {
    
    LoadMesh(obj_file_path);
}

Entity::~Entity() {
    blas_.reset();
    normal_buffer_.reset();
    index_buffer_.reset();
    vertex_buffer_.reset();
    texture_.reset();
}

bool Entity::LoadMesh(const std::string& obj_file_path) {
    // Try to load the OBJ file
    std::string full_path = grassland::FindAssetFile(obj_file_path);
    
    if (mesh_.LoadObjFile(full_path) != 0) {
        grassland::LogError("Failed to load mesh from: {}", obj_file_path);
        mesh_loaded_ = false;
        return false;
    }

    grassland::LogInfo("Successfully loaded mesh: {} ({} vertices, {} indices)", 
                       obj_file_path, mesh_.NumVertices(), mesh_.NumIndices());
    
    mesh_loaded_ = true;
    return true;
}

void Entity::BuildBLAS(grassland::graphics::Core* core) {
    if (!mesh_loaded_) {
        grassland::LogError("Cannot build BLAS: mesh not loaded");
        return;
    }

    // Create vertex buffer
    size_t vertex_buffer_size = mesh_.NumVertices() * sizeof(glm::vec3);
    core->CreateBuffer(vertex_buffer_size, 
                      grassland::graphics::BUFFER_TYPE_DYNAMIC, 
                      &vertex_buffer_);
    vertex_buffer_->UploadData(mesh_.Positions(), vertex_buffer_size);

    // Create normal buffer (only if mesh has normals)
    if (mesh_.Normals()) {
        size_t normal_buffer_size = mesh_.NumVertices() * sizeof(glm::vec3);
        core->CreateBuffer(normal_buffer_size, 
                          grassland::graphics::BUFFER_TYPE_DYNAMIC, 
                          &normal_buffer_);
        normal_buffer_->UploadData(mesh_.Normals(), normal_buffer_size);
        grassland::LogInfo("Created normal buffer with {} normals", mesh_.NumVertices());
    } else {
        grassland::LogWarning("Mesh has no normals - will generate defaults or use geometric normals");
    }

    // Create index buffer
    size_t index_buffer_size = mesh_.NumIndices() * sizeof(uint32_t);
    core->CreateBuffer(index_buffer_size, 
                      grassland::graphics::BUFFER_TYPE_DYNAMIC, 
                      &index_buffer_);
    index_buffer_->UploadData(mesh_.Indices(), index_buffer_size);

    // Build BLAS
    core->CreateBottomLevelAccelerationStructure(
        vertex_buffer_.get(), 
        index_buffer_.get(), 
        sizeof(glm::vec3), 
        &blas_);

    grassland::LogInfo("Built BLAS for entity ({} vertices, {} indices)", 
                       mesh_.NumVertices(), mesh_.NumIndices());
    
    // Load texture if path is provided
    if (!texture_path_.empty()) {
        LoadTexture(core, texture_path_);
    }
}

bool Entity::LoadTexture(grassland::graphics::Core* core, const std::string& texture_path) {
    if (texture_path.empty()) {
        grassland::LogWarning("Empty texture path provided");
        return false;
    }
    
    // Try to find the texture file
    std::string full_path = grassland::FindAssetFile(texture_path);
    
    // Use the framework's LoadImageFromFile function
    if (grassland::graphics::LoadImageFromFile(core, full_path, &texture_) != 0) {
        grassland::LogError("Failed to load texture from: {}", texture_path);
        return false;
    }
    
    grassland::LogInfo("Successfully loaded texture: {} ({}x{})", 
                       texture_path, 
                       texture_->Extent().width, 
                       texture_->Extent().height);
    return true;
}

