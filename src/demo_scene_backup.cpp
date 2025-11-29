///////这个文件不运行，只是保存场景设计备份/////////
////1： matou sakura //////
// Add entities to the scene
    // Ground plane
    {
        auto ground = std::make_shared<Entity>(
            "meshes/cube.obj",
            Material(glm::vec3(0.8f, 0.8f, 0.8f), 0.8f, 0.0f),
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(0.0f, -1.0f, 0.0f)), 
                      glm::vec3(10.0f, 0.1f, 10.0f))
        );
        scene_->AddEntity(ground);
    }

    // Left wall
    {
        auto left_wall = std::make_shared<Entity>(
            "meshes/cube.obj",
            Material(glm::vec3(0.9f, 0.9f, 0.9f), 0.9f, 0.0f),
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(-5.0f, 2.0f, 0.0f)), 
                      glm::vec3(0.1f, 4.0f, 10.0f))
        );
        scene_->AddEntity(left_wall);
    }

    // Right wall
    {
        auto right_wall = std::make_shared<Entity>(
            "meshes/cube.obj",
            Material(glm::vec3(0.9f, 0.9f, 0.9f), 0.9f, 0.0f),
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(5.0f, 2.0f, 0.0f)), 
                      glm::vec3(0.1f, 4.0f, 10.0f))
        );
        scene_->AddEntity(right_wall);
    }

    // Back wall
    {
        auto back_wall = std::make_shared<Entity>(
            "meshes/cube.obj",
            Material(glm::vec3(0.9f, 0.9f, 0.9f), 0.9f, 0.0f),
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(0.0f, 2.0f, -5.0f)), 
                      glm::vec3(10.0f, 4.0f, 0.1f)),
            "textures/sakura.png"
        );
        scene_->AddEntity(back_wall);
    }

    // Ceiling
    {
        auto ceiling = std::make_shared<Entity>(
            "meshes/cube.obj",
            Material(glm::vec3(0.9f, 0.9f, 0.9f), 0.9f, 0.0f),
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(0.0f, 5.0f, 0.0f)), 
                      glm::vec3(10.0f, 0.1f, 10.0f))
        );
        scene_->AddEntity(ceiling);
    }

    // Green metallic sphere (中景 - 作为焦平面目标)
     {
         auto green_sphere = std::make_shared<Entity>(
             "meshes/octahedron.obj",
             Material(glm::vec3(0.2f, 1.0f, 0.2f), 0.2f, 0.8f),
             // 放在 z=2 作为中景焦点
             glm::translate(glm::mat4(1.0f), glm::vec3(0.0f, 0.5f, 2.0f))
         );
         scene_->AddEntity(green_sphere);
     }
     
    // Textured copper sphere (幕后/中景)
    {
        auto copper_sphere = std::make_shared<Entity>(
            "meshes/octahedron.obj",
            Material(glm::vec3(1.0f, 1.0f, 1.0f), 0.3f, 0.9f),  // 白色基础,金属
            // 将铜球移到中景靠后位置，增加前后景深变化
            glm::translate(glm::mat4(1.0f), glm::vec3(-2.5f, 0.5f, 0.0f)),
            "textures/copper/Sphere_Base_color.png"
        );
        scene_->AddEntity(copper_sphere);
    }

    // Transparent blue glass cube (背景)
    // {
    //     auto blue_cube = std::make_shared<Entity>(
    //         "meshes/cube.obj",
    //         // Material(glm::vec3(0.3f, 0.3f, 1.0f), 0.05f, 0.0f, 0.95f, 1.5f), // 蓝色玻璃：明显的蓝色色调
    //         // Material(glm::vec3(1.0f, 1.0f, 1.0f), 0.3f, 0.9f),  // 白色基础,金属
    //         // 将蓝色玻璃放在稍微靠后的背景位置
    //         glm::translate(glm::mat4(1.0f), glm::vec3(2.0f, 0.5f, -2.0f))
    //         // "textures/sakura.png"
    //     );
    //     scene_->AddEntity(blue_cube);
    // }

    {
        auto blue_cube = std::make_shared<Entity>(
            "meshes/cube.obj",
            Material(glm::vec3(0.3f, 0.3f, 1.0f), 0.05f, 0.0f, 0.95f, 1.5f), // 蓝色玻璃：明显的蓝色色调
            // Material(glm::vec3(1.0f, 1.0f, 1.0f), 0.3f, 0.9f),  // 白色基础,金属
            // 将蓝色玻璃放在稍微靠后的背景位置
            glm::translate(glm::mat4(1.0f), glm::vec3(2.0f, 0.5f, -2.0f)),
            "textures/sakura.png"
        );
        blue_cube->SetVelocity(glm::vec3(2.0f, 0.0f, 0.0f));  // 向右移动的运动模糊
        scene_->AddEntity(blue_cube);
    }

    // Foreground specular sphere (近景 - 应该被模糊)
    {
        auto fg_sphere = std::make_shared<Entity>(
            "meshes/octahedron.obj",
             Material(glm::vec3(1.0f, 1.0f, 1.0f), 0.3f, 0.9f),
            // Material(glm::vec3(0.3f, 0.3f, 1.0f), 0.05f, 0.0f, 0.95f, 1.5f), // 蓝色玻璃：明显的蓝色色调
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(0.0f, 0.35f, 4.0f)), glm::vec3(0.5f))
        );
        scene_->AddEntity(fg_sphere);
    }

    // Background ornamental sphere (远景 - 强烈模糊形成bokeh高光)
    {
        auto bg_sphere = std::make_shared<Entity>(
            "meshes/octahedron.obj",
            Material(glm::vec3(1.0f, 1.0f, 0.85f), 0.05f, 1.0f),
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(0.0f, 0.4f, -7.0f)), glm::vec3(0.6f))
        );
        scene_->AddEntity(bg_sphere);
    }


    /////2. museum scene ///////
     // ========== 建筑结构 ==========
    // 1. 地面 - 大理石地板
    {
        auto floor = std::make_shared<Entity>(
            "meshes/cube.obj",
            Material(glm::vec3(0.85f, 0.85f, 0.9f), 0.3f, 0.1f),  // 浅灰大理石
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(0.0f, 0.0f, 0.0f)), 
                      glm::vec3(12.0f, 0.05f, 12.0f))
        );
        scene_->AddEntity(floor);
    }

    // 2-5. 四面墙 - 白色展馆墙壁
    // 左墙
    {
        auto left_wall = std::make_shared<Entity>(
            "meshes/cube.obj",
            Material(glm::vec3(0.95f, 0.95f, 0.97f), 0.7f, 0.0f),
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(-6.0f, 2.5f, 0.0f)), 
                      glm::vec3(0.2f, 5.0f, 12.0f))
        );
        scene_->AddEntity(left_wall);
    }
    // 右墙
    {
        auto right_wall = std::make_shared<Entity>(
            "meshes/cube.obj",
            Material(glm::vec3(0.95f, 0.95f, 0.97f), 0.7f, 0.0f),
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(6.0f, 2.5f, 0.0f)), 
                      glm::vec3(0.2f, 5.0f, 12.0f))
        );
        scene_->AddEntity(right_wall);
    }
    // 后墙
    {
        auto back_wall = std::make_shared<Entity>(
            "meshes/cube.obj",
            Material(glm::vec3(0.95f, 0.95f, 0.97f), 0.7f, 0.0f),
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(0.0f, 2.5f, -6.0f)), 
                      glm::vec3(12.0f, 5.0f, 0.2f)),
            "textures/sakura.png"  // 后墙可以有装饰纹理
        );
        scene_->AddEntity(back_wall);
    }
    // 前墙（入口方向，留出空间）
    {
        auto front_wall = std::make_shared<Entity>(
            "meshes/cube.obj",
            Material(glm::vec3(0.95f, 0.95f, 0.97f), 0.7f, 0.0f),
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(0.0f, 2.5f, 6.0f)), 
                      glm::vec3(12.0f, 5.0f, 0.2f))
        );
        scene_->AddEntity(front_wall);
    }

    // 6. 天花板
    {
        auto ceiling = std::make_shared<Entity>(
            "meshes/cube.obj",
            Material(glm::vec3(0.98f, 0.98f, 0.99f), 0.8f, 0.0f),
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(0.0f, 5.0f, 0.0f)), 
                      glm::vec3(12.0f, 0.1f, 12.0f))
        );
        scene_->AddEntity(ceiling);
    }

    // ========== 支撑柱 ==========
    // 7-10. 四个角落的装饰柱
    {
        auto pillar1 = std::make_shared<Entity>(
            "meshes/cube.obj",
            Material(glm::vec3(0.9f, 0.9f, 0.92f), 0.5f, 0.2f),
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(-5.0f, 2.5f, -5.0f)), 
                      glm::vec3(0.3f, 5.0f, 0.3f))
        );
        scene_->AddEntity(pillar1);
    }
    {
        auto pillar2 = std::make_shared<Entity>(
            "meshes/cube.obj",
            Material(glm::vec3(0.9f, 0.9f, 0.92f), 0.5f, 0.2f),
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(5.0f, 2.5f, -5.0f)), 
                      glm::vec3(0.3f, 5.0f, 0.3f))
        );
        scene_->AddEntity(pillar2);
    }
    {
        auto pillar3 = std::make_shared<Entity>(
            "meshes/cube.obj",
            Material(glm::vec3(0.9f, 0.9f, 0.92f), 0.5f, 0.2f),
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(-5.0f, 2.5f, 5.0f)), 
                      glm::vec3(0.3f, 5.0f, 0.3f))
        );
        scene_->AddEntity(pillar3);
    }
    {
        auto pillar4 = std::make_shared<Entity>(
            "meshes/cube.obj",
            Material(glm::vec3(0.9f, 0.9f, 0.92f), 0.5f, 0.2f),
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(5.0f, 2.5f, 5.0f)), 
                      glm::vec3(0.3f, 5.0f, 0.3f))
        );
        scene_->AddEntity(pillar4);
    }

    // ========== 展台底座 ==========
    // 11-18. 8个展台底座，分布在展馆中
    // 第一排展台（靠近入口）
    {
        auto pedestal1 = std::make_shared<Entity>(
            "meshes/cube.obj",
            Material(glm::vec3(0.7f, 0.7f, 0.75f), 0.4f, 0.3f),  // 深灰大理石
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(-3.5f, 0.4f, 3.5f)), 
                      glm::vec3(1.2f, 0.8f, 1.2f))
        );
        scene_->AddEntity(pedestal1);
    }
    {
        auto pedestal2 = std::make_shared<Entity>(
            "meshes/cube.obj",
            Material(glm::vec3(0.7f, 0.7f, 0.75f), 0.4f, 0.3f),
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(0.0f, 0.4f, 3.5f)), 
                      glm::vec3(1.2f, 0.8f, 1.2f))
        );
        scene_->AddEntity(pedestal2);
    }
    {
        auto pedestal3 = std::make_shared<Entity>(
            "meshes/cube.obj",
            Material(glm::vec3(0.7f, 0.7f, 0.75f), 0.4f, 0.3f),
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(3.5f, 0.4f, 3.5f)), 
                      glm::vec3(1.2f, 0.8f, 1.2f))
        );
        scene_->AddEntity(pedestal3);
    }
    // 第二排展台（中间）
    {
        auto pedestal4 = std::make_shared<Entity>(
            "meshes/cube.obj",
            Material(glm::vec3(0.7f, 0.7f, 0.75f), 0.4f, 0.3f),
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(-3.5f, 0.4f, 0.0f)), 
                      glm::vec3(1.2f, 0.8f, 1.2f))
        );
        scene_->AddEntity(pedestal4);
    }
    {
        auto pedestal5 = std::make_shared<Entity>(
            "meshes/cube.obj",
            Material(glm::vec3(0.7f, 0.7f, 0.75f), 0.4f, 0.3f),
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(0.0f, 0.4f, 0.0f)), 
                      glm::vec3(1.2f, 0.8f, 1.2f))
        );
        scene_->AddEntity(pedestal5);
    }
    {
        auto pedestal6 = std::make_shared<Entity>(
            "meshes/cube.obj",
            Material(glm::vec3(0.7f, 0.7f, 0.75f), 0.4f, 0.3f),
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(3.5f, 0.4f, 0.0f)), 
                      glm::vec3(1.2f, 0.8f, 1.2f))
        );
        scene_->AddEntity(pedestal6);
    }
    // 第三排展台（靠近后墙）
    {
        auto pedestal7 = std::make_shared<Entity>(
            "meshes/cube.obj",
            Material(glm::vec3(0.7f, 0.7f, 0.75f), 0.4f, 0.3f),
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(-3.5f, 0.4f, -3.5f)), 
                      glm::vec3(1.2f, 0.8f, 1.2f))
        );
        scene_->AddEntity(pedestal7);
    }
    {
        auto pedestal8 = std::make_shared<Entity>(
            "meshes/cube.obj",
            Material(glm::vec3(0.7f, 0.7f, 0.75f), 0.4f, 0.3f),
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(3.5f, 0.4f, -3.5f)), 
                      glm::vec3(1.2f, 0.8f, 1.2f))
        );
        scene_->AddEntity(pedestal8);
    }

    // ========== 展品 ==========
    // 19-26. 8个主要展品（每个展台上一个）
    // 第一排展品
    {
        auto exhibit1 = std::make_shared<Entity>(
            "meshes/octahedron.obj",
            Material(glm::vec3(0.2f, 0.8f, 0.3f), 0.2f, 0.9f),  // 绿色金属雕塑
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(-3.5f, 1.2f, 3.5f)), glm::vec3(0.4f))
        );
        scene_->AddEntity(exhibit1);
    }
    {
        auto exhibit2 = std::make_shared<Entity>(
            "meshes/octahedron.obj",
            Material(glm::vec3(1.0f, 1.0f, 1.0f), 0.3f, 0.9f),  // 银色金属
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(0.0f, 1.2f, 3.5f)), glm::vec3(0.5f)),
            "textures/copper/Sphere_Base_color.png"
        );
        scene_->AddEntity(exhibit2);
    }
    {
        auto exhibit3 = std::make_shared<Entity>(
            "meshes/octahedron.obj",
            Material(glm::vec3(0.8f, 0.2f, 0.2f), 0.3f, 0.8f),  // 红色金属
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(3.5f, 1.2f, 3.5f)), glm::vec3(0.45f))
        );
        scene_->AddEntity(exhibit3);
    }
    // 第二排展品
    {
        auto exhibit4 = std::make_shared<Entity>(
            "meshes/octahedron.obj",
            Material(glm::vec3(0.3f, 0.3f, 1.0f), 0.05f, 0.0f, 0.95f, 1.5f),  // 蓝色玻璃
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(-3.5f, 1.2f, 0.0f)), glm::vec3(0.5f))
        );
        scene_->AddEntity(exhibit4);
    }
    {
        auto exhibit5 = std::make_shared<Entity>(
            "meshes/octahedron.obj",
            Material(glm::vec3(0.9f, 0.7f, 0.2f), 0.4f, 0.7f),  // 金色
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(0.0f, 1.2f, 0.0f)), glm::vec3(0.6f))
        );
        scene_->AddEntity(exhibit5);
    }
    {
        auto exhibit6 = std::make_shared<Entity>(
            "meshes/octahedron.obj",
            Material(glm::vec3(0.5f, 0.3f, 0.8f), 0.3f, 0.6f),  // 紫色
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(3.5f, 1.2f, 0.0f)), glm::vec3(0.4f))
        );
        scene_->AddEntity(exhibit6);
    }
    // 第三排展品
    {
        auto exhibit7 = std::make_shared<Entity>(
            "meshes/octahedron.obj",
            Material(glm::vec3(1.0f, 0.8f, 0.6f), 0.2f, 0.5f),  // 陶瓷/陶土色
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(-3.5f, 1.2f, -3.5f)), glm::vec3(0.55f))
        );
        scene_->AddEntity(exhibit7);
    }
    {
        auto exhibit8 = std::make_shared<Entity>(
            "meshes/octahedron.obj",
            Material(glm::vec3(0.2f, 0.6f, 0.8f), 0.25f, 0.85f),  // 青色金属
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(3.5f, 1.2f, -3.5f)), glm::vec3(0.5f))
        );
        scene_->AddEntity(exhibit8);
    }

    // ========== 额外展品（放在中心展台上） ==========
    // 27-28. 中心展台上的两个展品
    {
        auto center_exhibit1 = std::make_shared<Entity>(
            "meshes/octahedron.obj",
            Material(glm::vec3(1.0f, 1.0f, 0.9f), 0.1f, 0.95f),  // 高光白色
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(0.0f, 1.4f, 0.0f)), glm::vec3(0.5f))
        );
        scene_->AddEntity(center_exhibit1);
    }
    {
        auto center_exhibit2 = std::make_shared<Entity>(
            "meshes/octahedron.obj",
            Material(glm::vec3(0.9f, 0.9f, 1.0f), 0.15f, 0.9f),  // 淡蓝色高光
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(0.0f, 0.9f, 0.0f)), glm::vec3(0.35f))
        );
        scene_->AddEntity(center_exhibit2);
    }

    // ========== 展柜（可选，保护重要展品） ==========
    // 29-30. 两个玻璃展柜（降低透明度）
    {
        auto showcase1 = std::make_shared<Entity>(
            "meshes/cube.obj",
            Material(glm::vec3(0.95f, 0.95f, 1.0f), 0.05f, 0.0f, 0.5f, 1.5f),  // 半透明玻璃（transmission从0.9降到0.5）
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(-3.5f, 1.5f, 3.5f)), 
                      glm::vec3(1.5f, 1.5f, 1.5f))
        );
        scene_->AddEntity(showcase1);
    }
    {
        auto showcase2 = std::make_shared<Entity>(
            "meshes/cube.obj",
            Material(glm::vec3(0.95f, 0.95f, 1.0f), 0.05f, 0.0f, 0.5f, 1.5f),  // 半透明玻璃（transmission从0.9降到0.5）
            glm::scale(glm::translate(glm::mat4(1.0f), glm::vec3(3.5f, 1.5f, -3.5f)), 
                      glm::vec3(1.5f, 1.5f, 1.5f))
        );
        scene_->AddEntity(showcase2);
    }
