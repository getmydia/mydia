// Browser side of passkeys: turns the server's JSON options into
// navigator.credentials calls and the resulting credentials back into JSON.
// Binary fields cross the wire as unpadded base64url, matching
// Mydia.Accounts.WebAuthn. The login and second-factor pages are
// controller-rendered, so they get plain DOM wiring (initPasskeyLogin,
// initPasskeySecondFactor); the profile page uses the PasskeyRegister hook.

export function bufferToBase64url(buffer) {
  const bytes = buffer instanceof Uint8Array ? buffer : new Uint8Array(buffer);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function base64urlToBuffer(value) {
  const base64 = value.replace(/-/g, "+").replace(/_/g, "/");
  const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes.buffer;
}

const decodeDescriptors = (list) =>
  (list || []).map((descriptor) => ({ ...descriptor, id: base64urlToBuffer(descriptor.id) }));

export function decodeCreationOptions(options) {
  return {
    ...options,
    challenge: base64urlToBuffer(options.challenge),
    user: { ...options.user, id: base64urlToBuffer(options.user.id) },
    excludeCredentials: decodeDescriptors(options.excludeCredentials),
  };
}

export function decodeRequestOptions(options) {
  return {
    ...options,
    challenge: base64urlToBuffer(options.challenge),
    allowCredentials: decodeDescriptors(options.allowCredentials),
  };
}

export function encodeRegistration(credential) {
  const response = credential.response;
  return {
    id: credential.id,
    rawId: bufferToBase64url(credential.rawId),
    type: credential.type,
    response: {
      attestationObject: bufferToBase64url(response.attestationObject),
      clientDataJSON: bufferToBase64url(response.clientDataJSON),
      transports: typeof response.getTransports === "function" ? response.getTransports() : [],
    },
  };
}

export function encodeAssertion(credential) {
  const response = credential.response;
  return {
    id: credential.id,
    rawId: bufferToBase64url(credential.rawId),
    type: credential.type,
    response: {
      authenticatorData: bufferToBase64url(response.authenticatorData),
      clientDataJSON: bufferToBase64url(response.clientDataJSON),
      signature: bufferToBase64url(response.signature),
      userHandle: response.userHandle ? bufferToBase64url(response.userHandle) : null,
    },
  };
}

export function passkeysSupported(win) {
  return Boolean(win && win.isSecureContext && win.PublicKeyCredential && win.navigator?.credentials);
}

const BROWSERS = [
  [/Edg\//, "Edge"],
  [/Firefox\//, "Firefox"],
  [/Chrome\//, "Chrome"],
  [/Safari\//, "Safari"],
];

const PLATFORMS = [
  [/iPhone|iPad|iPod/, "iOS"],
  [/Android/, "Android"],
  [/Mac OS X|Macintosh/, "macOS"],
  [/Windows/, "Windows"],
  [/CrOS/, "ChromeOS"],
  [/Linux/, "Linux"],
];

const firstMatch = (table, ua) => table.find(([pattern]) => pattern.test(ua))?.[1];

export function deviceName(userAgent) {
  const ua = userAgent || "";
  const browser = firstMatch(BROWSERS, ua);
  const platform = firstMatch(PLATFORMS, ua);
  if (browser && platform) return `Passkey on ${browser}, ${platform}`;
  if (browser || platform) return `Passkey on ${browser || platform}`;
  return "Passkey";
}

export function errorReason(error) {
  switch (error?.name) {
    case "NotAllowedError":
    case "AbortError":
      return "cancelled";
    case "InvalidStateError":
      return "duplicate";
    default:
      return "failed";
  }
}

const MESSAGES = {
  cancelled: "The passkey request was cancelled or timed out.",
  duplicate: "This device already has a passkey for this account",
  failed: "Passkey not recognised",
};

export function errorMessage(reason) {
  return MESSAGES[reason] || MESSAGES.failed;
}

// No Accept header: the :browser pipeline only accepts html, and a missing
// header (*/*) passes it.
async function postJSON(url, body) {
  const token = document.querySelector("meta[name='csrf-token']")?.getAttribute("content");
  const response = await fetch(url, {
    method: "POST",
    credentials: "same-origin",
    headers: { "content-type": "application/json", "x-csrf-token": token || "" },
    body: JSON.stringify(body || {}),
  });
  const data = await response.json().catch(() => ({}));
  return { ok: response.ok, data };
}

function showError(el, message) {
  if (!el) return;
  el.textContent = message;
  el.classList.remove("hidden");
}

async function runAssertion({ optionsUrl, verifyUrl, mediation, signal }) {
  const options = await postJSON(optionsUrl);
  if (!options.ok) throw new ServerError(options.data.error);

  const credential = await navigator.credentials.get({
    publicKey: decodeRequestOptions(options.data.publicKey),
    mediation,
    signal,
  });

  const result = await postJSON(verifyUrl, { credential: encodeAssertion(credential) });
  if (!result.ok) throw new ServerError(result.data.error);
  window.location.assign(result.data.redirect || "/");
}

class ServerError extends Error {
  constructor(message) {
    super(message || MESSAGES.failed);
    this.name = "ServerError";
  }
}

function messageFor(error) {
  return error instanceof ServerError ? error.message : errorMessage(errorReason(error));
}

export function initPasskeyLogin(doc) {
  const section = doc.getElementById("passkey-login-section");
  if (!section || !passkeysSupported(window)) return;

  section.classList.remove("hidden");
  const button = doc.getElementById("passkey-login");
  const errorEl = doc.getElementById("passkey-login-error");
  const urls = { optionsUrl: section.dataset.optionsUrl, verifyUrl: section.dataset.loginUrl };
  let autofill = null;

  button?.addEventListener("click", () => {
    autofill?.abort();
    errorEl?.classList.add("hidden");
    runAssertion({ ...urls, mediation: "optional" }).catch((error) => showError(errorEl, messageFor(error)));
  });

  // Offer passkeys in the username field's autofill. Silently ends when the
  // user types a password instead, or clicks the button (which aborts it).
  const conditional = window.PublicKeyCredential.isConditionalMediationAvailable;
  if (typeof conditional === "function") {
    conditional.call(window.PublicKeyCredential).then((available) => {
      if (!available) return;
      autofill = new AbortController();
      runAssertion({ ...urls, mediation: "conditional", signal: autofill.signal }).catch((error) => {
        if (error instanceof ServerError) showError(errorEl, error.message);
      });
    });
  }
}

export function initPasskeySecondFactor(doc) {
  const section = doc.getElementById("passkey-second-factor-section");
  if (!section) return;

  const button = doc.getElementById("passkey-second-factor");
  const errorEl = doc.getElementById("passkey-second-factor-error");

  if (!passkeysSupported(window)) {
    button?.setAttribute("disabled", "disabled");
    showError(errorEl, "This browser can't use passkeys here.");
    return;
  }

  button?.addEventListener("click", () => {
    errorEl?.classList.add("hidden");
    runAssertion({
      optionsUrl: section.dataset.optionsUrl,
      verifyUrl: section.dataset.verifyUrl,
      mediation: "optional",
    }).catch((error) => showError(errorEl, messageFor(error)));
  });
}

// Profile page. The server pushes "passkey:register" with creation options
// once the user has re-entered their password; this runs the authenticator
// and pushes the result back to the component that owns this element.
export const PasskeyRegister = {
  mounted() {
    this.pushEventTo(this.el, "passkey_support", { supported: passkeysSupported(window) });

    this.handleEvent("passkey:register", async ({ options }) => {
      try {
        const credential = await navigator.credentials.create({
          publicKey: decodeCreationOptions(options),
        });
        this.pushEventTo(this.el, "passkey_registered", {
          credential: encodeRegistration(credential),
          name: deviceName(navigator.userAgent),
        });
      } catch (error) {
        this.pushEventTo(this.el, "passkey_failed", { reason: errorReason(error) });
      }
    });
  },
};
