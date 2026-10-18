// Liquid Glass for the floating control layer on iOS and macOS.
//
// Runs as ImageFilter.shader composed over a blur inside a BackdropFilter
// (RenderLiquidGlass). The input texture is the blurred backdrop under the
// surface; the surface is centred in it (any blur margin is symmetric).
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

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 origin = (uSize - uSurface) * 0.5;
  vec2 halfSize = uSurface * 0.5;
  vec2 p = frag - origin - halfSize;
  float r = min(uRadius, min(halfSize.x, halfSize.y));
  float inside = -sdRoundRect(p, halfSize, r);
  vec2 n = sdNormal(p, halfSize, r);

  // Lens: 1 at the rim, easing to 0 across the edge band (circular profile).
  float t = clamp(inside / max(uEdge, 1.0), 0.0, 1.0);
  float lens = 1.0 - sqrt(max(0.0, 1.0 - (1.0 - t) * (1.0 - t)));

  // n points outward; samples are pulled inward, so they stay in the texture.
  vec2 shift = -n * lens * uRefraction;
  vec3 color = vec3(
      sampleAt(frag + shift * (1.0 + uDispersion)).r,
      sampleAt(frag + shift).g,
      sampleAt(frag + shift * (1.0 - uDispersion)).b);

  float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
  color = clamp(mix(vec3(luma), color, uSaturation) + vec3(uBrightness),
                0.0, 1.0);
  color = mix(color, uTint.rgb, uTint.a);

  // Darkened outer edge.
  float edge = 1.0 - smoothstep(0.0, uRimWidth * 3.0, inside);
  color *= 1.0 - uEdgeShade * edge;

  // Specular rim: brightest where the edge faces the light, with a softer
  // counter-highlight on the opposite side.
  vec2 lightPos = (uLight - vec2(0.5)) * uSurface;
  vec2 toLight = normalize(lightPos - p + vec2(1e-4));
  float facing = dot(n, toLight);
  float rim = 1.0 - smoothstep(uRimWidth * 0.5, uRimWidth * 1.5, inside);
  float highlight =
      pow(max(facing, 0.0), 2.0) + 0.35 * pow(max(-facing, 0.0), 2.0);
  color += vec3(uSpecular * highlight * rim);

  fragColor = vec4(clamp(color, 0.0, 1.0), 1.0);
}
