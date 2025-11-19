#include "Film.h"

Film::Film(grassland::graphics::Core* core, int width, int height)
    : core_(core)
    , width_(width)
    , height_(height)
    , sample_count_(0) {
    
    CreateImages();
    Reset();
}

Film::~Film() {
    accumulated_color_image_.reset();
    accumulated_samples_image_.reset();
    output_image_.reset();
}

void Film::CreateImages() {
    // Create accumulated color image (RGBA32F for high precision accumulation)
    core_->CreateImage(width_, height_, 
                      grassland::graphics::IMAGE_FORMAT_R32G32B32A32_SFLOAT,
                      &accumulated_color_image_);
    
    // Create accumulated samples image (R32_SINT to count samples)
    core_->CreateImage(width_, height_, 
                      grassland::graphics::IMAGE_FORMAT_R32_SINT,
                      &accumulated_samples_image_);
    
    // Create output image (RGBA32F for final result)
    core_->CreateImage(width_, height_, 
                      grassland::graphics::IMAGE_FORMAT_R32G32B32A32_SFLOAT,
                      &output_image_);
}

void Film::Reset() {
    sample_count_ = 0;
    
    std::unique_ptr<grassland::graphics::CommandContext> command_context;
    core_->CreateCommandContext(&command_context);

    command_context->CmdClearImage(accumulated_samples_image_.get(), { {0, 0, 0, 0} });

    command_context->CmdClearImage(accumulated_color_image_.get(), { {0.0, 0.0, 0.0, 0.0} });

    command_context->CmdClearImage(output_image_.get(), { {0.0, 0.0, 0.0, 0.0} });

    core_->SubmitCommandContext(command_context.get());
}

void Film::DevelopToOutput() {
    // This would ideally be done in a compute shader for efficiency
    // For now, we'll do it on the CPU (simple but potentially slow)
    
    if (sample_count_ == 0) {
        return;
    }

    // Download accumulated color and samples
    size_t color_size = width_ * height_ * sizeof(float) * 4;
    std::vector<float> accumulated_colors(width_ * height_ * 4);
    accumulated_color_image_->DownloadData(accumulated_colors.data());

    // Divide by sample count to get average HDR color, then apply tone mapping
    std::vector<float> output_colors(width_ * height_ * 4);
    for (int i = 0; i < width_ * height_; i++) {
        // 计算平均HDR颜色
        float r = accumulated_colors[i * 4 + 0] / static_cast<float>(sample_count_);
        float g = accumulated_colors[i * 4 + 1] / static_cast<float>(sample_count_);
        float b = accumulated_colors[i * 4 + 2] / static_cast<float>(sample_count_);
        
        // ACES Tone Mapping (与shader中的算法一致)
        auto ACESFilm = [](float x) -> float {
            float a = 2.51f;
            float b = 0.03f;
            float c = 2.43f;
            float d = 0.59f;
            float e = 0.14f;
            return std::max(0.0f, std::min(1.0f, (x * (a * x + b)) / (x * (c * x + d) + e)));
        };
        
        r = ACESFilm(r);
        g = ACESFilm(g);
        b = ACESFilm(b);
        
        // Gamma 校正 (2.2)
        r = std::pow(r, 1.0f / 2.2f);
        g = std::pow(g, 1.0f / 2.2f);
        b = std::pow(b, 1.0f / 2.2f);
        
        output_colors[i * 4 + 0] = r;
        output_colors[i * 4 + 1] = g;
        output_colors[i * 4 + 2] = b;
        output_colors[i * 4 + 3] = 1.0f; // Alpha
    }

    // Upload to output image
    output_image_->UploadData(output_colors.data());
}

void Film::Resize(int width, int height) {
    if (width == width_ && height == height_) {
        return;
    }

    width_ = width;
    height_ = height;

    // Recreate images with new dimensions
    accumulated_color_image_.reset();
    accumulated_samples_image_.reset();
    output_image_.reset();

    CreateImages();
    Reset();
    
    grassland::LogInfo("Film resized to {}x{}", width, height);
}

