sampler ATLAS : register(s0);
float4 FOG : register(c0);
float4 SCREEN : register(c1);

struct PS_INPUT {
	float2 uv    : TEXCOORD0;
	float4 color : COLOR0;
	float  fog   : TEXCOORD1;
	float3 screen : TEXCOORD2;
};

float4 main(PS_INPUT frag) : COLOR {
	float4 tex = tex2D(ATLAS, frag.uv);
	clip(tex.a - 0.5);
	float2 pixel = (frag.screen.xy / frag.screen.z * float2(0.5, -0.5) + 0.5) * SCREEN.xy;
	float noise = frac(52.9829189 * frac(dot(pixel, float2(0.06711056, 0.00583715))));
	clip(frag.color.a - noise - 0.002);
	float3 lit = tex.rgb * frag.color.rgb * 2.0;
	return float4(lerp(lit, FOG.rgb, saturate(frag.fog)), 1.0);
};
