defmodule Mydia.Config.Env.RemoteAccessEnv do
  @moduledoc """
  Reads the `remote_access` section of `Mydia.Config.Schema` from the
  environment: `ENABLE_REMOTE_ACCESS` and `IROH_RELAY_URL`.

  A missing or empty variable leaves its key out, so the database and YAML
  layers still apply.
  """

  alias Mydia.Config.Loader

  @spec load((String.t() -> String.t() | nil)) :: map()
  def load(getenv \\ &System.get_env/1) do
    %{}
    |> put("ENABLE_REMOTE_ACCESS", :enabled, getenv, &parse_boolean_or_invalid/1)
    |> put("IROH_RELAY_URL", :relay_urls, getenv, &parse_list/1)
  end

  defp put(acc, var, key, getenv, parser) do
    case getenv.(var) do
      value when value in [nil, ""] -> acc
      value -> Map.put(acc, key, parser.(value))
    end
  end

  # Not Loader.parse_boolean/1 alone: this switch puts a network listener on
  # the internet, so a typo has to fail validation by name instead of falling
  # back to the default, which is on. :invalid does not cast to a boolean. The
  # config README explains why a dropped value is worse than a rejected one.
  defp parse_boolean_or_invalid(value) do
    case Loader.parse_boolean(value) do
      {:ok, boolean} -> boolean
      :error -> :invalid
    end
  end

  # Comma-separated, in preference order. Validation rejects anything that is
  # not an https URL, so a typo stops startup instead of being skipped.
  defp parse_list(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
