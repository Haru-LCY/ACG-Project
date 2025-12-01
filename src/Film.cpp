#include "Film.h"

// 构造函数：初始化Film对象
Film::Film(grassland::graphics::Core* core, int width, int height)
    : core_(core)
    , width_(width)
    , height_(height)
    , sample_count_(0) {
    
    // 创建所有图像缓冲区
    CreateImages();
    // 重置累积状态
    Reset();
}

// 析构函数：释放所有图像资源
Film::~Film() {
    accumulated_color_image_.reset();
    accumulated_samples_image_.reset();
    output_image_.reset();
}

// 创建所有图像缓冲区（内部辅助函数）
void Film::CreateImages() {
    // 创建累积颜色图像（RGBA32F格式，用于高精度累积）
    core_->CreateImage(width_, height_, 
                      grassland::graphics::IMAGE_FORMAT_R32G32B32A32_SFLOAT,
                      &accumulated_color_image_);
    
    // 创建累积样本计数图像（R32_SINT格式，用于计数样本）
    core_->CreateImage(width_, height_, 
                      grassland::graphics::IMAGE_FORMAT_R32_SINT,
                      &accumulated_samples_image_);
    
    // 创建输出图像（RGBA32F格式，用于最终结果）
    core_->CreateImage(width_, height_, 
                      grassland::graphics::IMAGE_FORMAT_R32G32B32A32_SFLOAT,
                      &output_image_);
}

// 重置累积缓冲区
// 功能：清空所有累积图像，重置样本计数为0
void Film::Reset() {
    sample_count_ = 0;
    
    // 创建命令上下文用于GPU操作
    std::unique_ptr<grassland::graphics::CommandContext> command_context;
    core_->CreateCommandContext(&command_context);

    // 清空样本计数图像（设为0）
    command_context->CmdClearImage(accumulated_samples_image_.get(), { {0, 0, 0, 0} });

    // 清空累积颜色图像（设为黑色）
    command_context->CmdClearImage(accumulated_color_image_.get(), { {0.0, 0.0, 0.0, 0.0} });

    // 清空输出图像（设为黑色）
    command_context->CmdClearImage(output_image_.get(), { {0.0, 0.0, 0.0, 0.0} });

    // 提交命令到GPU执行
    core_->SubmitCommandContext(command_context.get());
}

// 将累积数据转换为最终输出图像
// 功能：计算平均HDR颜色，应用色调映射和Gamma校正
// 注意：此函数在CPU端执行，可能较慢。理想情况下应在GPU端使用compute shader实现
void Film::DevelopToOutput() {
    // 理想情况下应该在GPU端使用compute shader实现以提高效率
    // 目前在CPU端实现（简单但可能较慢）
    
    // 如果没有样本，直接返回
    if (sample_count_ == 0) {
        return;
    }

    // 从GPU下载累积颜色数据
    size_t color_size = width_ * height_ * sizeof(float) * 4;
    std::vector<float> accumulated_colors(width_ * height_ * 4);
    accumulated_color_image_->DownloadData(accumulated_colors.data());

    // 除以样本数量得到平均HDR颜色，然后应用色调映射
    std::vector<float> output_colors(width_ * height_ * 4);
    for (int i = 0; i < width_ * height_; i++) {
        // 计算平均HDR颜色
        float r = accumulated_colors[i * 4 + 0] / static_cast<float>(sample_count_);
        float g = accumulated_colors[i * 4 + 1] / static_cast<float>(sample_count_);
        float b = accumulated_colors[i * 4 + 2] / static_cast<float>(sample_count_);
        
        // ACES色调映射（与shader中的算法一致）
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
        
        // Gamma校正（2.2）
        r = std::pow(r, 1.0f / 2.2f);
        g = std::pow(g, 1.0f / 2.2f);
        b = std::pow(b, 1.0f / 2.2f);
        
        output_colors[i * 4 + 0] = r;
        output_colors[i * 4 + 1] = g;
        output_colors[i * 4 + 2] = b;
        output_colors[i * 4 + 3] = 1.0f; // Alpha
    }

    // 上传到输出图像
    output_image_->UploadData(output_colors.data());
}

// 调整Film尺寸
// width: 新宽度
// height: 新高度
// 功能：重新创建所有图像缓冲区并重置累积状态
void Film::Resize(int width, int height) {
    // 如果尺寸未改变，直接返回
    if (width == width_ && height == height_) {
        return;
    }

    width_ = width;
    height_ = height;

    // 释放旧图像并重新创建新尺寸的图像
    accumulated_color_image_.reset();
    accumulated_samples_image_.reset();
    output_image_.reset();

    CreateImages();
    Reset();
    
    grassland::LogInfo("Film resized to {}x{}", width, height);
}

