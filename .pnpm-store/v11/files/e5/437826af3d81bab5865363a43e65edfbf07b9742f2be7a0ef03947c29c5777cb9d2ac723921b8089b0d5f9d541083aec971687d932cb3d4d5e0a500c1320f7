import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { exactRegex } from "@rolldown/pluginutils";
import { transform } from "@swc/core";
import * as vite from "vite";
//#region ../common/refresh-utils.ts
const runtimePublicPath = "/@react-refresh";
const reactCompRE = /extends\s+(?:React\.)?(?:Pure)?Component/;
const refreshContentRE = /\$RefreshReg\$\(/;
const preambleCode = `import { injectIntoGlobalHook } from "__BASE__${runtimePublicPath.slice(1)}";
injectIntoGlobalHook(window);
window.$RefreshReg$ = () => {};
window.$RefreshSig$ = () => (type) => type;`;
const getPreambleCode = (base) => preambleCode.replace("__BASE__", base);
function addRefreshWrapper(code, pluginName, id, reactRefreshHost = "") {
	const hasRefresh = refreshContentRE.test(code);
	const onlyReactComp = !hasRefresh && reactCompRE.test(code);
	if (!hasRefresh && !onlyReactComp) return void 0;
	let newCode = code;
	newCode += `

import * as RefreshRuntime from "${reactRefreshHost}${runtimePublicPath}";
const inWebWorker = typeof WorkerGlobalScope !== 'undefined' && self instanceof WorkerGlobalScope;
if (import.meta.hot && !inWebWorker) {
  if (!window.$RefreshReg$) {
    throw new Error(
      "${pluginName} can't detect preamble. Something is wrong."
    );
  }

  RefreshRuntime.__hmr_import(import.meta.url).then((currentExports) => {
    RefreshRuntime.registerExportsForReactRefresh(${JSON.stringify(id)}, currentExports);
    import.meta.hot.accept((nextExports) => {
      if (!nextExports) return;
      const invalidateMessage = RefreshRuntime.validateRefreshBoundaryAndEnqueueUpdate(${JSON.stringify(id)}, currentExports, nextExports);
      if (invalidateMessage) import.meta.hot.invalidate(invalidateMessage);
    });
  });
}
`;
	if (hasRefresh) newCode += `function $RefreshReg$(type, id) { return RefreshRuntime.register(type, ${JSON.stringify(id)} + ' ' + id) }
function $RefreshSig$() { return RefreshRuntime.createSignatureFunctionForTransform(); }
`;
	return newCode;
}
function virtualPreamblePlugin({ name, isEnabled }) {
	return {
		name: "vite:react-virtual-preamble",
		resolveId: {
			order: "pre",
			filter: { id: exactRegex(name) },
			handler(source) {
				if (source === name) return "\0" + source;
			}
		},
		load: {
			filter: { id: exactRegex("\0" + name) },
			handler(id) {
				if (id === "\0" + name) {
					if (isEnabled()) return preambleCode.replace("__BASE__", "/");
					return "";
				}
			}
		}
	};
}
//#endregion
//#region ../common/warning.ts
const silenceUseClientWarning = (userConfig) => ({ rollupOptions: { onwarn(warning, defaultHandler) {
	if (warning.code === "MODULE_LEVEL_DIRECTIVE" && (warning.message.includes("use client") || warning.message.includes("use server"))) return;
	if (warning.code === "SOURCEMAP_ERROR" && warning.message.includes("resolve original location") && warning.pos === 0) return;
	if (userConfig.build?.rollupOptions?.onwarn) userConfig.build.rollupOptions.onwarn(warning, defaultHandler);
	else defaultHandler(warning);
} } });
//#endregion
//#region src/index.ts
const resolve = createRequire(import.meta.url).resolve;
const usingRolldown = "rolldownVersion" in vite;
const react = (_options) => {
	let hmrDisabled = true;
	let viteCacheRoot;
	const options = {
		jsxImportSource: _options?.jsxImportSource ?? "react",
		tsDecorators: _options?.tsDecorators,
		plugins: _options?.plugins ? _options?.plugins.map((el) => [resolve(el[0]), el[1]]) : void 0,
		devTarget: _options?.devTarget ?? "es2020",
		parserConfig: _options?.parserConfig,
		reactRefreshHost: _options?.reactRefreshHost,
		useAtYourOwnRisk_mutateSwcOptions: _options?.useAtYourOwnRisk_mutateSwcOptions,
		disableOxcRecommendation: _options?.disableOxcRecommendation
	};
	return [
		{
			name: "vite:react-swc:resolve-runtime",
			apply: "serve",
			enforce: "pre",
			resolveId: {
				filter: { id: exactRegex(runtimePublicPath) },
				handler: (id) => id === "/@react-refresh" ? id : void 0
			},
			load: {
				filter: { id: exactRegex(runtimePublicPath) },
				handler: (id) => id === "/@react-refresh" ? readFileSync(join(import.meta.dirname, "refresh-runtime.js"), "utf-8").replace(/__README_URL__/g, "https://github.com/vitejs/vite-plugin-react/tree/main/packages/plugin-react-swc") : void 0
			}
		},
		{
			name: "vite:react-swc",
			apply: "serve",
			config: () => {
				if (usingRolldown) return {
					oxc: false,
					optimizeDeps: {
						include: [`${options.jsxImportSource}/jsx-dev-runtime`],
						rolldownOptions: { transform: { jsx: { runtime: "automatic" } } }
					}
				};
				else return {
					esbuild: false,
					optimizeDeps: {
						include: [`${options.jsxImportSource}/jsx-dev-runtime`],
						esbuildOptions: { jsx: "automatic" }
					}
				};
			},
			configResolved(config) {
				viteCacheRoot = config.cacheDir;
				hmrDisabled = config.server.hmr === false;
				const mdxIndex = config.plugins.findIndex((p) => p.name === "@mdx-js/rollup");
				if (mdxIndex !== -1 && mdxIndex > config.plugins.findIndex((p) => p.name === "vite:react-swc")) throw new Error("[vite:react-swc] The MDX plugin should be placed before this plugin");
				if (usingRolldown && !options.plugins && !options.useAtYourOwnRisk_mutateSwcOptions && !options.disableOxcRecommendation) config.logger.warn("[vite:react-swc] We recommend switching to `@vitejs/plugin-react` for improved performance as no swc plugins are used. More information at https://vite.dev/rolldown");
			},
			transformIndexHtml: (_, config) => {
				if (!hmrDisabled) return [{
					tag: "script",
					attrs: { type: "module" },
					children: getPreambleCode(config.server.config.base)
				}];
			},
			async transform(code, _id, transformOptions) {
				const id = _id.split("?")[0];
				const refresh = !transformOptions?.ssr && !hmrDisabled;
				const result = await transformWithOptions(id, code, options.devTarget, options, viteCacheRoot, {
					refresh,
					development: true,
					runtime: "automatic",
					importSource: options.jsxImportSource
				});
				if (!result) return;
				if (!refresh) return result;
				return {
					code: addRefreshWrapper(result.code, "@vitejs/plugin-react-swc", id, options.reactRefreshHost) ?? result.code,
					map: result.map
				};
			}
		},
		options.plugins || options.useAtYourOwnRisk_mutateSwcOptions ? {
			name: "vite:react-swc",
			apply: "build",
			enforce: "pre",
			config: (userConfig) => ({ build: silenceUseClientWarning(userConfig) }),
			configResolved(config) {
				viteCacheRoot = config.cacheDir;
			},
			transform: (code, _id) => transformWithOptions(_id.split("?")[0], code, "esnext", options, viteCacheRoot, {
				runtime: "automatic",
				importSource: options.jsxImportSource
			})
		} : {
			name: "vite:react-swc",
			apply: "build",
			config: (userConfig) => {
				if (usingRolldown) return {
					build: silenceUseClientWarning(userConfig),
					oxc: { jsx: {
						runtime: "automatic",
						importSource: options.jsxImportSource
					} }
				};
				else return {
					build: silenceUseClientWarning(userConfig),
					esbuild: {
						jsx: "automatic",
						jsxImportSource: options.jsxImportSource,
						tsconfigRaw: { compilerOptions: { useDefineForClassFields: true } }
					}
				};
			},
			configResolved(config) {
				viteCacheRoot = config.cacheDir;
			}
		},
		virtualPreamblePlugin({
			name: "@vitejs/plugin-react-swc/preamble",
			isEnabled: () => !hmrDisabled
		})
	];
};
const transformWithOptions = async (id, code, target, options, viteCacheRoot, reactConfig) => {
	const decorators = options?.tsDecorators ?? false;
	const parser = options.parserConfig ? options.parserConfig(id) : id.endsWith(".tsx") ? {
		syntax: "typescript",
		tsx: true,
		decorators
	} : id.endsWith(".ts") || id.endsWith(".mts") ? {
		syntax: "typescript",
		tsx: false,
		decorators
	} : id.endsWith(".jsx") ? {
		syntax: "ecmascript",
		jsx: true
	} : id.endsWith(".mdx") ? {
		syntax: "ecmascript",
		jsx: true
	} : void 0;
	if (!parser) return;
	let result;
	try {
		const swcOptions = {
			filename: id,
			swcrc: false,
			configFile: false,
			sourceMaps: true,
			jsc: {
				target,
				parser,
				experimental: {
					plugins: options.plugins,
					cacheRoot: join(viteCacheRoot ?? "node_modules/.vite", ".swc")
				},
				transform: {
					useDefineForClassFields: true,
					react: reactConfig
				}
			}
		};
		if (options.useAtYourOwnRisk_mutateSwcOptions) options.useAtYourOwnRisk_mutateSwcOptions(swcOptions);
		result = await transform(code, swcOptions);
	} catch (e) {
		const message = e.message;
		const fileStartIndex = message.indexOf("╭─[");
		if (fileStartIndex !== -1) {
			const match = message.slice(fileStartIndex).match(/:(\d+):(\d+)\]/);
			if (match) {
				e.line = match[1];
				e.column = match[2];
			}
		}
		throw e;
	}
	return result;
};
function pluginForCjs(options) {
	return react.call(this, options);
}
Object.assign(pluginForCjs, { default: pluginForCjs });
//#endregion
export { react as default, pluginForCjs as "module.exports" };
