defmodule Mydia.Plugins.Connect do
  @moduledoc """
  Host driver for a plugin's interactive onboarding (`on-connect`).

  A connect flow spans human time: the operator reads a code, walks to another
  device, signs in, comes back. The guest is never held open across that. Each
  turn is one invocation that returns immediately, and the host stores the
  guest's opaque `state_json` between turns, the same discipline `on-schedule`
  follows.

  Sessions live in ETS, expire after ten minutes, and are dropped the moment a
  flow finishes. An expired session and an unknown one are reported identically:
  neither can be resumed, and telling them apart only leaks that an id once
  existed.
  """

  use GenServer

  alias Mydia.Plugins.Error
  alias Mydia.Plugins.Host
  alias Mydia.Settings

  @table :plugin_connect_sessions
  @default_ttl_ms :timer.minutes(10)
  @default_interval_ms 1_000

  defmodule Session do
    @moduledoc "One in-flight onboarding conversation."

    @type status :: :pending | :prompt | :done

    @type t :: %__MODULE__{
            id: String.t(),
            slug: String.t(),
            status: status(),
            state_json: String.t(),
            message: String.t() | nil,
            code: String.t() | nil,
            verification_url: String.t() | nil,
            interval_ms: pos_integer() | nil,
            expires_at: integer(),
            fields: [map()],
            choices: [map()]
          }

    defstruct [
      :id,
      :slug,
      :status,
      :state_json,
      :message,
      :code,
      :verification_url,
      :interval_ms,
      :expires_at,
      fields: [],
      choices: []
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # The table is public because turns are driven from whichever LiveView
    # process the operator is in; this GenServer exists only to own it, so a
    # session outlives the process that started it.
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  Begins a connect flow for `slug`.

  ## Options

    * `:invoke` - `(slug, request -> {:ok, response} | {:error, term})`, injected
      in tests so the driver runs without a wasm build
    * `:ttl_ms` - session lifetime (default 10 minutes)
    * `:config_json` - override the plugin's stored settings
  """
  @spec start(String.t(), keyword()) :: {:ok, Session.t()} | {:error, Error.t()}
  def start(slug, opts \\ []) when is_binary(slug) do
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)

    session = %Session{
      id: Ecto.UUID.generate(),
      slug: slug,
      status: :pending,
      state_json: "{}",
      expires_at: System.monotonic_time(:millisecond) + ttl_ms
    }

    turn(session, "start", "{}", opts)
  end

  @doc "Advances a pending flow. Called on the interval the guest asked for."
  @spec poll(String.t(), keyword()) :: {:ok, Session.t()} | {:error, Error.t()}
  def poll(id, opts \\ []) when is_binary(id) do
    with {:ok, session} <- fetch(id) do
      turn(session, "poll", "{}", opts)
    end
  end

  @doc "Answers a prompt with the operator's input."
  @spec submit(String.t(), map(), keyword()) :: {:ok, Session.t()} | {:error, Error.t()}
  def submit(id, input, opts \\ []) when is_binary(id) and is_map(input) do
    with {:ok, session} <- fetch(id) do
      turn(session, "submit", Jason.encode!(input), opts)
    end
  end

  @doc "Abandons a flow."
  @spec cancel(String.t()) :: :ok
  def cancel(id) when is_binary(id) do
    :ets.delete(@table, id)
    :ok
  end

  defp turn(session, step, input_json, opts) do
    invoke = Keyword.get(opts, :invoke, &default_invoke/2)

    request = %{
      step: step,
      state_json: session.state_json,
      input_json: input_json,
      config_json: config_json(session.slug, opts)
    }

    case invoke.(session.slug, request) do
      {:ok, response} ->
        session |> apply_response(response) |> store()

      {:error, reason} ->
        :ets.delete(@table, session.id)
        {:error, Error.new(:internal, to_string(reason))}
    end
  end

  defp apply_response(session, {:pending, p}) do
    %{
      session
      | status: :pending,
        message: Map.get(p, :message),
        code: Map.get(p, :code),
        verification_url: Map.get(p, :verification_url),
        interval_ms: Map.get(p, :interval_ms) || @default_interval_ms,
        state_json: Map.get(p, :state_json) || "{}",
        fields: [],
        choices: []
    }
  end

  defp apply_response(session, {:prompt, p}) do
    %{
      session
      | status: :prompt,
        message: Map.get(p, :message),
        code: nil,
        verification_url: nil,
        interval_ms: nil,
        fields: Map.get(p, :fields) || [],
        choices: Map.get(p, :choices) || [],
        state_json: Map.get(p, :state_json) || "{}"
    }
  end

  defp apply_response(session, {:done, d}) do
    %{session | status: :done, message: Map.get(d, :message), fields: [], choices: []}
  end

  # A finished flow is dropped before it is handed back, so a second turn on it
  # is indistinguishable from an unknown id.
  defp store(%Session{status: :done} = session) do
    :ets.delete(@table, session.id)
    {:ok, session}
  end

  defp store(session) do
    :ets.insert(@table, {session.id, session})
    {:ok, session}
  end

  defp fetch(id) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, id) do
      [{^id, %Session{expires_at: expires_at} = session}] when expires_at > now ->
        {:ok, session}

      [{^id, _expired}] ->
        :ets.delete(@table, id)
        {:error, Error.new(:not_found, "connect session expired")}

      [] ->
        {:error, Error.new(:not_found, "no such connect session")}
    end
  end

  defp config_json(slug, opts) do
    Keyword.get_lazy(opts, :config_json, fn ->
      case Settings.get_plugin_config_by_slug(slug) do
        %{settings: settings} when is_map(settings) -> Jason.encode!(settings)
        _ -> "{}"
      end
    end)
  end

  defp default_invoke(slug, request) do
    Host.call(slug, "on-connect", request, handler: :on_connect)
  end
end
