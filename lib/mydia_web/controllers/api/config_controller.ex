defmodule MydiaWeb.Api.ConfigController do
  @moduledoc """
  REST API controller for configuration management.

  Provides endpoints for querying and managing application configuration settings.
  Respects the four-layer configuration precedence:
  1. Environment variables (highest priority, read-only)
  2. Database/UI settings (managed via this API)
  3. YAML configuration file (read-only via API)
  4. Schema defaults (read-only)

  All endpoints require API authentication with admin role.
  """

  use MydiaWeb, :controller

  alias Mydia.Settings
  require Logger

  @doc """
  Lists all configuration settings with their sources.

  GET /api/v1/config

  Returns:
    - 200: List of all configuration settings with metadata including source
  """
  def index(conn, _params) do
    # Get the runtime config (result of all layers merged)
    runtime_config = Settings.get_runtime_config()

    # Get database settings
    db_settings = Settings.list_config_settings()

    # Build a map of all settings with their sources
    settings = build_settings_list(runtime_config, db_settings)

    json(conn, %{data: settings})
  end

  @doc """
  Gets a specific configuration setting by key.

  GET /api/v1/config/:key

  The key uses dot notation (e.g., "server.port", "auth.oidc_enabled").

  Returns:
    - 200: Configuration setting with source information
    - 404: Setting not found
  """
  def show(conn, %{"key" => key}) do
    # Parse key into path segments
    path = parse_config_key(key)

    # Get the current value from runtime config
    runtime_config = Settings.get_runtime_config()
    current_value = get_in(runtime_config, path_to_access_keys(path))

    # Check if it exists in database
    db_setting = Settings.get_config_setting_by_key(key)

    # Determine source
    source = determine_source(key, db_setting)

    # Get default value from schema
    default_value = get_default_value(path)

    setting = %{
      key: key,
      value: serialize_value(current_value),
      source: source,
      default_value: serialize_value(default_value),
      category: determine_category(path),
      description: db_setting && db_setting.description,
      updated_at: db_setting && db_setting.updated_at,
      updated_by_id: db_setting && db_setting.updated_by_id
    }

    json(conn, %{data: setting})
  end

  @doc """
  Updates a configuration setting.

  PUT /api/v1/config/:key

  Body:
    {
      "value": "new_value",       # Required: new configuration value
      "description": "..."         # Optional: human-readable description
    }

  Returns:
    - 200: Setting updated successfully
    - 400: Invalid request (missing value)
    - 403: Forbidden (setting is controlled by environment variable)
    - 422: Validation error
  """
  def update(conn, %{"key" => key} = params) do
    # Validate params through changeset
    changeset = validate_update_params(params)

    cond do
      not changeset.valid? ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Validation failed", details: format_changeset_errors(changeset)})

      is_env_var_setting?(key) ->
        conn
        |> put_status(:forbidden)
        |> json(%{
          error:
            "Cannot update setting controlled by environment variable. " <>
              "Remove the environment variable to allow UI/API configuration."
        })

      true ->
        validated_data = Ecto.Changeset.apply_changes(changeset)
        perform_update(conn, key, validated_data.value, Map.get(validated_data, :description))
    end
  end

  @doc """
  Deletes a configuration setting override from the database.

  DELETE /api/v1/config/:key

  This removes the database/UI override, causing the setting to fall back to
  YAML config or schema defaults.

  Returns:
    - 200: Override removed successfully (falls back to YAML/default)
    - 403: Forbidden (setting is controlled by environment variable)
    - 404: No database override exists for this setting
  """
  def delete(conn, %{"key" => key}) do
    cond do
      is_env_var_setting?(key) ->
        conn
        |> put_status(:forbidden)
        |> json(%{
          error:
            "Cannot delete setting controlled by environment variable. " <>
              "Remove the environment variable to allow UI/API configuration."
        })

      true ->
        case Settings.get_config_setting_by_key(key) do
          nil ->
            conn
            |> put_status(:not_found)
            |> json(%{error: "No database override exists for this setting"})

          setting ->
            case Settings.delete_config_setting(setting) do
              {:ok, _deleted} ->
                Logger.info("Configuration setting override removed", key: key)

                # Get the new value after deletion (will fall back to YAML/default)
                path = parse_config_key(key)
                runtime_config = Settings.get_runtime_config()
                fallback_value = get_in(runtime_config, path_to_access_keys(path))

                json(conn, %{
                  message: "Database override removed, setting will use YAML config or default",
                  key: key,
                  new_value: serialize_value(fallback_value),
                  new_source: "yaml_or_default"
                })

              {:error, reason} ->
                Logger.error("Failed to delete config setting",
                  key: key,
                  reason: inspect(reason)
                )

                conn
                |> put_status(:unprocessable_entity)
                |> json(%{error: "Failed to delete setting: #{inspect(reason)}"})
            end
        end
    end
  end

  @doc """
  Tests connection to an external service (download client or indexer).

  POST /api/v1/config/test-connection

  Body:
    {
      "type": "download_client",  # Required: download_client or indexer
      "id": "client_id"            # Required: ID of the client/indexer to test
    }

  Returns:
    - 200: Connection successful
    - 400: Invalid request (missing type or id)
    - 422: Connection failed
    - 501: Not yet implemented
  """
  def test_connection(conn, _params) do
    # TODO: Implement connection testing for download clients and indexers
    # This will require calling the respective test functions from their controllers
    conn
    |> put_status(:not_implemented)
    |> json(%{
      error: "Connection testing not yet implemented",
      hint: "Use /api/v1/downloads/clients/:id/test or /api/v1/indexers/:id/test instead"
    })
  end

  ## Private Functions

  defp perform_update(conn, key, value, description) do
    path = parse_config_key(key)
    category = determine_category(path)

    # Build attrs from validated data
    base_attrs = %{
      key: key,
      value: to_string(value),
      category: category
    }

    attrs =
      if description do
        Map.put(base_attrs, :description, description)
      else
        base_attrs
      end

    # Get or create the config setting
    case Settings.get_config_setting_by_key(key) do
      nil ->
        # Create new setting
        case Settings.create_config_setting(attrs) do
          {:ok, setting} ->
            Logger.info("Configuration setting created", key: key, value: value)

            json(conn, %{
              message: "Configuration setting created successfully",
              data: serialize_config_setting(setting)
            })

          {:error, changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Validation failed", details: format_changeset_errors(changeset)})
        end

      setting ->
        # Update existing setting (only value and optionally description)
        update_attrs = Map.take(attrs, [:value, :description])

        case Settings.update_config_setting(setting, update_attrs) do
          {:ok, updated_setting} ->
            Logger.info("Configuration setting updated", key: key, value: value)

            json(conn, %{
              message: "Configuration setting updated successfully",
              data: serialize_config_setting(updated_setting)
            })

          {:error, changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Validation failed", details: format_changeset_errors(changeset)})
        end
    end
  end

  defp build_settings_list(runtime_config, db_settings) do
    # Build a map of database settings for quick lookup
    db_settings_map =
      db_settings
      |> Enum.map(fn s -> {s.key, s} end)
      |> Enum.into(%{})

    # Convert runtime config struct to map and flatten it
    config_map = struct_to_map(runtime_config)
    flattened = flatten_config(config_map)

    # Build setting list with source information
    Enum.map(flattened, fn {key, value} ->
      db_setting = Map.get(db_settings_map, key)
      source = determine_source(key, db_setting)

      %{
        key: key,
        value: serialize_value(value),
        source: source,
        category: db_setting && db_setting.category,
        description: db_setting && db_setting.description,
        updated_at: db_setting && db_setting.updated_at
      }
    end)
    |> Enum.sort_by(& &1.key)
  end

  defp flatten_config(map, prefix \\ []) do
    Enum.flat_map(map, fn {key, value} ->
      current_path = prefix ++ [key]
      key_string = Enum.join(current_path, ".")

      cond do
        # Skip collections (download_clients, indexers) - they have their own APIs
        key in [:download_clients, :indexers] ->
          []

        # Recursively flatten nested maps
        is_map(value) and not is_struct(value) ->
          flatten_config(value, current_path)

        # Skip nil values
        is_nil(value) ->
          []

        # Leaf value
        true ->
          [{key_string, value}]
      end
    end)
  end

  defp struct_to_map(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> Enum.map(fn {key, value} ->
      {key, struct_to_map(value)}
    end)
    |> Enum.into(%{})
  end

  defp struct_to_map(value) when is_list(value) do
    Enum.map(value, &struct_to_map/1)
  end

  defp struct_to_map(value), do: value

  defp parse_config_key(key) do
    key
    |> String.split(".")
    |> Enum.map(&String.to_atom/1)
  end

  defp path_to_access_keys(path) do
    Enum.map(path, fn key when is_atom(key) -> Access.key(key) end)
  end

  defp determine_source(key, db_setting) do
    cond do
      is_env_var_setting?(key) -> "environment_variable"
      db_setting != nil -> "database"
      # TODO: Check if setting exists in YAML file
      # yaml_has_setting?(key) -> "yaml"
      true -> "default"
    end
  end

  defp is_env_var_setting?(key) do
    # Map config keys to their environment variable names
    env_var_name = config_key_to_env_var(key)
    env_var_name != nil and System.get_env(env_var_name) != nil
  end

  defp config_key_to_env_var(key) do
    # Map common config keys to their environment variable names
    # This is a subset - add more as needed
    mapping = %{
      "server.port" => "PORT",
      "server.host" => "HOST",
      "server.url_scheme" => "URL_SCHEME",
      "server.url_host" => "URL_HOST",
      "server.secret_key_base" => "SECRET_KEY_BASE",
      "server.guardian_secret_key" => "GUARDIAN_SECRET_KEY",
      "database.path" => "DATABASE_PATH",
      "database.pool_size" => "POOL_SIZE",
      "auth.oidc_enabled" => "OIDC_ENABLED",
      "auth.oidc_issuer" => "OIDC_ISSUER",
      "auth.oidc_discovery_document_uri" => "OIDC_DISCOVERY_DOCUMENT_URI",
      "auth.oidc_client_id" => "OIDC_CLIENT_ID",
      "auth.oidc_client_secret" => "OIDC_CLIENT_SECRET",
      "auth.local_enabled" => "LOCAL_AUTH_ENABLED",
      "media.movies_path" => "MOVIES_PATH",
      "media.tv_path" => "TV_PATH",
      "logging.level" => "LOG_LEVEL"
    }

    Map.get(mapping, key)
  end

  defp get_default_value(path) do
    defaults = Mydia.Config.Schema.defaults()
    get_in(defaults, path_to_access_keys(path))
  end

  defp determine_category([category | _rest]) do
    category_atom = category

    if category_atom in [
         :server,
         :auth,
         :media,
         :downloads,
         :notifications,
         :general,
         :database,
         :logging,
         :oban
       ] do
      category_atom
    else
      :general
    end
  end

  defp determine_category([]), do: :general

  defp serialize_value(value) when is_binary(value), do: value
  defp serialize_value(value) when is_number(value), do: value
  defp serialize_value(value) when is_boolean(value), do: value
  defp serialize_value(nil), do: nil
  defp serialize_value(value), do: to_string(value)

  defp serialize_config_setting(setting) do
    %{
      key: setting.key,
      value: setting.value,
      category: setting.category,
      description: setting.description,
      source: "database",
      updated_at: setting.updated_at,
      updated_by_id: setting.updated_by_id
    }
  end

  defp validate_update_params(params) do
    types = %{
      key: :string,
      value: :string,
      description: :string
    }

    {%{}, types}
    |> Ecto.Changeset.cast(params, [:key, :value, :description])
    |> Ecto.Changeset.validate_required([:key, :value])
  end

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
