#include "common_vs_fxc.h"

struct VS_INPUT {
	float4 vPos   : POSITION;
	float4 vColor : COLOR0;
	float2 vUV    : TEXCOORD0;
	float2 vVel   : TEXCOORD1;
	float2 vAnim  : TEXCOORD2;
};

struct VS_OUTPUT {
	float4 proj_pos : POSITION;
	float2 uv       : TEXCOORD0;
	float4 color    : COLOR0;
	float  fog      : TEXCOORD1;
};

#define CELL_U 0.03125

VS_OUTPUT main(VS_INPUT vert) {
	float3 world_pos;
	SkinPosition(0, vert.vPos, 0, 0, world_pos);

	float since = cAmbientCubeX[0].x;
	float clock = cAmbientCubeX[0].y;

	world_pos.xy += vert.vVel * since;

	float frame = floor(frac(clock * vert.vAnim.y + vert.vAnim.x) * 8.0);

	VS_OUTPUT o = (VS_OUTPUT)0;
	o.proj_pos = mul(float4(world_pos, 1), cViewProj);
	o.uv = float2(vert.vUV.x + frame * CELL_U, vert.vUV.y);
	o.color = vert.vColor;
	float fog_end = cAmbientCubeX[1].x;
	float fog_range = max(cAmbientCubeX[1].y, 1.0);
	float fog_max = cAmbientCubeX[1].z;
	o.fog = min(1.0 - saturate((fog_end - o.proj_pos.w) / fog_range), fog_max) * cAmbientCubeX[0].z;
	return o;
};
