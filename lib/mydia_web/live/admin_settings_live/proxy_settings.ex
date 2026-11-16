defmodule MydiaWeb.AdminSettingsLive.ProxySettings do
  @moduledoc """
  What the Outbound proxy row of Admin Settings shows, and what its edit modal
  writes.

  The URL shown is `Mydia.Net.Proxy.current/0`, the proxy requests actually
  use, never a `config_settings` row: a second reader is how a row comes to
  contradict the client behind it (see `flaresolverr_values_and_sources` in
  `MydiaWeb.AdminIndexersLive.Index`). Its password is always masked
  (`http://user:****@host:port`), so the modal is prefilled with the masked
  form and `save/3` puts the stored password back when it is submitted
  unchanged.

  A source is `:env` (`MYDIA_PROXY_*`), `:database`, `:default` (YAML or the
  schema default, as `Mydia.Settings.config_source/3` reports it), or
  `:standard_env` when the value falls back to `HTTPS_PROXY` / `HTTP_PROXY` /
  `NO_PROXY`. A database row outranks that fallback, so it reads as
  `:database` even while the fallback variables are set.
  """

  alias Mydia.Config.Schema.Proxy, as: ProxyConfig
  alias Mydia.Net.Proxy
  alias Mydia.Settings

  @url_key "proxy.url"
  @bypass_key "proxy.bypass"
  @url_env "MYDIA_PROXY_URL"
  @bypass_env "MYDIA_PROXY_BYPASS"
  @standard_url_vars ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"]
  @standard_bypass_vars ["NO_PROXY", "no_proxy"]
  @mask "****"

  defstruct url: nil,
            bypass: nil,
            url_source: :default,
            bypass_source: :default,
            configured?: false

  @type source :: :env | :database | :default | :standard_env
  @type t :: %__MODULE__{
          url: String.t() | nil,
          bypass: String.t() | nil,
          url_source: source(),
          bypass_source: source(),
          configured?: boolean()
        }

  @doc "The effective proxy, masked, and where each value came from."
  @spec current((String.t() -> String.t() | nil)) :: t()
  def current(getenv \\ &System.get_env/1) do
    proxy = Proxy.current()
    db = Settings.applied_config_settings_by_key()

    %__MODULE__{
      url: proxy && proxy.display_url,
      bypass: bypass_string(proxy, getenv),
      url_source: source(@url_env, @url_key, db, getenv, proxy && proxy.url_from),
      bypass_source: source(@bypass_env, @bypass_key, db, getenv, proxy && proxy.bypass_from),
      configured?: not is_nil(proxy)
    }
  end

  defp source(env_var, key, db, getenv, from) do
    cond do
      Settings.env_var_set?(env_var, getenv) -> :env
      Settings.config_source(nil, key, db) == :database -> :database
      from == :standard_env -> :standard_env
      true -> :default
    end
  end

  defp bypass_string(%Proxy{bypass_from: :standard_env}, getenv),
    do: first_present(@standard_bypass_vars, getenv)

  defp bypass_string(_proxy, _getenv), do: layered_config().bypass

  @doc "The modal's validation, shared with config loading."
  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(params), do: ProxyConfig.changeset(%ProxyConfig{}, params)

  @doc "The params the modal opens with."
  @spec form_params(t()) :: map()
  def form_params(%__MODULE__{} = settings),
    do: %{"url" => settings.url || "", "bypass" => settings.bypass || ""}

  @doc "Where the Test proxy button sends its request."
  @spec test_target() :: String.t()
  def test_target, do: String.trim_trailing(Mydia.Metadata.metadata_relay_url(), "/") <> "/health"

  @doc """
  Writes the fields the modal changed, as `proxy` rows.

  A field set by its `MYDIA_PROXY_*` variable is never written (it renders
  disabled, so it is not even submitted), and a field equal to what the row
  shows is skipped, so opening and saving the modal never pins a YAML,
  default or fallback value into the database. Both writes happen in one
  transaction. Returns the keys written.
  """
  @spec save(map(), binary() | nil, (String.t() -> String.t() | nil)) ::
          {:ok, [String.t()]} | {:error, Ecto.Changeset.t()} | {:error, String.t(), term()}
  def save(params, user_id, getenv \\ &System.get_env/1) do
    settings = current(getenv)

    with {:ok, data} <- Ecto.Changeset.apply_action(changeset(params), :insert) do
      [
        {@url_key, settings.url_source, settings.url, data.url},
        {@bypass_key, settings.bypass_source, settings.bypass, data.bypass}
      ]
      |> Enum.reject(fn {_key, source, shown, submitted} ->
        source == :env or (shown || "") == (submitted || "")
      end)
      |> Enum.map(fn {key, _source, _shown, value} -> {key, unmask(key, value, getenv)} end)
      |> write(user_id)
    end
  end

  defp write(changes, user_id) do
    fn ->
      Enum.reduce(changes, [], fn {key, value}, written ->
        attrs = %{key: key, value: value || "", category: :proxy, updated_by_id: user_id}

        case Settings.upsert_config_setting(attrs) do
          {:ok, _setting} -> [key | written]
          {:error, reason} -> Mydia.Repo.rollback({key, reason})
        end
      end)
    end
    |> Mydia.Repo.transaction()
    |> case do
      {:ok, written} -> {:ok, Enum.reverse(written)}
      {:error, {key, reason}} -> {:error, key, reason}
    end
  end

  # The modal shows `user:****@`, so an edit that keeps that placeholder means
  # "keep the stored password", taken from the raw URL behind the current
  # proxy. A different user name, or no stored URL, keeps the text as typed.
  defp unmask(@url_key, url, getenv) when is_binary(url) do
    with %URI{userinfo: userinfo} = uri when is_binary(userinfo) <- URI.parse(url),
         [user, @mask] <- String.split(userinfo, ":", parts: 2),
         %URI{userinfo: raw_userinfo} when is_binary(raw_userinfo) <-
           URI.parse(raw_url(getenv) || ""),
         [^user, _password] <- String.split(raw_userinfo, ":", parts: 2) do
      URI.to_string(%{uri | userinfo: raw_userinfo})
    else
      _ -> url
    end
  end

  defp unmask(_key, value, _getenv), do: value

  defp raw_url(getenv) do
    case Proxy.current() do
      %Proxy{url_from: :standard_env} -> first_present(@standard_url_vars, getenv)
      %Proxy{} -> layered_config().url
      nil -> nil
    end
  end

  defp layered_config, do: Settings.get_runtime_config().proxy || %ProxyConfig{}

  defp first_present(vars, getenv) do
    Enum.find_value(vars, fn var ->
      case getenv.(var) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end
end
