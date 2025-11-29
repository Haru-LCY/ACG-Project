///////这个文件不运行，只是保存场景设计备份/////////

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
