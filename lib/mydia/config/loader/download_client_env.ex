defmodule Mydia.Config.Loader.DownloadClientEnv do
  @moduledoc """
  Reads download client definitions from `DOWNLOAD_CLIENT_<N>_*` environment
  variables for `Mydia.Config.Loader`.

  The shared `put_if_present` and `parse_*` helpers stay in the loader, which
  uses them for every other section.
  """

  require Logger

  alias Mydia.Config.Loader

  @doc """
  Returns one config map per `DOWNLOAD_CLIENT_<N>_NAME` variable found, with
  the other `DOWNLOAD_CLIENT_<N>_*` variables folded in. Empty maps are dropped.
  """
  @spec load() :: [map()]
  def load do
    # Support environment variables for download clients in the format:
    # DOWNLOAD_CLIENT_<N>_NAME, DOWNLOAD_CLIENT_<N>_TYPE, etc.
    # where N is 1, 2, 3, etc.
    env_vars = System.get_env()

    # Find all download client indices by looking for *_NAME vars
    indices =
      env_vars
      |> Enum.filter(fn {key, _value} ->
        String.starts_with?(key, "DOWNLOAD_CLIENT_") and String.ends_with?(key, "_NAME")
      end)
      |> Enum.map(fn {key, _value} ->
        key
        |> String.replace_prefix("DOWNLOAD_CLIENT_", "")
        |> String.replace_suffix("_NAME", "")
      end)
      |> Enum.uniq()

    # Load each download client config
    Enum.map(indices, fn index ->
      prefix = "DOWNLOAD_CLIENT_#{index}_"

      %{}
      |> Loader.put_if_present(:name, System.get_env("#{prefix}NAME"))
      |> Loader.put_if_present(:type, System.get_env("#{prefix}TYPE"), &Loader.parse_atom/1)
      |> Loader.put_if_present(
        :enabled,
        System.get_env("#{prefix}ENABLED"),
        &Loader.parse_boolean/1
      )
      |> Loader.put_if_present(
        :priority,
        System.get_env("#{prefix}PRIORITY"),
        &Loader.parse_integer/1
      )
      |> Loader.put_if_present(:host, System.get_env("#{prefix}HOST"))
      |> Loader.put_if_present(:port, System.get_env("#{prefix}PORT"), &Loader.parse_integer/1)
      |> Loader.put_if_present(
        :use_ssl,
        System.get_env("#{prefix}USE_SSL"),
        &Loader.parse_boolean/1
      )
      |> Loader.put_if_present(:url_base, System.get_env("#{prefix}URL_BASE"))
      |> Loader.put_if_present(
        :web_ui_url,
        System.get_env("#{prefix}WEB_UI_URL"),
        &parse_web_ui_url/1
      )
      |> Loader.put_if_present(:username, System.get_env("#{prefix}USERNAME"))
      |> Loader.put_if_present(:password, System.get_env("#{prefix}PASSWORD"))
      |> Loader.put_if_present(:api_key, System.get_env("#{prefix}API_KEY"))
      |> Loader.put_if_present(:category, System.get_env("#{prefix}CATEGORY"))
      |> Loader.put_if_present(
        :external_torrents,
        System.get_env("#{prefix}EXTERNAL_TORRENTS"),
        &parse_external_torrents/1
      )
      |> Loader.put_if_present(:download_directory, System.get_env("#{prefix}DOWNLOAD_DIRECTORY"))
      |> put_connection_settings(prefix)
    end)
    |> Enum.reject(&(&1 == %{}))
  end

  # Assemble the `connection_settings` map from env vars. Some adapters store
  # config here rather than in top-level columns:
  #   * debrid clients keep their provider at `connection_settings["provider"]`
  #     (DOWNLOAD_CLIENT_<N>_PROVIDER)
  #   * blackhole clients keep their folder paths at
  #     `connection_settings["watch_folder"]` / `["completed_folder"]`
  #     (DOWNLOAD_CLIENT_<N>_WATCH_FOLDER / _COMPLETED_FOLDER)
  # Add further keys here as adapters need them. Keys are strings to match how
  # adapters and validations read the map.
  defp put_connection_settings(map, prefix) do
    settings =
      %{}
      |> Loader.put_if_present("provider", System.get_env("#{prefix}PROVIDER"))
      |> Loader.put_if_present("watch_folder", System.get_env("#{prefix}WATCH_FOLDER"))
      |> Loader.put_if_present("completed_folder", System.get_env("#{prefix}COMPLETED_FOLDER"))

    if settings == %{}, do: map, else: Map.put(map, :connection_settings, settings)
  end

  # An unusable address must not stop the app from booting: drop it, say why,
  # and let DownloadClientConfig.web_ui_url/1 derive one from host and port.
  defp parse_web_ui_url(value) do
    if Mydia.Settings.DownloadClientConfig.valid_web_ui_url?(value) do
      {:ok, value}
    else
      Logger.warning(
        "Ignoring DOWNLOAD_CLIENT_<N>_WEB_UI_URL #{inspect(value)}: expected an http:// or https:// address"
      )

      :error
    end
  end

  # A fixed enum rather than Loader.parse_atom/1, which falls back to
  # String.to_atom/1 and would mint an atom from an environment variable.
  # Atoms are never garbage collected, and the project rule is explicit: no
  # String.to_atom/1 on user input.
  #
  # An unrecognised value maps to :invalid rather than returning :error.
  # Returning :error makes put_if_present/4 drop the key, which would fall
  # back to :auto: an operator who typed "ignor" would get the adoption they
  # were explicitly trying to switch off, which is the exact silent behaviour
  # this setting exists to remove. :invalid is not a member of the Ecto.Enum,
  # so config validation rejects it by name. That matches how a bad
  # DOWNLOAD_CLIENT_<N>_TYPE already behaves, minus the atom leak.
  defp parse_external_torrents(value) when is_atom(value), do: {:ok, value}

  defp parse_external_torrents(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "auto" -> {:ok, :auto}
      "adopt" -> {:ok, :adopt}
      "category_only" -> {:ok, :category_only}
      "ignore" -> {:ok, :ignore}
      _unrecognised -> {:ok, :invalid}
    end
  end

  defp parse_external_torrents(_), do: :error
end
