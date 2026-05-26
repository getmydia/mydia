import { parse } from 'graphql';
import syncFetch from 'sync-fetch';
import { gqlPluckFromCodeStringSync, } from '@graphql-tools/graphql-tag-pluck';
import { parseGraphQLJSON, parseGraphQLSDL, } from '@graphql-tools/utils';
import { fetch as asyncFetch } from '@whatwg-node/fetch';
import { handleMaybePromise } from '@whatwg-node/promise-helpers';
// github:owner/name#ref:path/to/file
function extractData(pointer) {
    const [repo, file] = pointer.split('#');
    const [owner, name] = repo.split(':')[1].split('/');
    const [ref, path] = file.split(':');
    return {
        owner,
        name,
        ref,
        path,
    };
}
/**
 * This loader loads a file from GitHub.
 *
 * ```js
 * const typeDefs = await loadTypedefs('github:githubUser/githubRepo#branchName:path/to/file.ts', {
 *   loaders: [new GithubLoader()],
 *   token: YOUR_GITHUB_TOKEN,
 * })
 * ```
 */
export class GithubLoader {
    async canLoad(pointer) {
        return this.canLoadSync(pointer);
    }
    canLoadSync(pointer) {
        return typeof pointer === 'string' && pointer.toLowerCase().startsWith('github:');
    }
    loadSyncOrAsync(pointer, options, fetchFn) {
        if (!this.canLoadSync(pointer)) {
            return [];
        }
        const { owner, name, ref, path } = extractData(pointer);
        return handleMaybePromise(() => handleMaybePromise(() => fetchFn('https://api.github.com/graphql', this.prepareRequest({ owner, ref, path, name, options })), response => {
            const contentType = response.headers.get('content-type');
            if (contentType && contentType.includes('application/json')) {
                return response.json();
            }
            else {
                return response.text();
            }
        }), response => {
            const status = response.status;
            return this.handleResponse({ pointer, path, options, response, status });
        });
    }
    load(pointer, options) {
        const fetchFn = options.customFetch || asyncFetch;
        return this.loadSyncOrAsync(pointer, options, fetchFn);
    }
    loadSync(pointer, options) {
        const fetchFn = options.customFetch || syncFetch;
        return this.loadSyncOrAsync(pointer, options, fetchFn);
    }
    handleResponse({ pointer, path, options, response, status, }) {
        let errorMessage = null;
        if (response.errors && response.errors.length > 0) {
            errorMessage = response.errors.map((item) => item.message).join(', ');
        }
        else if (status === 401) {
            errorMessage = response.message;
        }
        else if (response.message) {
            errorMessage = response.message;
        }
        else if (!response.data) {
            errorMessage = response;
        }
        if (errorMessage) {
            throw new Error('Unable to download schema from github: ' + errorMessage);
        }
        if (!response.data.repository.object) {
            throw new Error(`Unable to find file: ${path} on ${pointer.replace(`:${path}`, '')}`);
        }
        const content = response.data.repository.object.text;
        if (/\.(gql|graphql)s?$/i.test(path)) {
            return [parseGraphQLSDL(pointer, content, options)];
        }
        if (/\.json$/i.test(path)) {
            return [parseGraphQLJSON(pointer, content, options)];
        }
        if (path.endsWith('.tsx') ||
            path.endsWith('.ts') ||
            path.endsWith('.js') ||
            path.endsWith('.jsx')) {
            const sources = gqlPluckFromCodeStringSync(pointer, content, options.pluckConfig);
            return sources.map(source => ({
                location: pointer,
                document: parse(source, options),
            }));
        }
        throw new Error(`Invalid file extension: ${path}`);
    }
    prepareRequest({ owner, ref, path, name, options, }) {
        const token = options.token || globalThis.process?.env?.['GITHUB_TOKEN'];
        if (!token) {
            throw new Error('You must provide a token to use the GitHub loader');
        }
        const headers = {
            'content-type': 'application/json; charset=utf-8',
            'user-agent': 'graphql-tools',
            authorization: `bearer ${token}`,
            ...options.headers,
        };
        return {
            method: 'POST',
            headers,
            body: JSON.stringify({
                query: `
          query GetGraphQLSchemaForGraphQLtools($owner: String!, $name: String!, $expression: String!) {
            repository(owner: $owner, name: $name) {
              object(expression: $expression) {
                ... on Blob {
                  text
                }
              }
            }
          }
        `,
                variables: {
                    owner,
                    name,
                    expression: ref + ':' + path,
                },
                operationName: 'GetGraphQLSchemaForGraphQLtools',
            }),
        };
    }
}
