defmodule Mydia.Release.Env do
  @moduledoc """
  Validates required environment variables read at release boot
  (`config/runtime.exs`).

  `config/runtime.exs` historically required a variable with the idiom
  `System.get_env(var) || raise "..."`. Elixir's `||` only falls through on
  `nil` or `false` -- an empty string is neither, so a variable that is
  *present but blank* (an unpopulated secrets file, an empty systemd/Docker
  credential, `VAR=` with no value in a compose file) silently satisfies the
  check and the `raise` never fires.

  For most variables that just produces a confusing downstream failure. For
  a JWT/session signing secret it is a confirmed authentication bypass:
  Guardian signs *and verifies* HS512 tokens with a zero-length HMAC key
  without complaint, so `GUARDIAN_SECRET_KEY=""` lets anyone who knows a
  user's UUID mint a valid access token for them.

  `fetch!/2` and `fetch_secret!/2` close that gap by treating a blank value
  the same as a missing one.
  """

  # Mirrors the floor `mix phx.gen.secret` and `mix guardian.gen.secret`
  # themselves enforce ("The secret should be at least 32 characters long") --
  # both refuse to generate anything shorter, and both default to 64. Using
  # their own floor means every secret produced by the documented generation
  # commands passes, while a blank, placeholder, or trivially short value
  # does not.
  @default_min_secret_length 32

  @doc """
  Fetches `env_var`, raising a clear error if it is unset, empty, or
  whitespace-only.

  `hint` is an optional line appended to the error message, e.g. an example
  value or how to generate one.
  """
  @spec fetch!(String.t(), String.t() | nil) :: String.t()
  def fetch!(env_var, hint \\ nil) when is_binary(env_var) do
    case System.get_env(env_var) do
      nil -> raise_missing!(env_var, hint)
      value -> if blank?(value), do: raise_missing!(env_var, hint), else: value
    end
  end

  @doc """
  Fetches `env_var` as a signing/session secret: the same requirement as
  `fetch!/2`, plus a minimum length so a blank, placeholder, or trivially
  short value cannot pass.

  ## Options

    * `:min_length` - minimum character count after trimming whitespace.
      Defaults to #{@default_min_secret_length}, the same floor
      `mix phx.gen.secret` and `mix guardian.gen.secret` enforce.
    * `:hint` - optional line appended to the error message.

  """
  @spec fetch_secret!(String.t(), keyword()) :: String.t()
  def fetch_secret!(env_var, opts \\ []) when is_binary(env_var) and is_list(opts) do
    min_length = Keyword.get(opts, :min_length, @default_min_secret_length)
    hint = Keyword.get(opts, :hint)

    value = fetch!(env_var, hint)
    trimmed_length = value |> String.trim() |> String.length()

    if trimmed_length < min_length do
      raise """
      environment variable #{env_var} is too short (#{trimmed_length} character#{plural(trimmed_length)}; at least #{min_length} are required for a signing secret).

      A short or predictable value here can be brute-forced or guessed, which lets an attacker forge authentication tokens.#{hint_line(hint)}
      """
    end

    value
  end

  defp blank?(value), do: String.trim(value) == ""

  defp raise_missing!(env_var, hint) do
    raise """
    environment variable #{env_var} is missing.#{hint_line(hint)}
    """
  end

  defp hint_line(nil), do: ""
  defp hint_line(hint), do: "\n\n#{hint}"

  defp plural(1), do: ""
  defp plural(_), do: "s"
end
