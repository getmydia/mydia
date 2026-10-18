// Liquid Glass for the floating control layer on iOS and macOS.
//
// Runs in a BackdropFilter nested inside a blur BackdropFilter
// (RenderLiquidGlass), because composing the two shifts the shader's
// coordinates. The input texture is the blurred backdrop under the surface,
// with the surface centred in it.
//
// Effects: refraction with dispersion, adaptive tint (the tint alpha rises
// with the brightest backdrop luma near each pixel), darkened edge, specular rim, inner glow across the
// lit edge band, and a press glow centred on the light.
//
// Refraction maths adapted from liquid_glass_renderer
// (https://github.com/whynotmake-it/flutter_liquid_glass, MIT).
//
// Uniform order is load-bearing: LiquidGlassUniforms.toFloats writes them
// starting at float index 2, after uSize, which the engine sets.

#version 460 core

#include <flutter/runtime_effect.glsl>

precision highp float;

uniform vec2 uSize;        // input texture size, physical px (engine)
uniform vec2 uSurface;     // surface size, physical px
uniform float uRadius;     // corner radius, physical px
uniform float uEdge;       // edge band width, physical px
uniform float uRefraction; // displacement at the rim, physical px
uniform float uDispersion; // red/blue spread, fraction of uRefraction
uniform float uSaturation;
uniform float uBrightness;
uniform float uSpecular;
uniform float uEdgeShade;
uniform float uRimWidth;   // physical px
uniform vec2 uLight;       // light position, 0..1 of the surface
uniform vec4 uTint;        // straight rgba
uniform float uShadeWidth;  // darkened edge width, physical px
uniform float uInnerGlow;   // light across the edge band facing the light
uniform float uAdaptiveMax; // tint alpha over a bright backdrop
uniform float uLumaLow;     // backdrop luma where adaptation starts
uniform float uLumaHigh;    // backdrop luma where it reaches uAdaptiveMax
uniform float uGlow;        // press glow strength
uniform float uGlowRadius;  // press glow radius, fraction of the short side
uniform float uAdaptRadius; // physical px

uniform sampler2D uTexture;

out vec4 fragColor;

float sdRoundRect(vec2 p, vec2 b, float r) {
  vec2 q = abs(p) - b + vec2(r);
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

vec2 sdNormal(vec2 p, vec2 b, float r) {
  vec2 e = vec2(0.5, 0.0);
  vec2 g = vec2(
      sdRoundRect(p + e.xy, b, r) - sdRoundRect(p - e.xy, b, r),
      sdRoundRect(p + e.yx, b, r) - sdRoundRect(p - e.yx, b, r));
  float len = length(g);
  return len > 1e-5 ? g / len : vec2(0.0);
}

vec3 sampleAt(vec2 px) {
  vec2 clamped = clamp(px, vec2(0.5), uSize - vec2(0.5));
  return texture(uTexture, clamped / uSize).rgb;
}

// Brightest luma of the unbent backdrop near this fragment: a 3x3 grid
// uAdaptRadius apart, centred on it. The max, not the mean, so a bright
// patch under a glyph always raises the tint there.
float backdropLuma(vec2 frag) {
  float brightest = 0.0;
  for (int i = -1; i <= 1; i++) {
    for (int j = -1; j <= 1; j++) {
      vec2 offset = vec2(float(i), float(j)) * uAdaptRadius;
      brightest = max(brightest, dot(sampleAt(frag + offset),
                                     vec3(0.2126, 0.7152, 0.0722)));
    }
  }
  return brightest;
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 origin = (uSize - uSurface) * 0.5;
  vec2 halfSize = uSurface * 0.5;
  vec2 p = frag - origin - halfSize;
  float r = min(uRadius, min(halfSize.x, halfSize.y));
  float inside = -sdRoundRect(p, halfSize, r);
  vec2 n = sdNormal(p, halfSize, r);

  // Lens: 1 at the rim; the bend eases quadratically to 0 across the edge band.
  float t = clamp(inside / max(uEdge, 1.0), 0.0, 1.0);
  float lens = (1.0 - t) * (1.0 - t);

  // n points outward; samples are pulled inward, so they stay in the texture.
  vec2 shift = -n * lens * uRefraction;
  vec3 color = vec3(
      sampleAt(frag + shift * (1.0 + uDispersion)).r,
      sampleAt(frag + shift).g,
      sampleAt(frag + shift * (1.0 - uDispersion)).b);

  float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
  color = clamp(mix(vec3(luma), color, uSaturation) + vec3(uBrightness),
                0.0, 1.0);
  // Adaptive tint: the base alpha over dark content, rising to uAdaptiveMax
  // over bright content so the label keeps its contrast (mirrored by
  // liquidAdaptiveAlpha in Dart).
  float adapt = smoothstep(uLumaLow, uLumaHigh, backdropLuma(frag));
  float tintAlpha = mix(uTint.a, max(uAdaptiveMax, uTint.a), adapt);
  color = mix(color, uTint.rgb, tintAlpha);

  // Darkened outer edge.
  float edge = 1.0 - smoothstep(0.0, uShadeWidth, inside);
  color *= 1.0 - uEdgeShade * edge;

  // Specular rim: every edge facing the light is lit (top and left at rest),
  // with a softer counter-highlight on the opposite edges.
  vec2 lightPos = (uLight - vec2(0.5)) * uSurface;
  // Light direction from the centre: every edge facing it is lit, not just
  // the pixels next to the light point.
  vec2 lightDir = normalize(lightPos + vec2(1e-4));
  float facing = dot(n, lightDir);
  float rim = 1.0 - smoothstep(uRimWidth * 0.5, uRimWidth * 1.5, inside);
  float highlight =
      pow(max(facing, 0.0), 2.0) + 0.35 * pow(max(-facing, 0.0), 2.0);
  color += vec3(uSpecular * highlight * rim);

  // Thickness: a soft glow across the edge band on the lit side.
  color += vec3(uInnerGlow * lens * max(facing, 0.0));

  // Press glow centred on the light (the pointer while pressed).
  float glowR = max(uGlowRadius * min(uSurface.x, uSurface.y), 1.0);
  float d = length(p - lightPos) / glowR;
  color += vec3(uGlow * exp(-d * d));

  fragColor = vec4(clamp(color, 0.0, 1.0), 1.0);
}
