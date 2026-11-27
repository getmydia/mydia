// Verbatim copy of the README Quick Start Compose block; compose.test.ts keeps them in sync.
export const composeYaml = `services:
  mydia:
    image: ghcr.io/getmydia/mydia:latest
    container_name: mydia
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=America/New_York
      - SECRET_KEY_BASE=your-secret-key-base-here
      - GUARDIAN_SECRET_KEY=your-guardian-secret-key-here
      - PHX_HOST=localhost
      - MOVIES_PATH=/media/library/movies
      - TV_PATH=/media/library/tv
    volumes:
      - ./config:/config
      - /path/to/media:/media
    ports:
      - 4000:4000
    restart: unless-stopped
`;

export interface ComposeSecrets {
  secretKeyBase: string;
  guardianSecretKey: string;
}

const PLACEHOLDERS: Record<keyof ComposeSecrets, string> = {
  secretKeyBase: 'SECRET_KEY_BASE=your-secret-key-base-here',
  guardianSecretKey: 'GUARDIAN_SECRET_KEY=your-guardian-secret-key-here',
};

/** composeYaml with both placeholder secrets replaced by real values. */
export function composeWithSecrets(secrets: ComposeSecrets): string {
  return composeYaml
    .replace(PLACEHOLDERS.secretKeyBase, `SECRET_KEY_BASE=${secrets.secretKeyBase}`)
    .replace(PLACEHOLDERS.guardianSecretKey, `GUARDIAN_SECRET_KEY=${secrets.guardianSecretKey}`);
}

/**
 * The browser equivalent of `openssl rand -base64 48`: 48 random bytes from
 * the platform CSPRNG, base64 encoded to 64 characters with no padding.
 */
export function randomSecret(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(48));
  return btoa(String.fromCharCode(...bytes));
}
