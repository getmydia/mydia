import { Types } from '@graphql-codegen/plugin-helpers';
import { CodegenContext } from './config.js';
export declare function generate(input: CodegenContext | (Types.Config & {
    cwd?: string;
}), saveToFile?: boolean): Promise<Types.FileOutput[]
/**
 * When this function runs in watch mode, it'd return an empty promise that doesn't resolve until the watcher exits
 * FIXME: this effectively makes the result `any`, which loses type-hints
 */
 | any>;
