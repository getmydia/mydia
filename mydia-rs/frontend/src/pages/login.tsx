import { useSearchParams } from "react-router-dom";
import { useState, useEffect, type FormEvent } from "react";

const ERROR_MESSAGES: Record<string, string> = {
  oidc_disabled: "OIDC login is not configured on this server.",
  provider_error: "The identity provider returned an error.",
  missing_code: "The login callback was missing required parameters.",
  missing_session_state: "Your login session expired. Please try again.",
  state_mismatch: "Login security check failed. Please try again.",
  token_exchange_failed: "Could not complete login. Please try again.",
  missing_id_token: "The identity provider did not return a valid session.",
  id_token_invalid: "The identity provider session could not be verified.",
  invalid_claims: "Your account is missing required information.",
  user_upsert_failed: "Could not create or update your account.",
  session_write_failed: "Could not save your login session.",
  invalid_credentials: "Invalid username or password.",
  local_login_failed: "Login failed. Please try again.",
  setup_already_completed: "Setup has already been completed.",
  db_error: "A database error occurred. Please try again.",
};

export function LoginPage() {
  const [searchParams] = useSearchParams();
  const errorCode = searchParams.get("error");
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [email, setEmail] = useState("");
  const [loading, setLoading] = useState(false);
  const [localError, setLocalError] = useState<string | null>(null);
  const [needsSetup, setNeedsSetup] = useState<boolean | null>(null);

  useEffect(() => {
    fetch("/auth/status")
      .then((r) => r.json())
      .then((data) => setNeedsSetup(!data.setup_completed))
      .catch(() => setNeedsSetup(false));
  }, []);

  const handleSubmit = async (e: FormEvent) => {
    e.preventDefault();
    setLoading(true);
    setLocalError(null);

    const formData = new URLSearchParams();
    formData.append("username", username);
    formData.append("password", password);

    try {
      const resp = await fetch("/auth/local/login", {
        method: "POST",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
          "X-Mydia-Client": "web",
        },
        body: formData,
        credentials: "include",
        redirect: "follow",
      });

      if (resp.redirected && resp.url.includes("/login?error=")) {
        const url = new URL(resp.url);
        const code = url.searchParams.get("error") ?? "invalid_credentials";
        setLocalError(ERROR_MESSAGES[code] ?? "Invalid username or password.");
        setLoading(false);
      } else if (resp.ok || resp.redirected) {
        window.location.assign("/");
      } else {
        setLocalError("Invalid username or password.");
        setLoading(false);
      }
    } catch {
      setLocalError("Login failed. Please try again.");
      setLoading(false);
    }
  };

  const handleSetup = async (e: FormEvent) => {
    e.preventDefault();
    setLoading(true);
    setLocalError(null);

    const formData = new URLSearchParams();
    formData.append("username", username);
    formData.append("email", email || `${username}@localhost`);
    formData.append("password", password);

    try {
      const resp = await fetch("/auth/local/setup", {
        method: "POST",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
          "X-Mydia-Client": "web",
        },
        body: formData,
        credentials: "include",
        redirect: "follow",
      });

      if (resp.redirected && resp.url.includes("/login?error=")) {
        const url = new URL(resp.url);
        const code = url.searchParams.get("error") ?? "setup_already_completed";
        setLocalError(ERROR_MESSAGES[code] ?? "Setup failed.");
        setLoading(false);
      } else if (resp.ok || resp.redirected) {
        window.location.assign("/");
      } else {
        setLocalError("Setup failed. Please try again.");
        setLoading(false);
      }
    } catch {
      setLocalError("Setup failed. Please try again.");
      setLoading(false);
    }
  };

  if (needsSetup === null) {
    return (
      <div className="flex items-center justify-center min-h-screen bg-base-200">
        <span className="loading loading-spinner loading-lg" />
      </div>
    );
  }

  return (
    <div className="flex items-center justify-center min-h-screen bg-base-200">
      <div className="card bg-base-100 shadow-xl w-full max-w-sm">
        <div className="card-body items-center text-center gap-6">
          <h1 className="text-2xl font-bold">Mydia</h1>

          {needsSetup ? (
            <>
              <p className="text-base-content/60">
                Welcome! Create your admin account to get started.
              </p>

              {(localError) && (
                <div className="alert alert-warning text-sm">{localError}</div>
              )}

              <form onSubmit={handleSetup} className="flex flex-col gap-4 w-full">
                <input
                  type="text"
                  placeholder="Username"
                  value={username}
                  onChange={(e) => setUsername(e.target.value)}
                  className="input input-bordered w-full"
                  required
                  minLength={3}
                  maxLength={50}
                />
                <input
                  type="email"
                  placeholder="Email"
                  value={email}
                  onChange={(e) => setEmail(e.target.value)}
                  className="input input-bordered w-full"
                  required
                />
                <input
                  type="password"
                  placeholder="Password (min 8 characters)"
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  className="input input-bordered w-full"
                  required
                  minLength={8}
                />
                <button
                  type="submit"
                  className="btn btn-primary w-full"
                  disabled={loading}
                >
                  {loading ? "Creating account..." : "Create admin account"}
                </button>
              </form>
            </>
          ) : (
            <>
              <p className="text-base-content/60">Sign in to manage your media</p>

              {(errorCode || localError) && (
                <div className="alert alert-warning text-sm">
                  {localError ?? ERROR_MESSAGES[errorCode ?? ""] ?? `An error occurred (${errorCode})`}
                </div>
              )}

              <form onSubmit={handleSubmit} className="flex flex-col gap-4 w-full">
                <input
                  type="text"
                  placeholder="Username or email"
                  value={username}
                  onChange={(e) => setUsername(e.target.value)}
                  className="input input-bordered w-full"
                  required
                />
                <input
                  type="password"
                  placeholder="Password"
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  className="input input-bordered w-full"
                  required
                />
                <button type="submit" className="btn btn-primary w-full" disabled={loading}>
                  {loading ? "Signing in..." : "Log in"}
                </button>
              </form>

              <div className="divider">or</div>

              <a href="/auth/oidc/login" className="btn btn-primary w-full">
                Log in with OIDC
              </a>
            </>
          )}
        </div>
      </div>
    </div>
  );
}
