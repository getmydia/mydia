const VERSION_MATCH = /v(\d{1,3})\.(\d{1,4})/i;
function parseVersion(version) {
    const versionParts = version?.match(VERSION_MATCH);
    if (versionParts?.length) {
        const [_full, major, minor] = versionParts;
        return [Number(major), Number(minor)];
    }
    return [-1, -1];
}
/**
 * A wrapper around the `@link` url -- this parses all necessary data to identify the link
 * and determine which version is most appropriate to use.
 */
export class FederatedLinkUrl {
    identity;
    name;
    version;
    // -1 if no version is set
    major;
    minor;
    constructor(identity, name, version) {
        this.identity = identity;
        this.name = name;
        this.version = version;
        const [major, minor] = parseVersion(version);
        this.major = major;
        this.minor = minor;
    }
    toString() {
        return `${this.identity}${this.version ? `/${this.version}` : ''}`;
    }
    static fromUrl = (urlSource) => {
        const url = new URL(urlSource);
        const parts = url.pathname.split('/').filter(Boolean);
        const versionOrName = parts[parts.length - 1];
        if (versionOrName) {
            if (VERSION_MATCH.test(versionOrName)) {
                const maybeName = parts[parts.length - 2];
                return new FederatedLinkUrl(url.origin + (maybeName ? `/${parts.slice(0, parts.length - 1).join('/')}` : ''), maybeName ?? null, versionOrName);
            }
            return new FederatedLinkUrl(`${url.origin}/${parts.join('/')}`, versionOrName, null);
        }
        return new FederatedLinkUrl(url.origin, null, null);
    };
    supports(...args) {
        const majorOrVersion = args[0];
        let major, minor;
        if (typeof majorOrVersion === 'string') {
            [major, minor] = parseVersion(majorOrVersion);
        }
        else if (typeof majorOrVersion === 'number') {
            [major, minor] = args;
        }
        else if (majorOrVersion instanceof FederatedLinkUrl) {
            // check that it is the same spec
            if (majorOrVersion.identity !== this.identity) {
                return false;
            }
            major = majorOrVersion.major;
            minor = majorOrVersion.minor;
        }
        else if (majorOrVersion === null) {
            // handles null case
            return majorOrVersion === this.version;
        }
        else {
            throw new Error(`Unsupported version argument: ${JSON.stringify(args)} [${typeof args}].`);
        }
        return this.isCompatibleVersion(major, minor);
    }
    isCompatibleVersion(major, minor) {
        if (this.major === major) {
            if (this.major === 0) {
                return this.minor === minor;
            }
            return this.minor >= minor;
        }
        return false;
    }
}
