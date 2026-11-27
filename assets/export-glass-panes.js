const fs = require("fs");
const path = require("path");
const { chromium } = require("@playwright/test");

/**
 * Renders the still glass panes fanned out on the website's homepage.
 *
 *   node export-glass-panes.js
 *
 * Each pane is one frame of site/src/lib/glass.frag compiled with PANE
 * defined, drawn in headless Chromium and saved as
 * site/src/assets/glass/pane-N.jpg. The seeds below pick which part of the
 * flow each pane shows; change one and re-run to get a different pane.
 *
 * Playwright's bundled Chromium cannot start on NixOS. Point at the system
 * browser there: CHROME_PATH=$(readlink -f $(which chromium)).
 */

const WIDTH = 480;
const HEIGHT = 720;
const SECONDS = 9;
const SEEDS = [1.7, 6.1, 11.4];
const SHADER = path.join(__dirname, "../site/src/lib/glass.frag");
const OUTPUT_DIR = process.env.GLASS_OUTPUT_DIR || path.join(__dirname, "../site/src/assets/glass");

function renderPane({ fragment, width, height, seconds, seed }) {
  const canvas = Object.assign(document.createElement("canvas"), { width, height });
  const gl = canvas.getContext("webgl", { preserveDrawingBuffer: true });
  if (!gl) throw new Error("WebGL is unavailable in this browser");
  const prog = gl.createProgram();
  const sources = [
    [gl.VERTEX_SHADER, "attribute vec2 p;void main(){gl_Position=vec4(p,0.,1.);}"],
    [gl.FRAGMENT_SHADER, fragment],
  ];
  for (const [type, source] of sources) {
    const shader = gl.createShader(type);
    gl.shaderSource(shader, source);
    gl.compileShader(shader);
    if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(shader));
    gl.attachShader(prog, shader);
  }
  gl.linkProgram(prog);
  if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(prog));
  gl.useProgram(prog);
  gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
  const position = gl.getAttribLocation(prog, "p");
  gl.enableVertexAttribArray(position);
  gl.vertexAttribPointer(position, 2, gl.FLOAT, false, 0, 0);
  gl.viewport(0, 0, width, height);
  gl.uniform2f(gl.getUniformLocation(prog, "r"), width, height);
  gl.uniform1f(gl.getUniformLocation(prog, "t"), seconds);
  gl.uniform1f(gl.getUniformLocation(prog, "s"), seed);
  gl.drawArrays(gl.TRIANGLES, 0, 3);
  return canvas.toDataURL("image/jpeg", 0.9);
}

async function exportGlassPanes() {
  const fragment = `#define PANE\n${fs.readFileSync(SHADER, "utf8")}`;
  const browser = await chromium.launch({
    executablePath: process.env.CHROME_PATH || undefined,
    // Software GL, so the panes come out the same with or without a GPU.
    args: ["--use-gl=angle", "--use-angle=swiftshader", "--enable-unsafe-swiftshader"],
  });
  try {
    const page = await browser.newPage();
    fs.mkdirSync(OUTPUT_DIR, { recursive: true });
    for (const [index, seed] of SEEDS.entries()) {
      const dataUrl = await page.evaluate(renderPane, {
        fragment,
        width: WIDTH,
        height: HEIGHT,
        seconds: SECONDS,
        seed,
      });
      const file = path.join(OUTPUT_DIR, `pane-${index + 1}.jpg`);
      fs.writeFileSync(file, Buffer.from(dataUrl.split(",")[1], "base64"));
      console.log(`  ✓ ${file}`);
    }
  } finally {
    await browser.close();
  }
}

exportGlassPanes().catch((error) => {
  console.error(error);
  process.exit(1);
});
