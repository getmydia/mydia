defmodule Mydia.Indexers.Cardigann.TemplateFunctions do
  @moduledoc false
  # Go template functions that format or slice a value. They need nothing from
  # the template context, so they live apart from the evaluator.

  require Logger

  @doc "Go `printf`: converts the Go verbs to Erlang's and formats `args`."
  @spec printf(String.t(), [term()]) :: String.t()
  def printf(fmt, args) do
    # %s -> ~s (strings), %d -> ~B (integers), %v -> ~p (any value)
    erlang_fmt =
      fmt
      |> String.replace("%s", "~s")
      |> String.replace("%d", "~B")
      |> String.replace("%v", "~p")
      |> String.replace("%f", "~f")
      |> String.replace("%%", "~%")

    :io_lib.format(to_charlist(erlang_fmt), args) |> IO.iodata_to_binary()
  rescue
    e ->
      Logger.debug("printf error: #{inspect(e)}, fmt=#{fmt}, args=#{inspect(args)}")
      ""
  end

  @doc "Substring `slice str start stop` (stop exclusive); `stop` may be omitted."
  @spec slice(term(), term(), term()) :: String.t()
  def slice(str, start, stop \\ nil)

  def slice(str, start, nil) when is_binary(str) do
    case parse_int(start) do
      {:ok, from} -> String.slice(str, from..-1//1)
      :error -> ""
    end
  end

  def slice(str, start, stop) when is_binary(str) do
    with {:ok, from} <- parse_int(start),
         {:ok, to} <- parse_int(stop) do
      String.slice(str, from..(to - 1)//1)
    else
      :error -> ""
    end
  end

  def slice(_str, _start, _stop), do: ""

  defp parse_int(value) when is_integer(value), do: {:ok, value}

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  defp parse_int(_value), do: :error
end
