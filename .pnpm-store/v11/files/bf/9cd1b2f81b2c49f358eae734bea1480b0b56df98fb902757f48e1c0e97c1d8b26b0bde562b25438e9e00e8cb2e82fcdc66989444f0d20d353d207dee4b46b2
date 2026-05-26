/**
 * A wrapper around the `@link` url -- this parses all necessary data to identify the link
 * and determine which version is most appropriate to use.
 */
export declare class FederatedLinkUrl {
    readonly identity: string;
    readonly name: string | null;
    readonly version: string | null;
    private readonly major;
    private readonly minor;
    constructor(identity: string, name: string | null, version: string | null);
    toString(): string;
    static fromUrl: (urlSource: string) => FederatedLinkUrl;
    /** Check if this version supports another version */
    supports(version: string): boolean;
    supports(major: number, minor: number): boolean;
    supports(version: FederatedLinkUrl): boolean;
    supports(version: null): boolean;
    private isCompatibleVersion;
}
