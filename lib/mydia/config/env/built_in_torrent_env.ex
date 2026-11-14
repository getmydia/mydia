defmodule Mydia.Config.Env.BuiltInTorrentEnv do
  @moduledoc """
  Reads the `built_in_torrent` section of `Mydia.Config.Schema` from the
  environment (`MYDIA_TORRENT_*` and `MYDIA_VPN_*`).

  Takes a one-argument getenv function so tests can inject values. Blank values
  count as unset; a value that does not parse, a port outside 1..65535 or a rate
  limit outside `BuiltInTorrent.min_rate_limit_kib/0`..`max_rate_limit_kib/0`, leaves its key out
  (`BuiltIn.Config` still warns about it from the raw environment).
  """

  alias Mydia.Config.Loader
  alias Mydia.Config.Schema.BuiltInTorrent

  @integer_fields [:listen_port, :api_port]
  @rate_limit_fields [:download_limit_kib, :upload_limit_kib]
  @min_rate_limit_kib BuiltInTorrent.min_rate_limit_kib()
  @max_rate_limit_kib BuiltInTorrent.max_rate_limit_kib()
  @boolean_fields [:enabled, :vpn_port_forwarding]
  @downcased_fields [:vpn_provider, :vpn_type]

  @spec load((String.t() -> String.t() | nil)) :: map()
  def load(getenv \\ &System.get_env/1) do
    Enum.reduce(BuiltInTorrent.env_vars(), %{}, fn {field, var}, acc ->
      case blank_to_nil(getenv.(var)) do
        nil -> acc
        raw -> put_field(acc, field, raw)
      end
    end)
  end

  # vpn_enabled is implied by a non-blank provider variable, whatever its value.
  defp put_field(acc, :vpn_enabled, _raw), do: Map.put(acc, :vpn_enabled, true)

  defp put_field(acc, field, raw) when field in @integer_fields do
    case Loader.parse_integer(raw) do
      {:ok, int} when int in 1..65_535 -> Map.put(acc, field, int)
      _ -> acc
    end
  end

  defp put_field(acc, field, raw) when field in @rate_limit_fields do
    case Loader.parse_integer(raw) do
      {:ok, int} when int in @min_rate_limit_kib..@max_rate_limit_kib//1 ->
        Map.put(acc, field, int)

      _ ->
        acc
    end
  end

  defp put_field(acc, field, raw) when field in @boolean_fields do
    case parse_boolean(raw) do
      {:ok, bool} -> Map.put(acc, field, bool)
      :error -> acc
    end
  end

  defp put_field(acc, field, raw) when field in @downcased_fields,
    do: Map.put(acc, field, String.downcase(raw))

  defp put_field(acc, field, raw), do: Map.put(acc, field, raw)

  defp parse_boolean(raw) do
    case String.downcase(raw) do
      v when v in ["true", "1", "yes", "on"] -> {:ok, true}
      v when v in ["false", "0", "no", "off"] -> {:ok, false}
      _ -> :error
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
