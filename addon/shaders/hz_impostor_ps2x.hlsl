sampler ATLAS : register(s0);
float4 FOG : register(c0);

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
