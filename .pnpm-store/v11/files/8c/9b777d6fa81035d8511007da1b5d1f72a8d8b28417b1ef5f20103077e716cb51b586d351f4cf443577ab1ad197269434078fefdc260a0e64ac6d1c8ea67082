import { GraphQLSchema } from 'graphql';
import { GraphQLConfig } from 'graphql-config';
import { Profiler, Types } from '@graphql-codegen/plugin-helpers';
import type { UnnormalizedTypeDefPointer } from '@graphql-tools/load';
export type CodegenConfig = Types.Config;
export type YamlCliFlags = {
    config: string;
    watch: boolean | string | string[];
    require: string[];
    overwrite: boolean;
    project: string;
    silent: boolean;
    errorsOnly: boolean;
    profile: boolean;
    check?: boolean;
    verbose?: boolean;
    debug?: boolean;
    ignoreNoDocuments?: boolean;
    emitLegacyCommonJSImports?: boolean;
    importExtension?: '' | `.${string}`;
};
export declare function generateSearchPlaces(moduleName: string): string[];
export type CodegenConfigLoader = (filepath: string, content: string) => Promise<Types.Config> | Types.Config;
export interface LoadCodegenConfigOptions {
    /**
     * The path to the config file or directory contains the config file.
     * @default process.cwd()
     */
    configFilePath?: string;
    /**
     * The name of the config file
     * @default codegen
     */
    moduleName?: string;
    /**
     * Additional search paths for the config file you want to check
     */
    searchPlaces?: string[];
    /**
     * @default codegen
     */
    packageProp?: string;
    /**
     * Overrides or extends the loaders for specific file extensions
     */
    loaders?: Record<string, CodegenConfigLoader>;
}
export interface LoadCodegenConfigResult {
    filepath: string;
    config: Types.Config;
    isEmpty?: boolean;
}
export declare function loadCodegenConfig({ configFilePath, moduleName, searchPlaces: additionalSearchPlaces, packageProp, loaders: customLoaders, }: LoadCodegenConfigOptions): Promise<LoadCodegenConfigResult>;
export declare function loadContext(configFilePath?: string): Promise<CodegenContext> | never;
export declare function buildOptions(): {
    c: {
        alias: string;
        type: "string";
        describe: string;
    };
    w: {
        alias: string;
        describe: string;
        coerce(watch: any): string | boolean | any[];
    };
    r: {
        alias: string;
        describe: string;
        type: "array";
        default: any[];
    };
    o: {
        alias: string;
        describe: string;
        type: "boolean";
    };
    s: {
        alias: string;
        describe: string;
        type: "boolean";
    };
    e: {
        alias: string;
        describe: string;
        type: "boolean";
    };
    profile: {
        describe: string;
        type: "boolean";
    };
    p: {
        alias: string;
        describe: string;
        type: "string";
    };
    v: {
        alias: string;
        describe: string;
        type: "boolean";
        default: boolean;
    };
    d: {
        alias: string;
        describe: string;
        type: "boolean";
        default: boolean;
    };
    'emit-legacy-common-js-imports': {
        describe: string;
        type: "boolean";
    };
    'import-extension': {
        describe: string;
        type: "string";
    };
    'ignore-no-documents': {
        describe: string;
        type: "boolean";
    };
};
export declare function parseArgv(argv?: string[]): YamlCliFlags;
export declare function createContext(cliFlags?: YamlCliFlags): Promise<CodegenContext>;
export declare function updateContextWithCliFlags(context: CodegenContext, cliFlags: YamlCliFlags): void;
export declare class CodegenContext {
    private _config;
    private _graphqlConfig?;
    private config;
    private _project?;
    private _checkMode;
    private _pluginContext;
    cwd: string;
    filepath: string;
    profiler: Profiler;
    profilerOutput?: string;
    checkModeStaleFiles: any[];
    constructor({ config, graphqlConfig, filepath, }: {
        config?: Types.Config;
        graphqlConfig?: GraphQLConfig;
        filepath?: string;
    });
    useProject(name?: string): void;
    getConfig<T>(extraConfig?: T): T & Types.Config;
    updateConfig(config: Partial<Types.Config>): void;
    enableCheckMode(): void;
    get checkMode(): boolean;
    useProfiler(): void;
    getPluginContext(): {
        [key: string]: any;
    };
    loadSchema(pointer: Types.Schema | Types.Schema[]): Promise<GraphQLSchema>;
    loadDocuments(pointer: UnnormalizedTypeDefPointer, type: 'standard' | 'external'): Promise<Types.DocumentFile[]>;
}
export declare function ensureContext(input: CodegenContext | Types.Config): CodegenContext;
