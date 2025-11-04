defmodule Mydia.Config.Loader do
  @moduledoc """
  Loads and merges configuration from multiple sources with precedence:
  Environment Variables > Database/UI Settings > YAML File > Schema Defaults

  The configuration system supports four layers:
  1. **Schema Defaults** - Default values defined in `Mydia.Config.Schema`
  2. **YAML File** - Configuration from config/config.yml (overrides defaults)
  3. **Database/UI Settings** - Runtime configuration from admin UI (overrides YAML)
  4. **Environment Variables** - Deployment-specific config (overrides everything)

  Validates the final configuration using the schema.
  """

  alias Mydia.Config.Schema
  alias Mydia.Settings

  @doc """
  Loads configuration from all sources and returns validated config.

  ## Options
    - `:config_file` - Path to YAML config file (default: "config/config.yml")
    - `:env` - Environment to use for config (default: Mix.env())

  Returns `{:ok, config}` or `{:error, errors}`.
  """
  def load(opts \\ []) do
    config_file = Keyword.get(opts, :config_file, default_config_path())

    with {:ok, yaml_config} <- load_yaml(config_file),
         {:ok, db_config} <- load_database_config(),
         env_config <- load_env(),
         merged <- merge_all_configs(yaml_config, db_config, env_config),
         {:ok, validated} <- validate(merged) do
      {:ok, validated}
    end
  end

  @doc """
  Loads configuration and raises on error.
  """
  def load!(opts \\ []) do
    case load(opts) do
      {:ok, config} ->
        config

      {:error, %Ecto.Changeset{} = changeset} ->
        errors = format_errors(changeset)

        raise """
        Configuration validation failed:
        #{errors}
        """

      {:error, reason} ->
        raise "Configuration loading failed: #{inspect(reason)}"
    end
  end

  ## Private Functions

  defp default_config_path do
    Path.join([:code.priv_dir(:mydia) |> to_string(), "..", "config", "config.yml"])
    |> Path.expand()
  end

  defp load_yaml(path) do
    if File.exists?(path) do
      case YamlElixir.read_from_file(path) do
        {:ok, nil} ->
          # Empty YAML file
          {:ok, %{}}

        {:ok, data} when is_map(data) ->
          {:ok, normalize_yaml_keys(data)}

        {:ok, _other} ->
          {:error, "YAML file must contain a map at the root level"}

        {:error, reason} ->
          {:error, "Failed to parse YAML file: #{inspect(reason)}"}
      end
    else
      # No config file is OK, just use defaults
      {:ok, %{}}
    end
  end

  defp normalize_yaml_keys(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} ->
      normalized_key =
        key
        |> to_string()
        |> String.downcase()
        |> String.to_atom()

      normalized_value =
        cond do
          is_map(value) -> normalize_yaml_keys(value)
          is_list(value) -> Enum.map(value, &normalize_yaml_value/1)
          true -> value
        end

      {normalized_key, normalized_value}
    end)
    |> Enum.into(%{})
  end

  defp normalize_yaml_value(value) when is_map(value), do: normalize_yaml_keys(value)
  defp normalize_yaml_value(value), do: value

  defp load_database_config do
    # Load database configuration settings
    # Returns {:ok, %{}} if database is unavailable (e.g., during initial setup)
    Settings.load_database_config()
  end

  defp load_env do
    %{
      server: load_server_env(),
      database: load_database_env(),
      auth: load_auth_env(),
      media: load_media_env(),
      downloads: load_downloads_env(),
      logging: load_logging_env(),
      oban: load_oban_env(),
      download_clients: load_download_clients_env(),
      indexers: load_indexers_env()
    }
    |> remove_empty_maps()
  end

  defp load_server_env do
    %{}
    |> put_if_present(:port, System.get_env("PORT"), &parse_integer/1)
    |> put_if_present(:host, System.get_env("HOST"))
    |> put_if_present(:url_scheme, System.get_env("URL_SCHEME"))
    # URL_HOST takes precedence over PHX_HOST, so put PHX_HOST first
    |> put_if_present(:url_host, System.get_env("PHX_HOST"))
    |> put_if_present(:url_host, System.get_env("URL_HOST"))
    |> put_if_present(:secret_key_base, System.get_env("SECRET_KEY_BASE"))
    |> put_if_present(:guardian_secret_key, System.get_env("GUARDIAN_SECRET_KEY"))
  end

  defp load_database_env do
    %{}
    |> put_if_present(:path, System.get_env("DATABASE_PATH"))
    |> put_if_present(:pool_size, System.get_env("POOL_SIZE"), &parse_integer/1)
    |> put_if_present(:timeout, System.get_env("DATABASE_TIMEOUT"), &parse_integer/1)
    |> put_if_present(:cache_size, System.get_env("SQLITE_CACHE_SIZE"), &parse_integer/1)
    |> put_if_present(:busy_timeout, System.get_env("SQLITE_BUSY_TIMEOUT"), &parse_integer/1)
    |> put_if_present(:journal_mode, System.get_env("SQLITE_JOURNAL_MODE"))
    |> put_if_present(:synchronous, System.get_env("SQLITE_SYNCHRONOUS"))
  end

  defp load_auth_env do
    %{}
    |> put_if_present(:local_enabled, System.get_env("LOCAL_AUTH_ENABLED"), &parse_boolean/1)
    |> put_if_present(:oidc_enabled, System.get_env("OIDC_ENABLED"), &parse_boolean/1)
    |> put_if_present(:oidc_issuer, System.get_env("OIDC_ISSUER"))
    |> put_if_present(
      :oidc_discovery_document_uri,
      System.get_env("OIDC_DISCOVERY_DOCUMENT_URI")
    )
    |> put_if_present(:oidc_client_id, System.get_env("OIDC_CLIENT_ID"))
    |> put_if_present(:oidc_client_secret, System.get_env("OIDC_CLIENT_SECRET"))
    |> put_if_present(:oidc_redirect_uri, System.get_env("OIDC_REDIRECT_URI"))
    |> put_if_present(:oidc_scopes, System.get_env("OIDC_SCOPES"))
    |> put_if_present(:jwt_ttl_days, System.get_env("JWT_TTL_DAYS"), &parse_integer/1)
    |> put_if_present(:jwt_allowed_drift, System.get_env("JWT_ALLOWED_DRIFT"), &parse_integer/1)
  end

  defp load_media_env do
    %{}
    |> put_if_present(:movies_path, System.get_env("MOVIES_PATH"))
    |> put_if_present(:tv_path, System.get_env("TV_PATH"))
    |> put_if_present(
      :scan_interval_hours,
      System.get_env("MEDIA_SCAN_INTERVAL_HOURS"),
      &parse_integer/1
    )
  end

  defp load_downloads_env do
    %{}
    |> put_if_present(
      :monitor_interval_minutes,
      System.get_env("DOWNLOAD_MONITOR_INTERVAL_MINUTES"),
      &parse_integer/1
    )
  end

  defp load_logging_env do
    %{}
    |> put_if_present(:level, System.get_env("LOG_LEVEL"))
  end

  defp load_oban_env do
    %{}
    |> put_if_present(:poll_interval, System.get_env("OBAN_POLL_INTERVAL"), &parse_integer/1)
    |> put_if_present(:max_age_days, System.get_env("OBAN_MAX_AGE_DAYS"), &parse_integer/1)
  end

  defp load_download_clients_env do
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
      |> put_if_present(:name, System.get_env("#{prefix}NAME"))
      |> put_if_present(:type, System.get_env("#{prefix}TYPE"), &parse_atom/1)
      |> put_if_present(:enabled, System.get_env("#{prefix}ENABLED"), &parse_boolean/1)
      |> put_if_present(:priority, System.get_env("#{prefix}PRIORITY"), &parse_integer/1)
      |> put_if_present(:host, System.get_env("#{prefix}HOST"))
      |> put_if_present(:port, System.get_env("#{prefix}PORT"), &parse_integer/1)
      |> put_if_present(:use_ssl, System.get_env("#{prefix}USE_SSL"), &parse_boolean/1)
      |> put_if_present(:url_base, System.get_env("#{prefix}URL_BASE"))
      |> put_if_present(:username, System.get_env("#{prefix}USERNAME"))
      |> put_if_present(:password, System.get_env("#{prefix}PASSWORD"))
      |> put_if_present(:api_key, System.get_env("#{prefix}API_KEY"))
      |> put_if_present(:category, System.get_env("#{prefix}CATEGORY"))
      |> put_if_present(:download_directory, System.get_env("#{prefix}DOWNLOAD_DIRECTORY"))
    end)
    |> Enum.reject(&(&1 == %{}))
  end

  defp load_indexers_env do
    # Support environment variables for indexers in the format:
    # INDEXER_<N>_NAME, INDEXER_<N>_TYPE, etc.
    # where N is 1, 2, 3, etc.
    env_vars = System.get_env()

    # Find all indexer indices by looking for *_NAME vars
    indices =
      env_vars
      |> Enum.filter(fn {key, _value} ->
        String.starts_with?(key, "INDEXER_") and String.ends_with?(key, "_NAME")
      end)
      |> Enum.map(fn {key, _value} ->
        key
        |> String.replace_prefix("INDEXER_", "")
        |> String.replace_suffix("_NAME", "")
      end)
      |> Enum.uniq()

    # Load each indexer config
    Enum.map(indices, fn index ->
      prefix = "INDEXER_#{index}_"

      %{}
      |> put_if_present(:name, System.get_env("#{prefix}NAME"))
      |> put_if_present(:type, System.get_env("#{prefix}TYPE"), &parse_atom/1)
      |> put_if_present(:enabled, System.get_env("#{prefix}ENABLED"), &parse_boolean/1)
      |> put_if_present(:priority, System.get_env("#{prefix}PRIORITY"), &parse_integer/1)
      |> put_if_present(:base_url, System.get_env("#{prefix}BASE_URL"))
      |> put_if_present(:api_key, System.get_env("#{prefix}API_KEY"))
      |> put_if_present(
        :indexer_ids,
        System.get_env("#{prefix}INDEXER_IDS"),
        &parse_string_list/1
      )
      |> put_if_present(:categories, System.get_env("#{prefix}CATEGORIES"), &parse_string_list/1)
      |> put_if_present(:rate_limit, System.get_env("#{prefix}RATE_LIMIT"), &parse_integer/1)
      |> put_if_present(:timeout, System.get_env("#{prefix}TIMEOUT"), &parse_integer/1)
    end)
    |> Enum.reject(&(&1 == %{}))
  end

  defp put_if_present(map, _key, nil, _parser), do: map
  defp put_if_present(map, _key, "", _parser), do: map

  defp put_if_present(map, key, value, parser) when is_function(parser, 1) do
    case parser.(value) do
      {:ok, parsed} -> Map.put(map, key, parsed)
      :error -> map
    end
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, _key, ""), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp parse_integer(value) when is_integer(value), do: {:ok, value}

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  defp parse_integer(_), do: :error

  defp parse_boolean(value) when is_boolean(value), do: {:ok, value}
  defp parse_boolean("true"), do: {:ok, true}
  defp parse_boolean("false"), do: {:ok, false}
  defp parse_boolean("1"), do: {:ok, true}
  defp parse_boolean("0"), do: {:ok, false}
  defp parse_boolean(_), do: :error

  defp parse_atom(value) when is_atom(value), do: {:ok, value}

  defp parse_atom(value) when is_binary(value) do
    try do
      {:ok, String.to_existing_atom(value)}
    rescue
      ArgumentError -> {:ok, String.to_atom(value)}
    end
  end

  defp parse_atom(_), do: :error

  defp parse_string_list(value) when is_list(value), do: {:ok, value}

  defp parse_string_list(value) when is_binary(value) do
    # Parse comma-separated string lists
    list =
      value
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    {:ok, list}
  end

  defp parse_string_list(_), do: :error

  defp merge_all_configs(yaml_config, db_config, env_config) do
    # Merge in order: yaml → db → env (each layer overrides the previous)
    yaml_config
    |> deep_merge(db_config)
    |> deep_merge(env_config)
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn key, left_val, right_val ->
      cond do
        # For download_clients and indexers, merge lists (env entries are appended)
        key in [:download_clients, :indexers] and is_list(left_val) and is_list(right_val) ->
          left_val ++ right_val

        # For nested maps, merge recursively
        is_map(left_val) and is_map(right_val) ->
          deep_merge(left_val, right_val)

        # Otherwise, right (env) takes precedence
        true ->
          right_val
      end
    end)
  end

  defp deep_merge(_left, right), do: right

  defp remove_empty_maps(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} ->
      if is_map(value) do
        {key, remove_empty_maps(value)}
      else
        {key, value}
      end
    end)
    |> Enum.reject(fn {_key, value} -> value == %{} end)
    |> Enum.into(%{})
  end

  defp validate(config) do
    case Schema.changeset(Schema.defaults(), config) do
      %Ecto.Changeset{valid?: true} = changeset ->
        {:ok, Ecto.Changeset.apply_changes(changeset)}

      %Ecto.Changeset{valid?: false} = changeset ->
        {:error, changeset}
    end
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> format_error_map()
  end

  defp format_error_map(errors, prefix \\ "") do
    Enum.map_join(errors, "\n", fn {key, value} ->
      current_key = if prefix == "", do: "#{key}", else: "#{prefix}.#{key}"

      cond do
        is_map(value) ->
          format_error_map(value, current_key)

        is_list(value) ->
          Enum.map_join(value, "\n", fn error ->
            "  - #{current_key}: #{error}"
          end)

        true ->
          "  - #{current_key}: #{value}"
      end
    end)
  end
end
