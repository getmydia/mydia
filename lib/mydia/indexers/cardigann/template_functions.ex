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

  def slice(str, start, nil) when is_binary(str), do: String.slice(str, to_int(start)..-1//1)

  def slice(str, start, stop) when is_binary(str),
    do: String.slice(str, to_int(start)..(to_int(stop) - 1)//1)

  def slice(_str, _start, _stop), do: ""

  defp to_int(value) when is_binary(value), do: String.to_integer(value)
  defp to_int(value), do: value
end
