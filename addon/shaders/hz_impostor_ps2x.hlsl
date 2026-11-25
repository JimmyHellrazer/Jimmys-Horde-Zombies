// Horde Zombies - far-zombie impostors, pixel half (see hz_impostor_vs2x.hlsl).
// Atlas texel, cut out by its alpha, times the light at the zombie, faded into the map's fog.
// Compiles to shaders/fxc/hz_impostor_ps20b.vcs
sampler ATLAS : register(s0);
float4 FOG : register(c0);   // $c0_x/y/z = fog colour (0..1)

struct PS_INPUT {
	float2 uv    : TEXCOORD0;
	float4 color : COLOR0;
};

float4 main(PS_INPUT frag) : COLOR {
	float4 tex = tex2D(ATLAS, frag.uv);
	clip(tex.a - 0.5);
	float3 lit = tex.rgb * frag.color.rgb * 2.0;
	return float4(lerp(lit, FOG.rgb, frag.color.a), 1.0);
};
