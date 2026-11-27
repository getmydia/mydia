import fragment from '../lib/glass.frag?raw';

// One oversized triangle covers the canvas.
const VERTEX = 'attribute vec2 p;void main(){gl_Position=vec4(p,0.,1.);}';
const TRIANGLE = new Float32Array([-1, -1, 3, -1, -1, 3]);

// The flow is soft, so the wall renders below native resolution.
const RESOLUTION = 0.8;
const MAX_PIXEL_RATIO = 2;
// Share of the remaining distance the pointer covers each frame.
const POINTER_EASE = 0.12;
// The frame drawn once when the visitor asks for reduced motion.
const STILL_SECONDS = 9;

function program(gl: WebGLRenderingContext): WebGLProgram | null {
  const prog = gl.createProgram();
  for (const [type, source] of [
    [gl.VERTEX_SHADER, VERTEX],
    [gl.FRAGMENT_SHADER, fragment],
  ] as const) {
    const shader = gl.createShader(type);
    if (!shader) return null;
    gl.shaderSource(shader, source);
    gl.compileShader(shader);
    gl.attachShader(prog, shader);
  }
  gl.linkProgram(prog);
  return gl.getProgramParameter(prog, gl.LINK_STATUS) ? prog : null;
}

/**
 * Draws the glass wall on `canvas`. Without WebGL it does nothing and the CSS
 * gradient behind the canvas stays. The loop only runs while the canvas is on
 * screen, and a visitor who prefers reduced motion gets a single still frame
 * with no pointer response.
 */
export function mountGlassWall(canvas: HTMLCanvasElement): void {
  const gl = canvas.getContext('webgl', { antialias: false, powerPreference: 'low-power' });
  const prog = gl && program(gl);
  if (!gl || !prog) return;

  gl.useProgram(prog);
  gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
  gl.bufferData(gl.ARRAY_BUFFER, TRIANGLE, gl.STATIC_DRAW);
  const position = gl.getAttribLocation(prog, 'p');
  gl.enableVertexAttribArray(position);
  gl.vertexAttribPointer(position, 2, gl.FLOAT, false, 0, 0);
  const size = gl.getUniformLocation(prog, 'r');
  const time = gl.getUniformLocation(prog, 't');
  const pointer = gl.getUniformLocation(prog, 'm');

  const still = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const current = [0, 0, 0];
  let target = [0, 0, 0];
  let frame = 0;

  const draw = (seconds: number) => {
    current.forEach((value, i) => (current[i] = value + (target[i] - value) * POINTER_EASE));
    gl.viewport(0, 0, canvas.width, canvas.height);
    gl.uniform2f(size, canvas.width, canvas.height);
    gl.uniform1f(time, seconds);
    gl.uniform3f(pointer, current[0], current[1], current[2]);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
    canvas.dataset.glassReady = '';
  };

  const tick = (now: number) => {
    draw(now / 1000);
    frame = requestAnimationFrame(tick);
  };

  new ResizeObserver(() => {
    const scale = Math.min(devicePixelRatio || 1, MAX_PIXEL_RATIO) * RESOLUTION;
    canvas.width = Math.max(2, Math.round(canvas.clientWidth * scale));
    canvas.height = Math.max(2, Math.round(canvas.clientHeight * scale));
    if (still) draw(STILL_SECONDS);
  }).observe(canvas);

  if (still) return;

  new IntersectionObserver(([entry]) => {
    cancelAnimationFrame(frame);
    if (entry.isIntersecting) frame = requestAnimationFrame(tick);
  }).observe(canvas);

  // The canvas sits behind the hero copy, so it never receives pointer events
  // itself. Touch is ignored: a scrolling finger is not pointing at anything.
  addEventListener(
    'pointermove',
    (event) => {
      if (event.pointerType !== 'mouse') return;
      const box = canvas.getBoundingClientRect();
      const x = event.clientX - box.left;
      const y = event.clientY - box.top;
      const inside = x >= 0 && y >= 0 && x <= box.width && y <= box.height;
      target = inside
        ? [(x - box.width / 2) / box.height, (box.height / 2 - y) / box.height, 1]
        : [target[0], target[1], 0];
    },
    { passive: true },
  );
}
