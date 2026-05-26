import { env } from 'process';
import { debugTimerEnd, debugTimerStart } from '@graphql-tools/utils';
export async function loadFile(pointer, options) {
    debugTimerStart(`@graphql-tools/load: loadFile ${pointer}`);
    let results = options.cache?.[pointer];
    if (!results) {
        results = [];
        const errors = [];
        await Promise.all(options.loaders.map(async (loader) => {
            try {
                const loaderResults = await loader.load(pointer, options);
                loaderResults?.forEach(result => results.push(result));
            }
            catch (error) {
                if (env['DEBUG']) {
                    console.error(error);
                }
                if (error instanceof AggregateError) {
                    for (const errorElement of error.errors) {
                        errors.push(errorElement);
                    }
                }
                else {
                    errors.push(error);
                }
            }
        }));
        if (results.length === 0 && errors.length > 0) {
            if (errors.length === 1) {
                throw errors[0];
            }
            throw new AggregateError(errors, `Failed to find any GraphQL type definitions in: ${pointer};\n - ${errors
                .map(error => error.message)
                .join('\n  - ')}`);
        }
        if (options.cache) {
            options.cache[pointer] = results;
        }
    }
    debugTimerEnd(`@graphql-tools/load: loadFile ${pointer}`);
    return results;
}
export function loadFileSync(pointer, options) {
    debugTimerStart(`@graphql-tools/load: loadFileSync ${pointer}`);
    let results = options.cache?.[pointer];
    if (!results) {
        results = [];
        const errors = [];
        for (const loader of options.loaders) {
            try {
                // We check for the existence so it is okay to force non null
                const loaderResults = loader.loadSync(pointer, options);
                loaderResults?.forEach(result => results.push(result));
            }
            catch (error) {
                if (env['DEBUG']) {
                    console.error(error);
                }
                if (error instanceof AggregateError) {
                    for (const errorElement of error.errors) {
                        errors.push(errorElement);
                    }
                }
                else {
                    errors.push(error);
                }
            }
        }
        if (results.length === 0 && errors.length > 0) {
            if (errors.length === 1) {
                throw errors[0];
            }
            throw new AggregateError(errors, `Failed to find any GraphQL type definitions in: ${pointer};\n - ${errors
                .map(error => error.message)
                .join('\n  - ')}`);
        }
        if (options.cache) {
            options.cache[pointer] = results;
        }
    }
    debugTimerEnd(`@graphql-tools/load: loadFileSync ${pointer}`);
    return results;
}
