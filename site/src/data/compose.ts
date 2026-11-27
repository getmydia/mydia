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

const ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
// The largest multiple of 62 a byte can hold. Bytes at or above it are
// dropped, so every character is equally likely (no modulo bias).
const UNBIASED_LIMIT = 256 - (256 % ALPHABET.length);

/**
 * 64 letters and digits from the platform CSPRNG, about 381 bits. Letters and
 * digits only, so a double-click selects the whole key: browsers and
 * terminals stop a word selection at the + and / that base64 would include.
 */
export function randomSecret(length = 64): string {
  let out = '';
  while (out.length < length) {
    for (const byte of crypto.getRandomValues(new Uint8Array(length))) {
      if (byte < UNBIASED_LIMIT) out += ALPHABET[byte % ALPHABET.length];
      if (out.length === length) break;
    }
  }
  return out;
}
