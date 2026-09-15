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

  Some queries have no application frame at all, such as Oban's own
  bookkeeping (job fetching, `BEGIN`/`COMMIT`). Rather than collapse all of
  these into one unactionable `"unknown"` key, `caller/1` falls back to the
  first frame belonging to a library (any Elixir module other than `Ecto`,
  `DBConnection`, or `Mydia.Repo`), so `oban_jobs` queries key by the Oban
  function that issued them instead of by nothing at all. Application frames
  still take priority over library frames wherever both appear.
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
      %{job: %Oban.Job{worker: worker}} = metadata
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
  `Module.fun/arity`.

  When no such application frame exists, falls back to the first frame
  belonging to any other Elixir module, excluding `Ecto`, `DBConnection`, and
  `Mydia.Repo`, formatted the same way. Erlang modules (`:gen_server`,
  `:proc_lib`, and the like) are never used. Returns `"unknown"` only when
  neither kind of frame is present. A single pass over the stacktrace finds
  the application frame while remembering the first library candidate, since
  this runs on every query.
  """
  @spec caller(term()) :: String.t()
  def caller(stacktrace) when is_list(stacktrace) do
    stacktrace
    |> Enum.reduce_while(nil, fn
      {module, fun, arity, _location}, library_candidate when is_atom(module) and is_atom(fun) ->
        cond do
          application_module?(module) ->
            {:halt, format_frame(module, fun, arity)}

          is_nil(library_candidate) and library_module?(module) ->
            {:cont, format_frame(module, fun, arity)}

          true ->
            {:cont, library_candidate}
        end

      _other, library_candidate ->
        {:cont, library_candidate}
    end)
    |> case do
      nil -> @unknown
      frame -> frame
    end
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

  defp library_module?(Mydia.Repo), do: false

  defp library_module?(module) do
    name = Atom.to_string(module)

    String.starts_with?(name, "Elixir.") and not under_namespace?(name, "Ecto") and
      not under_namespace?(name, "DBConnection")
  end

  defp under_namespace?(name, namespace) do
    name == "Elixir.#{namespace}" or String.starts_with?(name, "Elixir.#{namespace}.")
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
