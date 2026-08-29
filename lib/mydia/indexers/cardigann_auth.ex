defmodule Mydia.Indexers.CardigannAuth do
  @moduledoc """
  Authentication handler for private Cardigann indexers.

  Manages login flows, session cookies, and credential validation for indexers
  that require authentication. Supports multiple authentication methods:

  - **Form Login**: POST credentials to login URL, extract session cookies
  - **API Key**: Include API key in request headers or query params
  - **User Cookies**: Store and use pre-obtained session cookies

  ## Session Management

  Sessions are stored in the database with encrypted cookies and expiration tracking.
  The module automatically:
  - Validates sessions before use
  - Refreshes expired sessions
  - Handles login errors gracefully

  ## Security

  - Credentials are never logged
  - SSL certificates are validated by default
  - Session cookies are stored in the database (database security is responsibility of deployment)

  ## Examples

      # Form login
      definition = %Parsed{login: %{method: "form", path: "/login.php", ...}}
      user_config = %{username: "user", password: "pass"}
      {:ok, session} = CardigannAuth.authenticate(definition, user_config)

      # API key
      definition = %Parsed{login: %{method: "api", ...}}
      user_config = %{api_key: "secret123"}
      {:ok, session} = CardigannAuth.authenticate(definition, user_config)

      # User-provided cookies
      user_config = %{cookies: ["session=abc123; uid=456"]}
      {:ok, session} = CardigannAuth.authenticate(definition, user_config)
  """

  alias Mydia.Indexers.Cardigann.CredentialScope
  alias Mydia.Indexers.CardigannDefinition.Parsed
  alias Mydia.Indexers.CardigannSearchEngine
  alias Mydia.Indexers.CardigannSearchSession
  alias Mydia.Indexers.CardigannTemplate
  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Repo

  require Logger

  import Ecto.Query

  @type auth_method :: :form | :api_key | :cookie
  @type user_config :: %{
          optional(:username) => String.t(),
          optional(:password) => String.t(),
          optional(:api_key) => String.t(),
          optional(:cookies) => [String.t()]
        }

  @type session :: %{
          cookies: [String.t()],
          expires_at: DateTime.t(),
          method: auth_method()
        }

  # Default session expiration (7 days)
  @default_session_ttl 7 * 24 * 60 * 60

  @doc """
  Authenticates with an indexer and returns session information.

  Determines the appropriate authentication method based on the definition's
  login configuration and user-provided credentials.

  ## Parameters

  - `definition` - Parsed Cardigann definition with login config
  - `user_config` - User credentials (username/password, API key, or cookies)
  - `cardigann_definition_id` - Database ID for session storage (optional)

  ## Returns

  - `{:ok, session}` - Successful authentication with session data
  - `{:error, reason}` - Authentication failed

  ## Examples

      iex> authenticate(definition, %{username: "user", password: "pass"}, def_id)
      {:ok, %{cookies: [...], expires_at: ~U[...], method: :form}}
  """
  @spec authenticate(Parsed.t(), user_config(), String.t() | nil) ::
          {:ok, session()} | {:error, Error.t()}
  def authenticate(%Parsed{} = definition, user_config, cardigann_definition_id \\ nil) do
    method = determine_auth_method(definition, user_config)

    case method do
      :form ->
        perform_form_login(definition, user_config, cardigann_definition_id)

      :api_key ->
        perform_api_key_auth(definition, user_config)

      :cookie ->
        perform_cookie_auth(definition, user_config, cardigann_definition_id)

      :none ->
        # Public indexer, no authentication needed
        {:ok, %{cookies: [], expires_at: nil, method: :none}}
    end
  end

  @doc """
  Validates an existing session and returns whether it's still valid.

  Checks session expiration and can optionally test the session against
  the indexer's test selector.

  ## Parameters

  - `session` - Session map with cookies and expiration
  - `definition` - Parsed Cardigann definition (optional, for test validation)

  ## Returns

  - `true` - Session is valid
  - `false` - Session has expired or is invalid
  """
  @spec validate_session(session(), Parsed.t() | nil) :: boolean()
  def validate_session(%{expires_at: nil}, _definition), do: true

  def validate_session(%{expires_at: expires_at}, _definition) do
    DateTime.compare(DateTime.utc_now(), expires_at) == :lt
  end

  @doc """
  Retrieves stored session cookies for a definition from the database.

  ## Parameters

  - `cardigann_definition_id` - Database ID of the definition

  ## Returns

  - `{:ok, session}` - Session data with cookies
  - `{:error, :not_found}` - No session found
  - `{:error, :expired}` - Session exists but has expired
  """
  @spec get_stored_session(String.t()) :: {:ok, session()} | {:error, atom()}
  def get_stored_session(cardigann_definition_id) do
    query =
      from s in CardigannSearchSession,
        where: s.cardigann_definition_id == ^cardigann_definition_id,
        order_by: [desc: s.updated_at],
        limit: 1

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      %CardigannSearchSession{} = session ->
        if CardigannSearchSession.expired?(session) do
          {:error, :expired}
        else
          # session.cookies is now directly a list (not wrapped in a map)
          cookies = session.cookies || []

          {:ok,
           %{
             cookies: cookies,
             expires_at: session.expires_at,
             method: :form
           }}
        end
    end
  end

  @doc """
  Stores session cookies in the database.

  ## Parameters

  - `cardigann_definition_id` - Database ID of the definition
  - `cookies` - List of cookie strings to store
  - `expires_at` - Session expiration time (optional, defaults to 7 days)

  ## Returns

  - `{:ok, session_record}` - Successfully stored session
  - `{:error, changeset}` - Storage failed
  """
  @spec store_session(String.t(), [String.t()], DateTime.t() | nil) ::
          {:ok, CardigannSearchSession.t()} | {:error, Ecto.Changeset.t()}
  def store_session(cardigann_definition_id, cookies, expires_at \\ nil) do
    expires_at = expires_at || DateTime.add(DateTime.utc_now(), @default_session_ttl, :second)

    attrs = %{
      cardigann_definition_id: cardigann_definition_id,
      cookies: cookies,
      expires_at: expires_at
    }

    %CardigannSearchSession{}
    |> CardigannSearchSession.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Refreshes an expired session by re-authenticating.

  ## Parameters

  - `definition` - Parsed Cardigann definition
  - `user_config` - User credentials for re-authentication
  - `cardigann_definition_id` - Database ID for session storage

  ## Returns

  - `{:ok, session}` - New session after successful re-authentication
  - `{:error, reason}` - Re-authentication failed
  """
  @spec refresh_session(Parsed.t(), user_config(), String.t()) ::
          {:ok, session()} | {:error, Error.t()}
  def refresh_session(definition, user_config, cardigann_definition_id) do
    Logger.info("Refreshing session for indexer: #{definition.id}")
    authenticate(definition, user_config, cardigann_definition_id)
  end

  # Private Functions

  defp determine_auth_method(%Parsed{login: nil}, user_config) do
    # Even if no login config, allow user-provided cookies
    cond do
      Map.has_key?(user_config, :cookies) -> :cookie
      Map.has_key?(user_config, :api_key) -> :api_key
      true -> :none
    end
  end

  defp determine_auth_method(%Parsed{login: login}, user_config) do
    cond do
      # User provided cookies directly
      Map.has_key?(user_config, :cookies) ->
        :cookie

      # User provided API key
      Map.has_key?(user_config, :api_key) ->
        :api_key

      # Form login if username/password provided
      Map.has_key?(user_config, :username) && Map.has_key?(user_config, :password) ->
        :form

      # Check login method from definition
      Map.get(login, :method) == "form" ->
        :form

      Map.get(login, :method) == "api" ->
        :api_key

      true ->
        :none
    end
  end

  defp perform_form_login(definition, user_config, cardigann_definition_id) do
    with {:ok, login_url} <- build_login_url(definition, config_for(user_config)),
         :ok <- check_login_transport(login_url),
         {:ok, login_params} <- build_login_params(definition, user_config),
         {:ok, response} <- execute_login_request(definition, login_url, login_params),
         {:ok, cookies} <- extract_cookies(response),
         :ok <- validate_login_success(definition, response, cookies) do
      # Store session if definition ID provided
      if cardigann_definition_id do
        store_session(cardigann_definition_id, cookies)
      end

      {:ok, %{cookies: cookies, expires_at: calculate_expiration(), method: :form}}
    end
  end

  # A form login POSTs the username and password, and #601 already withholds a
  # session cookie from a cleartext non-loopback host. That asymmetry is the
  # hole: Mydia would send the password in the clear, receive a session, and
  # then refuse to use it, so the login leaks the credentials and buys nothing.
  #
  # There is deliberately NO origin check here, and one should not be added. The
  # login URL is derived from the definition, and the definition also defines
  # the credential scope, so comparing them is circular: trusted_origins/2
  # includes an absolute login.path's own origin by construction. An adversary
  # who can set login.path can set links too.
  defp check_login_transport(login_url) do
    if CredentialScope.cleartext?(login_url) do
      {:error,
       Error.connection_failed(
         "Refusing to send credentials to #{login_url} over an unencrypted connection. " <>
           "Configure an https URL for this indexer."
       )}
    else
      :ok
    end
  end

  # The adapter passes the operator's settings under :config alongside the
  # credentials. The bare-map fallback covers a direct caller (tests, and
  # authenticate/3 called with a plain settings map) that passes settings
  # without wrapping them.
  defp config_for(user_config) when is_map(user_config) do
    case Map.get(user_config, :config) || Map.get(user_config, "config") do
      %{} = config -> config
      _ -> user_config
    end
  end

  defp config_for(_user_config), do: %{}

  defp perform_api_key_auth(_definition, user_config) do
    case Map.get(user_config, :api_key) do
      nil ->
        {:error, Error.connection_failed("API key required but not provided")}

      api_key ->
        # API key auth doesn't use cookies, instead we'll pass the key in headers
        {:ok,
         %{
           cookies: [],
           api_key: api_key,
           expires_at: nil,
           method: :api_key
         }}
    end
  end

  defp perform_cookie_auth(_definition, user_config, cardigann_definition_id) do
    case Map.get(user_config, :cookies) do
      nil ->
        {:error, Error.connection_failed("Cookies required but not provided")}

      cookies when is_list(cookies) ->
        # Store cookies if definition ID provided
        if cardigann_definition_id do
          store_session(cardigann_definition_id, cookies)
        end

        {:ok, %{cookies: cookies, expires_at: calculate_expiration(), method: :cookie}}

      cookie_string when is_binary(cookie_string) ->
        cookies = [cookie_string]

        if cardigann_definition_id do
          store_session(cardigann_definition_id, cookies)
        end

        {:ok, %{cookies: cookies, expires_at: calculate_expiration(), method: :cookie}}
    end
  end

  @doc """
  Builds the login URL for a definition.

  The path is rendered first, because five shipped v11 definitions declare
  `login.path` as `https://{{ .Config.apiurl }}/...`, and then joined with
  `build_full_url/2` so an absolute path is used as-is rather than appended to
  the site link. Concatenating one produced
  `https://abn.lol/https://{{ .Config.apiurl }}/api`, curly braces intact.
  """
  @spec build_login_url(Parsed.t(), map()) :: {:ok, String.t()} | {:error, Error.t()}
  def build_login_url(%Parsed{} = definition, config) do
    with {:ok, path} <- login_path(definition),
         {:ok, base_url} <- site_link(definition),
         {:ok, rendered} <- render_login_path(path, definition, config) do
      {:ok, CardigannSearchEngine.build_full_url(String.trim_trailing(base_url, "/"), rendered)}
    end
  end

  defp login_path(%Parsed{login: %{path: path}}) when is_binary(path), do: {:ok, path}
  defp login_path(%Parsed{}), do: {:error, Error.search_failed("Login path not configured")}

  defp site_link(%Parsed{links: [link | _]}) when is_binary(link), do: {:ok, link}
  defp site_link(%Parsed{}), do: {:error, Error.search_failed("No site link configured")}

  defp render_login_path(path, %Parsed{} = definition, config) do
    context = %{
      keywords: "",
      config: config,
      query: %{series: "", season: nil, episode: nil, imdb_id: nil, tmdb_id: nil, tvdb_id: nil},
      categories: [],
      settings: definition.settings
    }

    case CardigannTemplate.render(path, context, url_encode: false) do
      {:ok, rendered} ->
        {:ok, rendered}

      {:error, reason} ->
        {:error, Error.search_failed("Login path failed to render: #{inspect(reason)}")}
    end
  end

  defp build_login_params(%Parsed{login: login}, user_config) do
    inputs = Map.get(login, :inputs, %{})

    # Substitute username and password in input template
    params =
      Enum.reduce(inputs, %{}, fn {key, value}, acc ->
        substituted_value =
          value
          |> String.replace("{{ .Config.username }}", Map.get(user_config, :username, ""))
          |> String.replace("{{ .Config.password }}", Map.get(user_config, :password, ""))

        Map.put(acc, key, substituted_value)
      end)

    {:ok, params}
  end

  defp execute_login_request(definition, url, params) do
    Logger.debug("Executing login request to #{url}")

    # Determine login method (GET or POST)
    method =
      case Map.get(definition.login, :method, "post") do
        "get" -> :get
        _ -> :post
      end

    req_opts = [
      headers: [{"Content-Type", "application/x-www-form-urlencoded"}],
      form: params,
      redirect: true,
      receive_timeout: 30_000
    ]

    case method do
      :post ->
        Req.post(url, req_opts)

      :get ->
        Req.get(url, Keyword.put(req_opts, :params, params))
    end
    |> case do
      {:ok, %Req.Response{} = response} ->
        {:ok, response}

      {:error, reason} ->
        {:error, Error.connection_failed("Login request failed: #{inspect(reason)}")}
    end
  end

  defp extract_cookies(%Req.Response{headers: headers}) do
    cookies =
      headers
      |> Enum.filter(fn
        {name, _value} when is_binary(name) -> String.downcase(name) == "set-cookie"
        _ -> false
      end)
      |> Enum.flat_map(fn
        {_name, values} when is_list(values) ->
          Enum.map(values, &parse_cookie/1)

        {_name, value} when is_binary(value) ->
          [parse_cookie(value)]

        _ ->
          []
      end)
      |> Enum.reject(&is_nil/1)

    if cookies == [] do
      Logger.warning("No cookies received from login response")
    end

    {:ok, cookies}
  end

  defp parse_cookie(cookie_string) when is_binary(cookie_string) do
    # Extract just the cookie name=value part, ignore attributes like Path, Domain, etc.
    case String.split(cookie_string, ";", parts: 2) do
      [cookie_value | _] -> String.trim(cookie_value)
      _ -> nil
    end
  end

  defp parse_cookie(_), do: nil

  defp validate_login_success(definition, response, cookies) do
    # Check for error selectors first
    case Map.get(definition.login, :error) do
      error_selectors when is_list(error_selectors) and error_selectors != [] ->
        case check_error_selectors(response.body, error_selectors) do
          {:error, _} = error -> error
          :ok -> validate_login_test(definition, response, cookies)
        end

      _ ->
        validate_login_test(definition, response, cookies)
    end
  end

  defp check_error_selectors(body, error_selectors) do
    case Floki.parse_document(body) do
      {:ok, document} ->
        # Check if any error selectors match
        errors =
          Enum.filter(error_selectors, fn error_config ->
            selector = Map.get(error_config, :selector)
            selector && Floki.find(document, selector) != []
          end)

        if errors != [] do
          {:error, Error.connection_failed("Login failed: Error detected on page")}
        else
          :ok
        end

      {:error, _} ->
        # Can't parse HTML, skip error check
        :ok
    end
  end

  defp validate_login_test(%Parsed{login: login}, response, _cookies) do
    case Map.get(login, :test) do
      nil ->
        # No test configured, assume success
        :ok

      test_config when is_map(test_config) ->
        # Test has a selector that should be present after successful login
        selector = Map.get(test_config, :selector) || Map.get(test_config, "selector")

        if selector do
          case Floki.parse_document(response.body) do
            {:ok, document} ->
              if Floki.find(document, selector) != [] do
                :ok
              else
                {:error,
                 Error.connection_failed("Login validation failed: test selector not found")}
              end

            {:error, _} ->
              {:error, Error.connection_failed("Login validation failed: invalid HTML response")}
          end
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  defp calculate_expiration do
    DateTime.add(DateTime.utc_now(), @default_session_ttl, :second)
  end
end
