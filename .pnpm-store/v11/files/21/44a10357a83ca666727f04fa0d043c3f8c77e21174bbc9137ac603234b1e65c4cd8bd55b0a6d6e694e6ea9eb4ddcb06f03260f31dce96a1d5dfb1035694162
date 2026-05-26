"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.getLatestVersion = getLatestVersion;
const fetch_1 = require("@whatwg-node/fetch");
/**
 * Fetches the version directly from the registry instead of depending on
 * an ESM only module as latest-version does.
 * @param packageName
 */
async function getLatestVersion(packageName) {
    return (0, fetch_1.fetch)(`https://unpkg.com/${packageName}/package.json`)
        .then(res => res.json())
        .then(pkg => pkg.version);
}
