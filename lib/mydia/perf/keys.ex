defmodule Mydia.Perf.Keys do
  @moduledoc """
  Tag values for `Mydia.Perf.Metrics`, derived from telemetry event metadata.

  Each function receives the metadata of one event and returns a map of tag
  values. None of them may raise. `:telemetry` detaches a handler that raises,
  and Peep attaches one handler per event name, so one bad input would stop
  every metric on that event for the rest of the boot. Anything unrecognised
  becomes `"unknown"`.

  ## Query callers

  `caller/1` names the first stacktrace frame in application code. Two limits
  apply. Ecto captures the stacktrace with `:erlang.process_info/2`, which keeps
  eight frames by default. And a function that ends in a tail call to the Repo
  leaves no frame of its own, so the key names whoever called it.
  """

  alias Phoenix.LiveView.Socket

  @unknown "unknown"

  @doc "LiveView `mount` and `handle_params`: the view and whether the socket is connected."
  @spec live_view(term()) :: %{view: String.t(), connected: boolean() | String.t()}
  def live_view(metadata) do
    guard(%{view: @unknown, connected: @unknown}, fn ->
      %{socket: %Socket{} = socket} = metadata
      %{view: module_name(socket.view), connected: Phoenix.LiveView.connected?(socket)}
    end)
  end

  @doc "LiveView `handle_event`: the view and the event name."
  @spec live_view_event(term()) :: %{view: String.t(), event: String.t()}
  def live_view_event(metadata) do
    guard(%{view: @unknown, event: @unknown}, fn ->
      %{socket: %Socket{} = socket, event: event} = metadata
      %{view: module_name(socket.view), event: to_string(event)}
    end)
  end

  @doc "LiveView render: the view, and the component when a component rendered."
  @spec render(term()) :: %{view: String.t(), component: String.t()}
  def render(metadata) do
    guard(%{view: @unknown, component: @unknown}, fn ->
      %{socket: %Socket{} = socket} = metadata

      %{
        view: module_name(socket.view),
        component: module_name(Map.get(metadata, :component), "none")
      }
    end)
  end

  @doc "LiveComponent `handle_event`: the component and the event name."
  @spec component_event(term()) :: %{component: String.t(), event: String.t()}
  def component_event(metadata) do
    guard(%{component: @unknown, event: @unknown}, fn ->
      %{component: component, event: event} = metadata
      %{component: module_name(component), event: to_string(event)}
    end)
  end

  @doc "Router dispatch: the route pattern, never the concrete path."
  @spec route(term()) :: %{route: String.t()}
  def route(metadata) do
    guard(%{route: @unknown}, fn ->
      %{route: route} = metadata
      true = is_binary(route)
      %{route: route}
    end)
  end

  @doc "Absinthe operation: its name and the `:source` its context carries."
  @spec graphql(term()) :: %{operation: String.t(), source: String.t()}
  def graphql(metadata) do
    guard(%{operation: @unknown, source: @unknown}, fn ->
      %{blueprint: %Absinthe.Blueprint{} = blueprint} = metadata
      %{operation: operation_name(blueprint), source: graphql_source(Map.get(metadata, :options))}
    end)
  end

  @doc "Ecto query: the calling application function and the table."
  @spec query(term()) :: %{caller: String.t(), source: String.t()}
  def query(metadata) do
    guard(%{caller: @unknown, source: @unknown}, fn ->
      %{
        caller: caller(Map.get(metadata, :stacktrace)),
        source: query_source(Map.get(metadata, :source))
      }
    end)
  end

  @doc "Oban job: the worker and the state it finished in."
  @spec oban_job(term()) :: %{worker: String.t(), state: String.t()}
  def oban_job(metadata) do
    guard(%{worker: @unknown, state: @unknown}, fn ->
      %{worker: worker} = metadata
      %{worker: to_string(worker), state: metadata |> Map.get(:state, @unknown) |> to_string()}
    end)
  end

  @doc "p2p request span: the kind passed at the span site."
  @spec p2p_request(term()) :: %{kind: String.t()}
  def p2p_request(metadata) do
    guard(%{kind: @unknown}, fn ->
      %{kind: kind} = metadata
      %{kind: to_string(kind)}
    end)
  end

  @doc """
  The first frame under `Mydia.` or `MydiaWeb.` other than `Mydia.Repo`, as
  `Module.fun/arity`, or `"unknown"`.
  """
  @spec caller(term()) :: String.t()
  def caller(stacktrace) when is_list(stacktrace) do
    Enum.find_value(stacktrace, @unknown, fn
      {module, fun, arity, _location} when is_atom(module) and is_atom(fun) ->
        if application_module?(module), do: format_frame(module, fun, arity)

      _other ->
        nil
    end)
  end

  def caller(_stacktrace), do: @unknown

  defp guard(fallback, fun) do
    fun.()
  rescue
    _exception -> fallback
  end

  defp operation_name(blueprint) do
    case Absinthe.Blueprint.current_operation(blueprint) do
      %{name: name} when is_binary(name) -> name
      _ -> "anonymous"
    end
  end

  defp graphql_source(options) when is_list(options) do
    case options |> Keyword.get(:context, %{}) |> Map.get(:source) do
      nil -> @unknown
      source -> to_string(source)
    end
  end

  defp graphql_source(_options), do: @unknown

  defp query_source(source) when is_binary(source), do: source
  defp query_source(_source), do: "none"

  defp application_module?(Mydia.Repo), do: false

  defp application_module?(module) do
    name = Atom.to_string(module)
    String.starts_with?(name, "Elixir.Mydia.") or String.starts_with?(name, "Elixir.MydiaWeb.")
  end

  defp format_frame(module, fun, arity) do
    inspect(module) <> "." <> function_name(fun, arity)
  end

  # Anonymous functions appear as `:"-list_media_items/1-fun-0-"`. Keying them
  # by the enclosing function keeps the key stable when edits renumber the fun.
  defp function_name(fun, arity) do
    case Atom.to_string(fun) do
      "-" <> rest ->
        case String.split(rest, "-", parts: 2) do
          [enclosing, _suffix] -> enclosing
          [_whole] -> "#{rest}/#{arity_of(arity)}"
        end

      name ->
        "#{name}/#{arity_of(arity)}"
    end
  end

  defp arity_of(args) when is_list(args), do: length(args)
  defp arity_of(arity) when is_integer(arity), do: arity

  defp module_name(module, fallback \\ @unknown)
  defp module_name(nil, fallback), do: fallback
  defp module_name(module, _fallback) when is_atom(module), do: inspect(module)
  defp module_name(_module, fallback), do: fallback
end
