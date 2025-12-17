   // Cornell Box 原始尺寸约为 556x548.8x559.2，需要缩放以适应场景
    // 缩放因子 0.02 使其约为 11.12x10.98x11.18 单位（扩大一倍）
    // 同时需要平移使其中心位于原点附近
    glm::mat4 cornell_box_transform = glm::translate(glm::mat4(1.0f), glm::vec3(-5.56f, 0.0f, -5.6f))
                                    * glm::scale(glm::mat4(1.0f), glm::vec3(0.02f));

    // Add Cornell Box Floor (white)
    {
        auto floor = std::make_shared<Entity>(
            "meshes/cornell_box_floor.obj",
            Material(glm::vec3(1.0f, 1.0f, 1.0f), 0.8f, 0.0f),  // white
            cornell_box_transform
        );
        scene_->AddEntity(floor);
    }

    // Add Cornell Box Ceiling (white)
    {
        auto ceiling = std::make_shared<Entity>(
            "meshes/cornell_box_ceiling.obj",
            Material(glm::vec3(1.0f, 1.0f, 1.0f), 0.8f, 0.0f),  // white
            cornell_box_transform
        );
        scene_->AddEntity(ceiling);
    }

    // // Add Cornell Box Back Wall (white)
    // {
    //     auto back_wall = std::make_shared<Entity>(
    //         "meshes/cornell_box_back_wall.obj",
    //         Material(glm::vec3(1.0f, 1.0f, 1.0f), 0.8f, 0.0f),  // white
    //         cornell_box_transform
    //     );
    //     scene_->AddEntity(back_wall);
    // }

