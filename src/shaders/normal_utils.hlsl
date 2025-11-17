// 法线计算函数
#ifndef NORMAL_UTILS_HLSL
#define NORMAL_UTILS_HLSL

// 根据对象空间位置估算法线
float3 EstimateObjectNormal(float3 objectPos) {
	float3 objectNormal;
	
	// 检测平面（y 接近常数）
	if (abs(objectPos.y + 1.0) < 0.15 || abs(objectPos.y) < 0.15 || abs(objectPos.y - 1.0) < 0.15) {
		objectNormal = float3(0, sign(objectPos.y + 0.5), 0);
	}
	// 检测盒子（一个坐标的绝对值接近 1）
	else if (abs(abs(objectPos.x) - 1.0) < 0.15 || abs(abs(objectPos.y) - 1.0) < 0.15 || abs(abs(objectPos.z) - 1.0) < 0.15) {
		float3 absPos = abs(objectPos);
		if (absPos.x > absPos.y && absPos.x > absPos.z) {
			objectNormal = float3(sign(objectPos.x), 0, 0);
		} else if (absPos.y > absPos.z) {
			objectNormal = float3(0, sign(objectPos.y), 0);
		} else {
			objectNormal = float3(0, 0, sign(objectPos.z));
		}
	}
	// 默认：球体或其他凸物体，使用径向法线
	else {
		objectNormal = normalize(objectPos);
	}
	
	return objectNormal;
}

#endif // NORMAL_UTILS_HLSL
