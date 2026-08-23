defmodule MetadataRelay.Config do
  @moduledoc """
  Small helpers for reading configuration from the environment.

  `System.get_env/1` returns `""` (not `nil`) for a variable explicitly set
  to an empty string, and `""` is truthy in Elixir, so the common
  `System.get_env(name) || raise(...)` / `|| default` pattern silently
  accepts that misconfiguration -- an empty value from a secret store, an
  unset interpolation in a templated manifest, or a literal empty string in
  a `.env` file all produce this. `config/runtime.exs` already had one
  correct version of this logic (`normalize_env`, used for the feedback
  email/SMTP settings) and one incorrect one (the raw pattern, used for
  `DASHBOARD_USERNAME`/`DASHBOARD_PASSWORD`) side by side in the same file
  -- see T-259..T-262: `Authorization: Basic Og==` decodes to `{"", ""}`,
  and `Plug.BasicAuth` does not itself reject an empty configured
  credential (its own moduledoc says user/pass "may be empty strings").
  Routing every environment-driven credential through this module closes
  that gap once, instead of per call site.
  """

  @doc """
  Reads an environment variable, treating "unset" and "blank after
  trimming" identically: both come back as `nil`.
  """
  @spec get_non_blank(String.t()) :: String.t() | nil
  def get_non_blank(name) do
    case System.get_env(name) do
      nil ->
        nil

      value ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end
    end
  end

  @doc """
  Resolves a required credential from the environment.

  Blank (unset or empty-after-trim) is never silently accepted: in `:prod`
  it raises -- refusing to boot with an empty dashboard credential rather
  than quietly authenticating everyone -- matching the existing behavior
  for a value that is missing outright. Everywhere else it falls back to
  `default`, so local dev/CI keeps working with no environment setup
  required.
  """
  @spec fetch_credential!(String.t(), atom(), String.t()) :: String.t()
  def fetch_credential!(env_name, config_env, default) do
    case get_non_blank(env_name) do
      nil ->
        if config_env == :prod do
          raise "#{env_name} not set"
        else
          default
        end

      value ->
        value
    end
  end
end
