// Horde Zombies - far-zombie impostors (see lua/hordez/cl_impostor.lua).
// Each far zombie is one camera-facing quad whose corners Lua places a few times a second. Between those
// rebuilds this shader keeps it moving (position + velocity * time since the build) and animating (which of
// the 8 flipbook frames in the atlas it shows), so a thousand of them cost no Lua per frame.
//
// Compile with ShaderCompile (github.com/meetric1/gmod_shader_guide, shaders/build_single_shader.bat) into
// shaders/fxc/hz_impostor_vs20.vcs
#include "common_vs_fxc.h"

struct VS_INPUT {
	float4 vPos   : POSITION;    // corner, world space, where it was when the mesh was built
	float4 vColor : COLOR0;      // rgb = light at the zombie (half scale: 0.5 = full), a = fog amount
	float2 vUV    : TEXCOORD0;   // atlas coordinate of this corner in flipbook frame 0
	float2 vVel   : TEXCOORD1;   // the zombie's ground velocity, units / second
	float2 vAnim  : TEXCOORD2;   // x = animation phase 0..1, y = flipbook cycles per second
};

struct VS_OUTPUT {
	float4 proj_pos : POSITION;
	float2 uv       : TEXCOORD0;
	float4 color    : COLOR0;
};

// width of one atlas cell (the atlas is 32 cells across; a flipbook strip is 8 cells)
#define CELL_U 0.03125

VS_OUTPUT main(VS_INPUT vert) {
	float3 world_pos;
	SkinPosition(0, vert.vPos, 0, 0, world_pos);

	// Lua passes these through the front face of the ambient cube (render.SetModelLighting(0, ...)):
	// x = seconds since the mesh was built, y = animation clock
	float since = cAmbientCubeX[0].x;
	float clock = cAmbientCubeX[0].y;

	world_pos.xy += vert.vVel * since;

	float frame = floor(frac(clock * vert.vAnim.y + vert.vAnim.x) * 8.0);

	VS_OUTPUT o = (VS_OUTPUT)0;
	o.proj_pos = mul(float4(world_pos, 1), cViewProj);
	o.uv = float2(vert.vUV.x + frame * CELL_U, vert.vUV.y);
	o.color = vert.vColor;
	return o;
};
