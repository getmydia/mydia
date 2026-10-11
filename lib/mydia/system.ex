defmodule Mydia.System do
  @moduledoc """
  System information helpers for application version, environment, etc.
  """

  # Capture the environment at compile time so it's available in releases
  @env Mix.env()

  # Capture build commit at compile time (set via BUILD_COMMIT env var during Docker builds)
  @build_commit System.get_env("BUILD_COMMIT")

  @doc """
  Get the application version from mix.exs.

  For development/master branch builds, appends an asterisk and short commit hash
  (e.g., "0.7.4*abc1234") to distinguish from stable releases.
  """
  def app_version do
    base_version =
      case Application.spec(:mydia, :vsn) do
        nil -> "unknown"
        vsn -> to_string(vsn)
      end

    version_with_commit(base_version, @build_commit)
  end

  @doc """
  Get the full build commit hash, if available.

  Returns nil for stable releases built from tags.
  """
  def build_commit, do: normalize_commit(@build_commit)

  @doc """
  Check if running in development mode.
  """
  def dev_mode?, do: dev_env?(@env)

  # The three helpers below are public so they are analysed against any input
  # rather than the single compile-time value the module attributes hold, and so
  # tests can drive each branch without recompiling with a different environment.

  @doc false
  @spec version_with_commit(String.t(), String.t() | nil) :: String.t()
  def version_with_commit(base_version, commit) do
    case normalize_commit(commit) do
      nil -> base_version
      commit -> "#{base_version}*#{String.slice(commit, 0, 7)}"
    end
  end

  @doc false
  @spec normalize_commit(String.t() | nil) :: String.t() | nil
  def normalize_commit(""), do: nil
  def normalize_commit(commit), do: commit

  @doc false
  @spec dev_env?(atom()) :: boolean()
  def dev_env?(env), do: env == :dev
end
