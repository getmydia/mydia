defmodule Mydia.URL do
  @moduledoc """
  URL parsing that keeps the port an operator typed.

  Since Elixir 1.20.5, `URI.parse/1` returns `port: nil` for a port outside
  1..65535 (`"http://host:99999"`), so a range check on the parsed port never
  sees it and an error message cannot show it. `URI.new/1` keeps the number but
  refuses some URLs `URI.parse/1` accepts, such as an unescaped `[` in the
  query. `parse/1` tries `URI.new/1` first and, on the `URI.parse/1` fallback,
  restores a dropped port from the authority, so callers can validate it.
  """

  @doc """
  Parses `url` like `URI.parse/1`, but keeps an out-of-range port as an
  integer instead of `nil`.
  """
  @spec parse(String.t()) :: URI.t()
  def parse(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, uri} -> uri
      {:error, _} -> url |> URI.parse() |> restore_port()
    end
  end

  defp restore_port(%URI{port: nil, authority: authority} = uri) when is_binary(authority) do
    case Regex.run(~r/:(\d+)\z/, authority) do
      [_, digits] -> %{uri | port: String.to_integer(digits)}
      nil -> uri
    end
  end

  defp restore_port(uri), do: uri
end
