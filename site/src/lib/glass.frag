// The website's glass shader. Drawn live behind the heroes by
// src/scripts/glass-wall.ts (a tilted floor of glass panes), and once, with
// PANE defined, by assets/export-glass-panes.js for the still panes on the
// homepage.
#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#else
precision mediump float;
#endif

uniform vec2 r;  // canvas size in pixels
uniform float t; // seconds
uniform vec3 m;  // pointer: xy in the same space as uv, z is 0..1 presence
uniform float s; // seed, offsets the flow (PANE only)

float hash(vec2 p) {
  return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
  vec2 i = floor(p), f = fract(p);
  f = f * f * (3. - 2. * f);
  return mix(
    mix(hash(i), hash(i + vec2(1., 0.)), f.x),
    mix(hash(i + vec2(0., 1.)), hash(i + vec2(1., 1.)), f.x),
    f.y
  );
}

float fbm(vec2 p) {
  float a = .5, sum = 0.;
  for (int i = 0; i < 5; i++) {
    sum += a * noise(p);
    p = p * 2.03 + vec2(1.7, 9.2);
    a *= .5;
  }
  return sum;
}

// Domain-warped flow: the liquid inside the glass.
float field(vec2 uv, out vec2 w) {
  vec2 q = vec2(fbm(uv + t * .035), fbm(uv + vec2(5.2, 1.3) - t * .03));
  w = vec2(
    fbm(uv + 3. * q + vec2(1.7, 9.2) + t * .02),
    fbm(uv + 3. * q + vec2(8.3, 2.8) - t * .025)
  );
  return fbm(uv + 3.5 * w);
}

// Near-black through the site's primary indigo to violet, with cyan streaks.
vec3 palette(float f, vec2 w) {
  vec3 c = mix(vec3(.05, .05, .13), vec3(.39, .4, .95), smoothstep(.25, .8, f));
  c = mix(c, vec3(.66, .33, .97), smoothstep(.55, 1.15, length(w)) * .75);
  return mix(c, vec3(.13, .83, .93), pow(w.y, 3.) * .55);
}

#ifdef PANE

// One pane, close up: the flow with a surface normal for specular highlights.
void main() {
  vec2 uv = (gl_FragCoord.xy - .5 * r) / r.y * .75 + s;
  vec2 w, w2;
  float f = field(uv, w);
  float e = .012;
  float fx = field(uv + vec2(e, 0.), w2) - f;
  float fy = field(uv + vec2(0., e), w2) - f;
  vec3 nrm = normalize(vec3(-fx, -fy, e * 1.6));
  float spec = pow(max(dot(nrm, normalize(vec3(.45, .6, .65))), 0.), 28.);
  vec3 c = palette(f, w) * (.55 + .6 * nrm.z) * 1.15;
  gl_FragColor = vec4(c + spec * vec3(.9, .92, 1.) * .75, 1.);
}

#else

// Screen point to floor coordinates. The camera leans a little toward the
// pointer, so the same function must map both the pixel and the pointer.
vec2 project(vec2 uv, out float dist) {
  // uv is in canvas heights, so a tall phone canvas would show only a few
  // huge panes. Widen the view there.
  float zoom = mix(1.7, 1., smoothstep(.6, 1.5, r.x / r.y));
  vec3 d = vec3(uv * zoom, 1.25);
  float pitch = .75 - m.y * m.z * .07, yaw = .42 + m.x * m.z * .09;
  float cp = cos(pitch), sp = sin(pitch);
  d = vec3(d.x, d.y * cp - d.z * sp, d.y * sp + d.z * cp);
  dist = -1.6 / d.y;
  vec2 pc = d.xz * dist;
  float cy = cos(yaw), sy = sin(yaw);
  pc = vec2(pc.x * cy - pc.y * sy, pc.x * sy + pc.y * cy);
  pc.y += t * .1;
  return pc * 1.25;
}

// A cell's id and the position inside it. Cells are 2:3, like a poster.
vec2 cell(vec2 pc, out vec2 inside) {
  vec2 g = pc * vec2(1.5, 1.);
  inside = (fract(g) - .5) * vec2(.6667, 1.);
  return floor(g);
}

void main() {
  vec2 uv = (gl_FragCoord.xy - .5 * r) / r.y;
  float dist, pointerDist;
  vec2 pc = project(uv, dist);
  vec2 pointer = project(m.xy, pointerDist);
  vec2 fp, fm;
  vec2 id = cell(pc, fp);
  vec2 pointerId = cell(pointer, fm);
  // 1 on the pane under the pointer.
  float hover = m.z * step(abs(id.x - pointerId.x) + abs(id.y - pointerId.y), .5);

  // Rounded-rectangle distance: negative inside the pane, positive in the gap.
  vec2 q = abs(fp) - (vec2(.3333, .5) - .09);
  float sd = length(max(q, 0.)) + min(max(q.x, q.y), 0.) - .05;
  float aa = dist * .006;
  float mask = smoothstep(aa, -aa, sd);

  // Each pane refracts its own slice of the flow.
  vec2 w;
  vec3 c = palette(field(id * .37 + fp * .9 + 3., w), w) * 1.15;
  c += smoothstep(-.07, -.005, sd) * (.2 + hover * .55) * vec3(.8, .86, 1.); // bevelled rim
  c += .12 * smoothstep(.05, 0., abs(fp.x + fp.y * .5 - .08));               // resting glare
  c *= .6 + .9 * pow(.5 + .5 * sin(t * .7 + hash(id) * 6.283), 10.);         // now and then, a pane lights up
  vec2 away = pc - pointer;
  c *= 1. + m.z * .9 * exp(-dot(away, away) * .55);                          // glow near the pointer
  c *= 1. + hover * .45;
  c += hover * .5 * smoothstep(.16, 0., abs((fp.x + fp.y * .5) - (fm.x + fm.y * .5))) * vec3(.85, .9, 1.); // glare follows the pointer

  float fog = exp(-dist * .13);
  gl_FragColor = vec4(mix(vec3(.03, .035, .065), c, mask) * fog + (1. - fog) * vec3(.07, .07, .15), 1.);
}

#endif
