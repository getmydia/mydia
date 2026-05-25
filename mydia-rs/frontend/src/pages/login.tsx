import { useSearchParams } from "react-router-dom";

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
};

export function LoginPage() {
  const [searchParams] = useSearchParams();
  const errorCode = searchParams.get("error");

  return (
    <div className="flex items-center justify-center min-h-screen bg-base-200">
      <div className="card bg-base-100 shadow-xl w-full max-w-sm">
        <div className="card-body items-center text-center gap-6">
          <h1 className="text-2xl font-bold">Mydia</h1>
          <p className="text-base-content/60">Sign in to manage your media</p>

          {errorCode && (
            <div className="alert alert-warning text-sm">
              {ERROR_MESSAGES[errorCode] ?? `An error occurred (${errorCode})`}
            </div>
          )}

          <a href="/auth/oidc/login" className="btn btn-primary w-full">
            Log in with OIDC
          </a>
        </div>
      </div>
    </div>
  );
}
