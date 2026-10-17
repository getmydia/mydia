defmodule Mydia.UpdateCheck do
  @moduledoc """
  Asks the metadata relay whether a newer Mydia release exists, so the admin
  System page can say so.

  The check sends exactly four values, and nothing else:

    * `install_id`: 64 random hex characters generated for this purpose on
      the first check and kept in `config_settings`. Mydia sends it nowhere
      else, so it cannot be joined to feedback, crash reports or pairing.
    * `version`: this install's Mydia version.
    * `arch`: the CPU architecture the BEAM was built for.
    * `db`: `sqlite` or `postgres`.

  The relay keeps one row per install per week and no address, which is how
  the developers count active installs and see which versions, architectures
  and databases are worth prioritising. See `MetadataRelay.UpdateCheck`.

  It runs shortly after boot and weekly after that (`Mydia.Jobs.UpdateCheck`).
  It is on by default. `UPDATE_CHECK_ENABLED=false` turns it off and wins over
  the admin toggle; otherwise the toggle (`update_check.enabled`) decides.
  The operator-facing description lives under "Update check" in
  `docs/using/reference/environment-variables.md`; keep the two in step.
  """

  require Logger

  alias Mydia.Settings

  @env_var "UPDATE_CHECK_ENABLED"
  @enabled_key "update_check.enabled"
  @install_id_key "update_check.install_id"
  @latest_key {__MODULE__, :latest}
  @timeout 10_000

  @type release :: %{version: String.t(), url: String.t() | nil}

  @doc "The environment variable that turns the check off."
  @spec env_var() :: String.t()
  def env_var, do: @env_var

  @doc """
  Whether the check runs: the environment variable when set, then the admin
  toggle, then on.
  """
  @spec enabled?((String.t() -> String.t() | nil)) :: boolean()
  def enabled?(getenv \\ &System.get_env/1) do
    if Settings.env_var_set?(@env_var, getenv) do
      Settings.parse_setting_boolean(getenv.(@env_var))
    else
      case Settings.get_config_setting_by_key(@enabled_key) do
        nil -> true
        setting -> Settings.parse_setting_boolean(setting.value)
      end
    end
  rescue
    _ -> true
  end

  @doc """
  Runs one check when enabled and remembers the answer for
  `available_update/0`. Never raises; failures are logged at debug level only,
  since an install with no route to the relay is not an error worth showing.

  Options: `:relay_url` (defaults to the configured metadata relay) and
  `:getenv`, both for tests.
  """
  @spec run(keyword()) :: {:ok, release() | nil} | :disabled | {:error, term()}
  def run(opts \\ []) do
    if enabled?(Keyword.get(opts, :getenv, &System.get_env/1)) do
      check(Keyword.get_lazy(opts, :relay_url, &Mydia.Metadata.metadata_relay_url/0))
    else
      forget()
      :disabled
    end
  end

  defp check(relay_url) do
    case Req.post("#{relay_url}/update-check",
           json: payload(),
           receive_timeout: @timeout,
           retry: false
         ) do
      {:ok, %Req.Response{status: 200, body: %{"latest_version" => version} = body}} ->
        latest = if is_binary(version), do: %{version: version, url: https_url(body)}
        :persistent_term.put(@latest_key, latest)
        {:ok, latest}

      {:ok, %Req.Response{status: status}} ->
        Logger.debug("Update check: relay answered HTTP #{status}")
        {:error, {:http, status}}

      {:error, reason} ->
        Logger.debug("Update check: relay unreachable: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    error ->
      Logger.debug("Update check failed: " <> Exception.message(error))
      {:error, error}
  end

  # The URL ends up in an admin-facing href, so anything but https (a
  # `javascript:` URL from a hostile METADATA_RELAY_URL) is dropped.
  defp https_url(%{"release_url" => "https://" <> _ = url}), do: url
  defp https_url(_body), do: nil

  @doc "Exactly what the check sends."
  @spec payload() :: %{String.t() => String.t()}
  def payload do
    %{
      "install_id" => install_id(),
      "version" => current_version(),
      "arch" => to_string(:erlang.system_info(:system_architecture)),
      "db" => Atom.to_string(Mydia.DB.adapter_type())
    }
  end

  @doc """
  This install's id, generated and stored on first use.
  """
  @spec install_id() :: String.t()
  def install_id do
    case Settings.get_config_setting_by_key(@install_id_key) do
      %{value: <<_::binary-size(64)>> = id} ->
        id

      _missing_or_malformed ->
        id = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

        {:ok, _} =
          Settings.upsert_config_setting(%{key: @install_id_key, value: id, category: :general})

        id
    end
  end

  @doc """
  The newer release the last check reported, or `nil` when there is none, no
  check has run since boot, or the check is off.
  """
  @spec available_update() :: release() | nil
  def available_update do
    # The settings read comes last: the Status page calls this on every
    # refresh, and almost always there is no answer to show.
    with %{version: latest} = release <- :persistent_term.get(@latest_key, nil),
         {:ok, latest} <- Version.parse(latest),
         {:ok, current} <- Version.parse(current_version()),
         :gt <- Version.compare(latest, current),
         true <- enabled?() do
      release
    else
      _ -> nil
    end
  end

  @doc "Drops the remembered answer, so a disabled check stops showing one."
  @spec forget() :: :ok
  def forget do
    :persistent_term.erase(@latest_key)
    :ok
  end

  defp current_version, do: to_string(Application.spec(:mydia, :vsn))
end
