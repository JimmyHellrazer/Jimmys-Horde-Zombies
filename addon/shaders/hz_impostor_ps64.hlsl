cbuffer Registers : register(b0) {
	float4 FOG;
	float4 SCREEN;
};

Texture2D ATLAS : register(t0);
SamplerState ATLAS_SAMPLER : register(s0);

struct PS_INPUT {
	float4 pixel : SV_Position;
	float2 uv    : TEXCOORD0;
	float4 color : COLOR0;
	float  fog   : TEXCOORD1;
};

float4 main(PS_INPUT frag) : SV_Target {
	float4 tex = ATLAS.Sample(ATLAS_SAMPLER, frag.uv);
	clip(tex.a - 0.5);
	float noise = frac(52.9829189 * frac(dot(floor(frag.pixel.xy), float2(0.06711056, 0.00583715))));
	clip(frag.color.a - noise - 0.002);
	float3 lit = tex.rgb * frag.color.rgb * 2.0;
	return float4(lerp(lit, FOG.rgb, saturate(frag.fog)), 1.0);
}
