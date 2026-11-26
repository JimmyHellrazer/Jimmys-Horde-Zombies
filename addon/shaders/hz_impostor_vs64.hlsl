cbuffer Registers : register(b0) {
	float4 r[232];
};

struct VS_INPUT {
	float3 vPos   : POSITION;
	float4 vColor : COLOR0;
	float2 vUV    : TEXCOORD0;
	float2 vVel   : TEXCOORD1;
	float2 vAnim  : TEXCOORD2;
};

struct VS_OUTPUT {
	float4 proj_pos : SV_Position;
	float2 uv       : TEXCOORD0;
	float4 color    : COLOR0;
	float  fog      : TEXCOORD1;
};

#define MODEL_VIEW_PROJ 4
#define AMBIENT_X 21
#define CELL_U 0.03125

VS_OUTPUT main(VS_INPUT vert) {
	float3 world_pos = vert.vPos;

	float since = r[AMBIENT_X].x;
	float clock = r[AMBIENT_X].y;

	world_pos.xy += vert.vVel * since;

	float frame = floor(frac(clock * vert.vAnim.y + vert.vAnim.x) * 8.0);

	float4 world = float4(world_pos, 1);
	VS_OUTPUT o = (VS_OUTPUT)0;
	o.proj_pos = float4(dot(world, r[MODEL_VIEW_PROJ]), dot(world, r[MODEL_VIEW_PROJ + 1]),
		dot(world, r[MODEL_VIEW_PROJ + 2]), dot(world, r[MODEL_VIEW_PROJ + 3]));
	o.uv = float2(vert.vUV.x + frame * CELL_U, vert.vUV.y);
	o.color = vert.vColor;
	float fog_end = r[AMBIENT_X + 1].x;
	float fog_range = max(r[AMBIENT_X + 1].y, 1.0);
	float fog_max = r[AMBIENT_X + 1].z;
	o.fog = min(1.0 - saturate((fog_end - o.proj_pos.w) / fog_range), fog_max) * r[AMBIENT_X].z;
	return o;
}