// BSDF mirrow with clear coat implement. backup
    // Add Cornell Box Front Wall (glass material with sakura texture, white color)
    {
        // Metallic mirror material with clear coat (softer parameters)
        Material front_wall_material(glm::vec3(1.0f, 1.0f, 1.0f), 0.05f, 0.9f);  // white, metallic mirror (roughness=0.05, metallic=0.9)
        front_wall_material.clearcoat = 0.8f;              // Moderate clear coat strength
        front_wall_material.clearcoat_roughness = 0.05f;   // Slightly rougher clear coat for softer reflection
        
        // Front wall dimensions: width=556, height=548.8 (in original coordinates)
        // After cornell_box_transform (scale 0.02): width=11.12, height=10.976
        // Cube is 2x2x2 unit cube, so scale factors: width=11.12/2=5.56, height=10.976/2=5.488, depth=0.1/2=0.05
        // Center position: x=(549.6+0)/2*0.02-5.56=-0.064, y=274.4*0.02=5.488, z=0*0.02-5.6=-5.6
        glm::mat4 front_wall_transform = glm::translate(glm::mat4(1.0f), glm::vec3(-0.064f, 5.488f, -5.6f))
                                       * glm::scale(glm::mat4(1.0f), glm::vec3(5.56f, 5.488f, 0.05f));  // Scale cube to match wall size
        
        auto front_wall = std::make_shared<Entity>(
            "meshes/cube.obj",
            front_wall_material,
            front_wall_transform
        );
        scene_->AddEntity(front_wall);
    }

    // Add Cornell Box Front Wall (white block material with height map)
    // {
    //     // White block material (high roughness, more diffuse reflection)
    //     Material front_wall_material(glm::vec3(1.0f, 1.0f, 1.0f), 0.8f, 0.0f);  // white, high roughness, non-metallic
    //     front_wall_material.height_scale = 0.1f;  // Enable height map with strong effect
        
    //     // Front wall dimensions: width=556, height=548.8 (in original coordinates)
    //     // After cornell_box_transform (scale 0.02): width=11.12, height=10.976
    //     // Cube is 2x2x2 unit cube, so scale factors: width=11.12/2=5.56, height=10.976/2=5.488, depth=0.1/2=0.05
    //     // Center position: x=(549.6+0)/2*0.02-5.56=-0.064, y=274.4*0.02=5.488, z=0*0.02-5.6=-5.6
    //     glm::mat4 front_wall_transform = glm::translate(glm::mat4(1.0f), glm::vec3(-0.064f, 5.488f, -5.6f))
    //                                    * glm::scale(glm::mat4(1.0f), glm::vec3(5.56f, 5.488f, 0.05f));  // Scale cube to match wall size
        
    //     auto front_wall = std::make_shared<Entity>(
    //         "meshes/cube.obj",
    //         front_wall_material,
    //         front_wall_transform,
    //         "",
    //         "textures/normal.png"
    //     );
    //     scene_->AddEntity(front_wall);
    // }

    {
        auto blue_cube = std::make_shared<Entity>(
            "meshes/cube.obj",
            Material(glm::vec3(0.3f, 0.3f, 1.0f), 0.05f, 0.0f, 0.95f, 1.5f), // 蓝色玻璃：明显的蓝色色调
            // Material(glm::vec3(1.0f, 1.0f, 1.0f), 0.3f, 0.9f),  // 白色基础,金属
            // 将蓝色玻璃往 x 轴靠外移动，更靠近摄像机位置
            glm::translate(glm::mat4(1.0f), glm::vec3(-2.0f, 2.0f, 4.0f))  // x从2.0改为3.5，更靠近相机
            // "textures/sakura.png"
        );
        blue_cube->SetVelocity(glm::vec3(1.0f, 0.0f, 0.0f));  // 向右移动的运动模糊
        scene_->AddEntity(blue_cube);
    }


    {
        // White base material with iiis texture
        auto white_cube = std::make_shared<Entity>(
            "meshes/cube.obj",
            Material(glm::vec3(1.0f, 1.0f, 1.0f), 0.8f, 0.0f),  // white base material (non-metallic, non-transparent)
            glm::translate(glm::mat4(1.0f), glm::vec3(2.0f, 1.0f, 4.0f)),
            "textures/iiis.png"  // Add iiis texture
        );
        white_cube->SetVelocity(glm::vec3(1.0f, 0.0f, 0.0f));  // 向右移动的运动模糊
        scene_->AddEntity(white_cube);
    }


    // Add Cornell Box Green Wall
    {
        auto green_wall = std::make_shared<Entity>(
            "meshes/cornell_box_green_wall.obj",
            Material(glm::vec3(0.0f, 1.0f, 0.0f), 0.8f, 0.0f),  // green
            cornell_box_transform
        );
        scene_->AddEntity(green_wall);
    }

    // Add Cornell Box Red Wall
    {
        auto red_wall = std::make_shared<Entity>(
            "meshes/cornell_box_red_wall.obj",
            Material(glm::vec3(1.0f, 0.0f, 0.0f), 0.8f, 0.0f),  // red
            cornell_box_transform
        );
        scene_->AddEntity(red_wall);
    }

    // Add Cornell Box Light (emissive white)
    {
        Material light_material(glm::vec3(1.0f, 1.0f, 1.0f), 0.8f, 0.0f);
        light_material.emission_color = glm::vec3(1.0f, 1.0f, 1.0f);
        light_material.emission_strength = 20.0f;  // Ka 20 20 20 from MTL
        
        auto light = std::make_shared<Entity>(
            "meshes/cornell_box_light.obj",
            light_material,
            cornell_box_transform
        );
        scene_->AddEntity(light);
    }

    // Add Cornell Box Short Block (white base material with tsinghua texture)
    {
        // Replace short_block with cube of same size, with tsinghua texture
        // Short block dimensions: width≈208, height=165, depth≈207 (in original coordinates)
        // After cornell_box_transform (scale 0.02): width≈4.16, height=3.3, depth≈4.14
        // Scale to 2x current size: width≈2.496, height=1.98, depth≈2.484
        // Adjust position so bottom surface aligns with floor (y=0), then move up 1 unit
        // Cube height = 1.98, so center should be at y = 1.98/2 + 1.0 = 1.99
        glm::mat4 cube_transform = glm::translate(glm::mat4(1.0f), glm::vec3(-1.84f, 1.99f, -2.23f))
                                  * glm::scale(glm::mat4(1.0f), glm::vec3(2.496f, 1.98f, 2.484f));  // Scale to 2x current size
        
        auto short_block = std::make_shared<Entity>(
            "meshes/cube.obj",
            Material(glm::vec3(1.0f, 1.0f, 1.0f), 0.8f, 0.0f),  // white, non-metallic base material
            cube_transform,
            "textures/tsinghua.png"  // Add tsinghua texture
        );
        // short_block->SetVelocity(glm::vec3(0.0f, 0.0f, 1.0f));  // 向 z 轴正方向移动的运动模糊
        scene_->AddEntity(short_block);
    }

    // {
    //     auto blue_cube = std::make_shared<Entity>(
    //         "meshes/cube.obj",
    //         Material(glm::vec3(0.3f, 0.3f, 1.0f), 0.05f, 0.0f, 0.95f, 1.5f), // 蓝色玻璃：明显的蓝色色调
    //         // Material(glm::vec3(1.0f, 1.0f, 1.0f), 0.3f, 0.9f),  // 白色基础,金属
    //         // 将蓝色玻璃往 x 轴靠外移动，更靠近摄像机位置
    //         glm::translate(glm::mat4(1.0f), glm::vec3(3.5f, 1.0f, 10.0f)),  // x从2.0改为3.5，更靠近相机
    //         "textures/sakura.png"
    //     );
    //     blue_cube->SetVelocity(glm::vec3(1.0f, 0.0f, 0.0f));  // 向右移动的运动模糊
    //     scene_->AddEntity(blue_cube);
    // }




    // Add Cornell Box Tall Block (white) - replaced by flower
    // {
    //     auto tall_block = std::make_shared<Entity>(
    //         "meshes/cornell_box_tall_block.obj",
    //         Material(glm::vec3(1.0f, 1.0f, 1.0f), 0.8f, 0.0f),  // white
    //         cornell_box_transform
    //     );
    //     scene_->AddEntity(tall_block);
    // }

    // Add small flower asset from assets (scale 0.1) and rotate to stand upright
    // Positioned at tall_block location: center at (368.5, 165.0, 351.5) in original coordinates
    // After cornell_box_transform (scale 0.02, translate (-5.56, 0, -5.6)):
    // x: 368.5 * 0.02 - 5.56 = 1.81
    // y: 165.0 * 0.02 = 3.3
    // z: 351.5 * 0.02 - 5.6 = 1.43
    // {
    //     // Build a transform: translate * rotate * scale
    //     // Position at tall_block center, rotate to stand upright
    //     glm::mat4 flower_transform = glm::translate(glm::mat4(1.0f), glm::vec3(1.81f, 3.3f, 1.43f))
    //                               * glm::rotate(glm::mat4(1.0f), glm::radians(-90.0f), glm::vec3(1.0f, 0.0f, 0.0f))
    //                               * glm::scale(glm::mat4(1.0f), glm::vec3(0.1f));

    //     auto flower = std::make_shared<Entity>(
    //         "meshes/12973_anemone_flower_v1_l2.obj",
    //         // diffuse, non-metallic material
    //         Material(glm::vec3(1.0f, 1.0f, 1.0f), 0.8f, 0.0f),
    //         flower_transform,
    //         // use diffuse texture from the mesh's material if available
    //         "meshes/12973_anemone_flower_diff.jpg"
    //     );
    //     // keep static (no velocity) by default
    //     flower->SetVelocity(glm::vec3(0.0f, 0.0f, 0.0f));
    //     scene_->AddEntity(flower);
    // }

    // Build acceleration structures