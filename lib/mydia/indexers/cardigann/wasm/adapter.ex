defmodule Mydia.Indexers.Cardigann.Wasm.Adapter do
  @moduledoc """
  A counterpart to `Mydia.Indexers.Adapter.Cardigann` that runs Prowlarr's
  Cardigann engine under Wasmex (`Mydia.Indexers.Cardigann.Wasm.Engine`).

  `search/3`, `test_connection/1` and `get_capabilities/1` return the same
  shapes as the Elixir adapter. `download/3` and `login/2` have no Elixir
  adapter counterpart:

    * `download/3` returns `{:ok, {:bytes, binary}}` for a torrent file,
      `{:ok, {:magnet, url}}` for a magnet and `{:ok, {:link, url}}` otherwise.
    * `login/2` takes `nil` or a `%{answer: String.t(), state: String.t()}`
      captcha answer and returns `{:ok, session}` or
      `{:captcha, %{image: binary, content_type: String.t(), state: String.t()}}`.

  The engine's own errors come back unchanged: an unavailable engine is
  `:engine_unavailable`, never a silent fall back to the Elixir engine.
  When the Cardigann feature flag is off the adapter behaves as the Elixir one.

  ## Sessions

  The guest keeps its cookies in a session handed in and out of each call. The
  stored session is the definition's single `cardigann_search_sessions` row, read
  and written only through `CardigannAuth.get_stored_session/1` and
  `store_session/3` (`"name=value"` strings; the Elixir engine reads the same
  row). There is no fixed expiry: the row is stored with a nil expiry.
  Prowlarr updates its cookies after every fetch, so the guest reports a changed
  session on every search; the row is written only when the cookies or expiry
  differ from what was passed in (the guest's rolling expiry is ignored). A definition in `needs_login` (set by the
  Elixir engine when a login needs a person) is skipped with a `:login_required`
  error by `search/3`, `test_connection/1` and `download/3`, as the Elixir
  adapter skips it; `login/2` is exempt, and storing a session through it moves
  the definition back to healthy.

  ## Failed logins

  When a login fails during `search/3`, Prowlarr's engine swallows it and the
  search returns `{:ok, []}`. The Elixir adapter returns an authentication error
  instead. `login/2` is where the failure surfaces
  (`{:error, %Error{type: :authentication_failed}}`).

  Setting values are credentials and are never logged.
  """

  @behaviour Mydia.Indexers.Adapter

  require Logger

  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.Cardigann.AdapterSupport
  alias Mydia.Indexers.Cardigann.Wasm.Engine
  alias Mydia.Indexers.{CardigannAuth, CardigannDefinition, CardigannFeatureFlags}
  alias Mydia.Indexers.Cardigann.SessionManager
  alias Mydia.Repo

  import AdapterSupport,
    only: [apply_search_filters: 2, blank?: 1, fetch_definition: 1, setting: 2]

  @default_timeout_ms 60_000
  @empty_session %{cookies: %{}, expires_at: nil}

  @impl true
  def test_connection(config) do
    if CardigannFeatureFlags.enabled?() do
      with {:ok, definition, doc} <- load(config),
           :ok <- check_login_needed(definition, doc),
           session = stored_session(definition),
           {:ok, new_session} <-
             run(
               {:test, definition.definition, guest_settings(definition, config, doc), session},
               definition,
               config,
               doc,
               []
             ) do
        persist_session(definition, new_session, session)

        {:ok,
         %{
           name: doc["name"],
           type: doc["type"],
           language: doc["language"],
           indexer_id: doc["id"]
         }}
      end
    else
      Logger.debug("Cardigann test connection skipped - feature disabled")
      {:error, Error.invalid_config("Cardigann feature is disabled")}
    end
  end

  @impl true
  def search(config, query, opts \\ []) do
    if CardigannFeatureFlags.enabled?() do
      with {:ok, definition, doc} <- load(config),
           :ok <- check_login_needed(definition, doc),
           session = stored_session(definition),
           call =
             {:search, definition.definition, guest_settings(definition, config, doc),
              build_query(query, opts), session},
           {:ok, out} <- run(call, definition, config, doc, opts) do
        if out.session_changed, do: persist_session(definition, out.session, session)
        {:ok, apply_search_filters(out.releases, opts)}
      end
    else
      Logger.debug("Cardigann search skipped - feature disabled")
      {:ok, []}
    end
  end

  @impl true
  def get_capabilities(config) do
    with {:ok, definition, doc} <- load(config),
         {:ok, caps} <- run({:capabilities, definition.definition}, definition, config, doc, []) do
      {:ok, build_capabilities(caps)}
    end
  end

  @doc """
  Resolves a release's download link through the definition. See the moduledoc
  for the return shapes.
  """
  @spec download(map(), String.t(), keyword()) ::
          {:ok, {:bytes, binary()} | {:magnet, String.t()} | {:link, String.t()}}
          | {:error, Error.t()}
  def download(config, link, opts \\ []) do
    if CardigannFeatureFlags.enabled?() do
      with {:ok, definition, doc} <- load(config),
           :ok <- check_login_needed(definition, doc),
           session = stored_session(definition),
           call =
             {:download, definition.definition, guest_settings(definition, config, doc), link,
              session},
           {:ok, out} <- run(call, definition, config, doc, opts) do
        persist_session(definition, out.session, session)
        {:ok, download_payload(out.payload)}
      end
    else
      {:error, Error.invalid_config("Cardigann feature is disabled")}
    end
  end

  @doc """
  Logs in and stores the session. `captcha_answer` is `nil` for the first
  attempt, or the answer to a challenge this function returned earlier.
  """
  @spec login(map(), %{answer: String.t(), state: String.t()} | nil, keyword()) ::
          {:ok, map()}
          | {:captcha, %{image: binary(), content_type: String.t(), state: String.t()}}
          | {:error, Error.t()}
  def login(config, captcha_answer, opts \\ []) do
    if CardigannFeatureFlags.enabled?() do
      with {:ok, definition, doc} <- load(config),
           call =
             {:login, definition.definition, guest_settings(definition, config, doc),
              @empty_session, normalize_answer(captcha_answer)},
           {:ok, result} <- run(call, definition, config, doc, opts) do
        case result do
          {:ok, session} ->
            persist_session(definition, session, @empty_session)
            {:ok, session}

          {:captcha, _challenge} = captcha ->
            captcha
        end
      end
    else
      {:error, Error.invalid_config("Cardigann feature is disabled")}
    end
  end

  # ── Definition and settings ───────────────────────────────────────────────

  defp load(config) do
    with {:ok, definition} <- fetch_definition(config),
         {:ok, doc} <- parse_yaml(definition) do
      {:ok, definition, doc}
    end
  end

  defp parse_yaml(%CardigannDefinition{definition: yaml}) do
    case YamlElixir.read_from_string(yaml || "") do
      {:ok, %{} = doc} ->
        {:ok, doc}

      {:ok, _not_a_map} ->
        Logger.error("Failed to parse Cardigann definition: not a YAML mapping")
        {:error, Error.search_failed("Invalid definition")}

      {:error, %{__exception__: true} = e} ->
        Logger.error("Failed to parse Cardigann definition: #{Exception.message(e)}")
        {:error, Error.search_failed("Invalid definition")}

      {:error, _reason} ->
        Logger.error("Failed to parse Cardigann definition: YAML syntax error")
        {:error, Error.search_failed("Invalid definition")}
    end
  end

  @doc false
  # Settings for the guest from the adapter config (its `user_settings` over the
  # definition's stored config), or from a bare user-settings map.
  def guest_settings(definition, %{} = config, doc) when is_map(doc) do
    guest_settings(definition, setting(config, :user_settings) || %{}, declared_settings(doc))
  end

  def guest_settings(%CardigannDefinition{} = definition, user_settings, declared)
      when is_list(declared) do
    stored = stringify_keys(definition.config || %{})

    stored
    |> Map.merge(stringify_keys(user_settings || %{}))
    |> Map.reject(fn {_name, value} -> blank?(value) end)
    |> map_cookies(declared)
    |> Map.new(fn {name, value} -> {name, stringify(value)} end)
  end

  # The Elixir adapter's `cookies` setting is Prowlarr's `cookie` setting, but
  # only a definition that declares one has anywhere to put it.
  defp map_cookies(settings, declared) do
    cond do
      "cookies" in declared ->
        settings

      "cookie" in declared ->
        {cookies, rest} = Map.pop(settings, "cookies")
        if blank?(cookies), do: rest, else: Map.put_new(rest, "cookie", stringify(cookies))

      true ->
        Map.delete(settings, "cookies")
    end
  end

  defp declared_settings(doc) do
    doc
    |> Map.get("settings")
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"name" => name} when is_binary(name) -> [name]
      _ -> []
    end)
  end

  defp stringify_keys(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_list(value), do: Enum.map_join(value, "; ", &stringify/1)
  defp stringify(value) when is_map(value), do: Jason.encode!(value)
  defp stringify(value), do: to_string(value)

  # ── Engine call ───────────────────────────────────────────────────────────

  defp run(call, definition, config, doc, opts) do
    Engine.call(
      call,
      ctx(definition, config, doc),
      Keyword.get(opts, :timeout, @default_timeout_ms)
    )
  end

  defp ctx(definition, config, doc) do
    base = %{
      definition_id: definition.id,
      request_delay_ms: request_delay_ms(doc["requestDelay"] || doc["requestdelay"]),
      flaresolverr: AdapterSupport.build_flaresolverr_opts(definition),
      indexer_name: setting(config, :name) || definition.name
    }

    case gate_opts() do
      [] -> base
      gate_opts -> Map.put(base, :gate_opts, gate_opts)
    end
  end

  @test_env? Application.compile_env(:mydia, :env) == :test

  @doc false
  # Test seam so Bypass on localhost passes the SSRF gate. HostHttp merges these
  # over the gate defaults, so outside the test env they are ignored, and even
  # there only the one relaxation the tests need is taken.
  @spec gate_opts() :: keyword()
  def gate_opts do
    if @test_env? do
      :mydia
      |> Application.get_env(:cardigann_wasm_gate_opts, [])
      |> Keyword.take([:allow_private_except_link_local])
    else
      []
    end
  end

  @doc """
  The YAML `requestDelay` in milliseconds, normalised exactly as
  `CardigannSearchEngine.apply_rate_limit/1` does: below 10 it is seconds
  (possibly fractional), from 10 up it already is milliseconds.
  """
  @spec request_delay_ms(term()) :: non_neg_integer()
  def request_delay_ms(delay) when is_number(delay) and delay < 10, do: trunc(delay * 1000)
  def request_delay_ms(delay) when is_number(delay), do: trunc(delay)
  def request_delay_ms(_none), do: 0

  defp build_query(term, opts) do
    season = Keyword.get(opts, :season)
    episode = Keyword.get(opts, :episode)
    imdb_id = Keyword.get(opts, :imdb_id)
    tmdb_id = Keyword.get(opts, :tmdb_id)

    kind =
      cond do
        season || episode -> :tv
        imdb_id || tmdb_id -> :movie
        true -> :search
      end

    %{
      kind: kind,
      term: term,
      categories: Keyword.get(opts, :categories, []),
      imdb_id: imdb_id,
      tmdb_id: tmdb_id,
      tvdb_id: Keyword.get(opts, :tvdb_id),
      season: season,
      episode: episode && to_string(episode),
      limit: nil,
      offset: nil
    }
  end

  defp normalize_answer(nil), do: nil

  defp normalize_answer(%{} = answer),
    do: %{answer: setting(answer, :answer), state: setting(answer, :state)}

  defp download_payload({:bytes, _} = bytes), do: bytes
  defp download_payload({:link, "magnet:" <> _ = magnet}), do: {:magnet, magnet}
  defp download_payload({:link, _} = link), do: link

  defp build_capabilities(caps) do
    %{
      searching: %{
        search: %{available: Map.get(caps, "SearchAvailable", true), supported_params: ["q"]},
        tv_search: %{
          available: Map.get(caps, "TvSearchAvailable", false),
          supported_params: ["q", "season", "ep"]
        },
        movie_search: %{
          available: Map.get(caps, "MovieSearchAvailable", false),
          supported_params: ["q", "imdbid", "tmdbid"]
        }
      },
      categories:
        caps
        |> Map.get("Categories", [])
        |> Enum.map(&%{id: &1["Id"], name: &1["Name"]})
        |> Enum.filter(&is_integer(&1.id))
    }
  end

  # ── Session persistence ───────────────────────────────────────────────────

  # The stored session as the guest's session type. A missing or expired row is
  # an empty session, which makes the guest log in.
  defp stored_session(%CardigannDefinition{id: id}) do
    case CardigannAuth.get_stored_session(id) do
      {:ok, %{cookies: cookies, expires_at: expires_at}} ->
        %{cookies: cookies_to_map(cookies), expires_at: expires_at}

      {:error, _not_found_or_expired} ->
        @empty_session
    end
  end

  defp cookies_to_map(cookies) do
    for cookie when is_binary(cookie) <- List.wrap(cookies),
        [name, value] <- [String.split(cookie, "=", parts: 2)],
        into: %{},
        do: {String.trim(name), value}
  end

  defp persist_session(definition, new, passed_in) do
    if session_changed?(new, passed_in) do
      write_session(definition, new)
    else
      :ok
    end
  rescue
    e ->
      Logger.warning("Could not store Cardigann session: #{Exception.message(e)}")
      :ok
  end

  # Only the cookies count. Prowlarr hands back a rolling expiry (now plus its
  # default lifetime) on every fetch, so comparing expiries would rewrite the row
  # on every search; and Mydia keeps no fixed expiry, so none is stored.
  defp session_changed?(%{cookies: new_cookies}, %{cookies: old_cookies}),
    do: new_cookies != old_cookies

  defp write_session(_definition, %{cookies: cookies}) when map_size(cookies) == 0, do: :ok

  # One row per definition, no fixed expiry: `store_session/3` upserts with a nil
  # expiry, so the session lives until the tracker stops honoring it. A definition waiting on a
  # person (`needs_login`) is moved back to healthy, as `SessionManager.store/2`
  # does for the Elixir engine.
  defp write_session(definition, %{cookies: cookies}) do
    pairs = cookies |> Enum.sort() |> Enum.map(fn {name, value} -> "#{name}=#{value}" end)

    case CardigannAuth.store_session(definition.id, pairs, nil) do
      {:ok, _row} ->
        clear_needs_login(definition)

      {:error, _changeset} ->
        Logger.warning("Cardigann #{definition.indexer_id}: could not save the login session")
        :ok
    end
  end

  defp clear_needs_login(%CardigannDefinition{health_status: "needs_login"} = definition) do
    definition
    |> CardigannDefinition.health_check_changeset(%{
      health_status: "healthy",
      last_health_check_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update()

    Phoenix.PubSub.broadcast(
      Mydia.PubSub,
      SessionManager.topic(),
      {:cardigann_health_changed, definition.id}
    )

    :ok
  end

  defp clear_needs_login(_definition), do: :ok

  # Same gate the Elixir engine applies in `SessionManager.user_config/2`: a
  # definition with a login block that is waiting on a person is skipped, not
  # searched anonymously.
  defp check_login_needed(%CardigannDefinition{health_status: "needs_login"} = definition, doc) do
    if is_map(doc["login"]) do
      {:error,
       Error.login_required("#{definition.name} needs someone to log in from the Indexers page")}
    else
      :ok
    end
  end

  defp check_login_needed(_definition, _doc), do: :ok
end
