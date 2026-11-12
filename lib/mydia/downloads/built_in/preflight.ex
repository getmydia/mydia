defmodule Mydia.Downloads.BuiltIn.Preflight do
  @moduledoc """
  Reads the entrypoint's `preflight` file: `key=ok|missing` lines describing
  what the container grants the VPN. A key that is absent reads as `:ok`;
  only an explicit `missing` blocks, and `src_valid_mark` never does.
  """

  @keys [:net_admin, :tun, :split_group, :src_valid_mark]

  @doc """
  The parsed file, `:absent` when there is none (the entrypoint has not run
  yet, or this is not the container), or `{:error, posix}` when it exists
  but cannot be read.
  """
  @spec read(Path.t()) :: {:ok, map()} | :absent | {:error, File.posix()}
  def read(dir) do
    case File.read(Path.join(dir, "preflight")) do
      {:ok, body} -> {:ok, parse(body)}
      {:error, :enoent} -> :absent
      {:error, _posix} = error -> error
    end
  end

  defp parse(body) do
    lines =
      body
      |> String.split("\n", trim: true)
      |> Map.new(fn line ->
        case String.split(String.trim(line), "=", parts: 2) do
          [k, v] -> {k, v}
          [k] -> {k, ""}
        end
      end)

    Map.new(@keys, fn key ->
      {key, if(Map.get(lines, Atom.to_string(key)) == "missing", do: :missing, else: :ok)}
    end)
  end

  @spec blocking_reason(map()) :: nil | :missing_net_admin | :missing_tun | :split_group_missing
  def blocking_reason(%{net_admin: :missing}), do: :missing_net_admin
  def blocking_reason(%{tun: :missing}), do: :missing_tun
  def blocking_reason(%{split_group: :missing}), do: :split_group_missing
  def blocking_reason(_), do: nil
end
