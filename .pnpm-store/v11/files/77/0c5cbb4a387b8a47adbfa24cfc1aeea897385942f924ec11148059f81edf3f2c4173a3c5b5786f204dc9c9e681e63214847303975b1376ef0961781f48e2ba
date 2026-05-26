"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
Object.defineProperty(exports, "__esModule", { value: true });
exports.runCli = runCli;
exports.ensureGraphQlPackage = ensureGraphQlPackage;
const config_js_1 = require("./config.js");
const generate_and_save_js_1 = require("./generate-and-save.js");
const hooks_js_1 = require("./hooks.js");
const index_js_1 = require("./init/index.js");
async function runCli(cmd) {
    await ensureGraphQlPackage();
    if (cmd === 'init') {
        await (0, index_js_1.init)();
        return 0;
    }
    const context = await (0, config_js_1.createContext)();
    try {
        await (0, generate_and_save_js_1.generate)(context);
        if (context.checkMode && context.checkModeStaleFiles.length > 0) {
            // eslint-disable-next-line no-console
            console.log(`The following stale files were detected:\n${context.checkModeStaleFiles.map(file => `  - ${file}\n`)}`);
            return 1;
        }
        return 0;
    }
    catch (error) {
        await (0, hooks_js_1.lifecycleHooks)(context.getConfig().hooks).onError(error.toString());
        return 1;
    }
}
async function ensureGraphQlPackage() {
    try {
        await Promise.resolve().then(() => __importStar(require('graphql')));
    }
    catch {
        throw new Error(`Unable to load "graphql" package. Please make sure to install "graphql" as a dependency! \n
       To install "graphql", run:
         yarn add graphql
       Or, with NPM:
         npm install --save graphql`);
    }
}
