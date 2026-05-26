import { type DocumentNode } from 'graphql';
import { type Types } from '@graphql-codegen/plugin-helpers';
export { default as babelOptimizerPlugin } from './babel.cjs';
export type FragmentMaskingConfig = {
    /** @description Name of the function that should be used for unmasking a masked fragment property.
     * @default `'useFragment'`
     */
    unmaskFunctionName?: string;
};
export type ClientPresetConfig = {
    /**
     * @description Fragment masking hides data from components and only allows accessing the data by using a unmasking function.
     * @exampleMarkdown
     * ```tsx
     * const config = {
     *    schema: 'https://graphql.org/graphql/',
     *    documents: ['src/**\/*.tsx', '!src\/gql/**\/*'],
     *    generates: {
     *       './src/gql/': {
     *          preset: 'client',
     *          presetConfig: {
     *            fragmentMasking: false,
     *          }
     *        },
     *    },
     * };
     * export default config;
     * ```
     */
    fragmentMasking?: FragmentMaskingConfig | boolean;
    /**
     * @description Specify the name of the "graphql tag" function to use
     * @default "graphql"
     *
     * E.g. `graphql` or `gql`.
     *
     * @exampleMarkdown
     * ```tsx
     * const config = {
     *    schema: 'https://graphql.org/graphql/',
     *    documents: ['src/**\/*.tsx', '!src\/gql/**\/*'],
     *    generates: {
     *       './src/gql/': {
     *          preset: 'client',
     *          presetConfig: {
     *            gqlTagName: 'gql',
     *          }
     *        },
     *    },
     * };
     * export default config;
     * ```
     */
    gqlTagName?: string;
    /**
     * Generate metadata for a executable document node and embed it in the emitted code.
     */
    onExecutableDocumentNode?: (documentNode: DocumentNode) => void | Record<string, unknown>;
    /** Persisted operations configuration. */
    persistedDocuments?: boolean | {
        /**
         * @description Behavior for the output file.
         * @default 'embedHashInDocument'
         * "embedHashInDocument" will add a property within the `DocumentNode` with the hash of the operation.
         * "replaceDocumentWithHash" will fully drop the document definition.
         */
        mode?: 'embedHashInDocument' | 'replaceDocumentWithHash';
        /**
         * @description Name of the property that will be added to the `DocumentNode` with the hash of the operation.
         */
        hashPropertyName?: string;
        /**
         * @description Algorithm or function used to generate the hash, could be useful if your server expects something specific (e.g., Apollo Server expects `sha256`).
         *
         * A custom hash function can be provided to generate the hash if the preset algorithms don't fit your use case. The function receives the operation and should return the hash string.
         *
         * The algorithm parameter is typed with known algorithms and as a string rather than a union because it solely depends on Crypto's algorithms supported
         * by the version of OpenSSL on the platform.
         *
         * @default `sha256`
         */
        hashAlgorithm?: 'sha1' | 'sha256' | (string & {}) | ((operation: string) => string);
    };
};
export declare const preset: Types.OutputPreset<ClientPresetConfig>;
export { addTypenameSelectionDocumentTransform } from './add-typename-selection-document-transform.cjs';
