defmodule Mydia.Settings.QualityProfiles do
  @moduledoc false

  import Ecto.Query, warn: false
  import Mydia.QueryHelpers
  require Logger

  alias Mydia.Repo

  alias Mydia.Settings.{
    QualityProfile,
    ConfigSetting,
    DefaultQualityProfiles
  }

  # Shipped default. Sets no resolution or size constraints, so seeding it does
  # not narrow what an existing install grabs, but it still routes every search
  # through ReleaseRanker instead of the bare seeders sort a nil profile hits.
  @seeded_default_profile_name "Any"

  ## Quality Profile CRUD

  def list_quality_profiles(opts \\ []) do
    QualityProfile
    |> apply_quality_profile_filters(opts)
    |> maybe_preload(opts[:preload])
    |> order_by([q], asc: q.name)
    |> Repo.all()
  end

  def get_quality_profile!(id, opts \\ []) do
    QualityProfile
    |> maybe_preload(opts[:preload])
    |> Repo.get!(id)
  end

  def get_quality_profile_by_name(name, opts \\ []) do
    QualityProfile
    |> where([q], q.name == ^name)
    |> maybe_preload(opts[:preload])
    |> Repo.one()
  end

  def create_quality_profile(attrs \\ %{}) do
    %QualityProfile{}
    |> QualityProfile.changeset(attrs)
    |> Repo.insert()
  end

  def update_quality_profile(%QualityProfile{} = quality_profile, attrs, opts \\ []) do
    skip_reevaluation = Keyword.get(opts, :skip_reevaluation, false)

    changeset = QualityProfile.changeset(quality_profile, attrs)

    # Check if quality_standards are changing
    quality_standards_changed? =
      Ecto.Changeset.get_change(changeset, :quality_standards) != nil

    case Repo.update(changeset) do
      {:ok, updated_profile} = result ->
        # Trigger re-evaluation if quality_standards changed and not skipped
        if quality_standards_changed? and not skip_reevaluation do
          trigger_profile_reevaluation(updated_profile.id)
        end

        result

      error ->
        error
    end
  end

  def trigger_profile_reevaluation(profile_id) do
    Logger.info("Triggering background re-evaluation for quality profile",
      profile_id: profile_id
    )

    # Spawn a supervised task to re-evaluate files
    Task.Supervisor.start_child(Mydia.TaskSupervisor, fn ->
      alias Mydia.Settings.QualityProfileEngine

      case QualityProfileEngine.reevaluate_profile_files(profile_id) do
        {:ok, summary} ->
          Logger.info("Quality profile re-evaluation completed",
            profile_id: profile_id,
            processed: summary.processed,
            updated: summary.updated,
            errors: length(summary.errors)
          )

        {:error, reason} ->
          Logger.error("Quality profile re-evaluation failed",
            profile_id: profile_id,
            reason: inspect(reason)
          )
      end
    end)

    :ok
  end

  def delete_quality_profile(%QualityProfile{} = quality_profile) do
    # Check if profile is assigned to any media items
    if profile_in_use?(quality_profile.id) do
      {:error, :profile_in_use}
    else
      Repo.delete(quality_profile)
    end
  end

  def profile_in_use?(profile_id) do
    alias Mydia.Media.MediaItem

    MediaItem
    |> where([m], m.quality_profile_id == ^profile_id)
    |> Repo.exists?()
  end

  def count_media_items_for_profile(profile_id) do
    alias Mydia.Media.MediaItem

    MediaItem
    |> where([m], m.quality_profile_id == ^profile_id)
    |> Repo.aggregate(:count)
  end

  def force_delete_quality_profile(%QualityProfile{} = quality_profile) do
    alias Mydia.Media.MediaItem

    Repo.transaction(fn ->
      # Unassign the profile from all media items
      MediaItem
      |> where([m], m.quality_profile_id == ^quality_profile.id)
      |> Repo.update_all(set: [quality_profile_id: nil])

      # Delete the profile
      case Repo.delete(quality_profile) do
        {:ok, deleted_profile} -> deleted_profile
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  def change_quality_profile(%QualityProfile{} = quality_profile, attrs \\ %{}) do
    QualityProfile.changeset(quality_profile, attrs)
  end

  def ensure_default_quality_profiles do
    try do
      # Get existing profile names to avoid duplicates
      existing_names =
        QualityProfile
        |> select([q], q.name)
        |> Repo.all()
        |> MapSet.new()

      # Create missing default profiles
      created_count =
        DefaultQualityProfiles.defaults()
        |> Enum.reject(fn profile -> MapSet.member?(existing_names, profile.name) end)
        |> Enum.reduce(0, fn profile_attrs, count ->
          case create_quality_profile(profile_attrs) do
            {:ok, _profile} -> count + 1
            {:error, _changeset} -> count
          end
        end)

      maybe_seed_default_quality_profile()

      {:ok, created_count}
    rescue
      # Database might not be available during initial setup
      DBConnection.ConnectionError -> {:error, :database_unavailable}
      # Catch query errors (e.g., table doesn't exist yet)
      Ecto.QueryError -> {:error, :database_unavailable}
      # Catch SQLite-specific errors
      Exqlite.Error -> {:error, :database_unavailable}
      # Catch Repo not started yet error
      RuntimeError -> {:error, :database_unavailable}
    end
  end

  def clone_quality_profile(%QualityProfile{} = profile, new_name \\ nil) do
    name = new_name || "#{profile.name} (Copy)"

    attrs = %{
      name: name,
      upgrades_allowed: profile.upgrades_allowed,
      upgrade_until_quality: profile.upgrade_until_quality,
      description: profile.description,
      is_system: false,
      version: 1,
      source_url: nil,
      quality_standards: profile.quality_standards
    }

    create_quality_profile(attrs)
  end

  ## Version Comparison

  def compare_quality_profile_versions(%QualityProfile{} = profile1, %QualityProfile{} = profile2) do
    # Fields to compare (excluding id, timestamps, and associations)
    fields = [
      :name,
      :upgrades_allowed,
      :upgrade_until_quality,
      :description,
      :is_system,
      :version,
      :source_url,
      :last_synced_at,
      :quality_standards
    ]

    changed =
      Enum.reduce(fields, %{}, fn field, acc ->
        val1 = Map.get(profile1, field)
        val2 = Map.get(profile2, field)

        if val1 != val2 do
          Map.put(acc, field, {val1, val2})
        else
          acc
        end
      end)

    # For added/removed, focus on optional map fields
    optional_fields = [:quality_standards]

    added =
      Enum.reduce(optional_fields, %{}, fn field, acc ->
        val1 = Map.get(profile1, field)
        val2 = Map.get(profile2, field)

        if is_nil(val1) and not is_nil(val2) do
          Map.put(acc, field, val2)
        else
          acc
        end
      end)

    removed =
      Enum.reduce(optional_fields, %{}, fn field, acc ->
        val1 = Map.get(profile1, field)
        val2 = Map.get(profile2, field)

        if not is_nil(val1) and is_nil(val2) do
          Map.put(acc, field, val1)
        else
          acc
        end
      end)

    %{
      changed: changed,
      added: added,
      removed: removed
    }
  end

  ## Export / Import

  def export_profile(%QualityProfile{} = profile, opts \\ []) do
    format = Keyword.get(opts, :format, :json)
    pretty = Keyword.get(opts, :pretty, true)

    # Build export data structure with schema version
    export_data = %{
      schema_version: 1,
      name: profile.name,
      description: profile.description,
      upgrades_allowed: profile.upgrades_allowed,
      upgrade_until_quality: profile.upgrade_until_quality,
      quality_standards: profile.quality_standards,
      version: profile.version,
      exported_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    case format do
      :json ->
        encode_json(export_data, pretty)

      :yaml ->
        encode_yaml(export_data)

      _ ->
        {:error, "Unsupported format: #{format}. Use :json or :yaml"}
    end
  end

  def import_profile(source, opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)

    with {:ok, content} <- fetch_import_content(source, opts),
         {:ok, data} <- parse_import_content(content),
         {:ok, validated_data} <- validate_import_schema(data),
         {:ok, attrs} <- prepare_import_attrs(validated_data, source, opts) do
      perform_import(attrs, dry_run)
    end
  end

  ## Default Quality Profile

  def get_default_quality_profile_id do
    case Mydia.Settings.RuntimeConfig.get_config_setting_by_key(
           "media.default_quality_profile_id"
         ) do
      %ConfigSetting{value: value} when is_binary(value) and value != "" ->
        value

      _ ->
        nil
    end
  end

  def get_default_quality_profile do
    case get_default_quality_profile_id() do
      nil -> nil
      id -> Repo.get(QualityProfile, id)
    end
  end

  def set_default_quality_profile(nil) do
    case Mydia.Settings.RuntimeConfig.get_config_setting_by_key(
           "media.default_quality_profile_id"
         ) do
      nil ->
        {:ok, nil}

      existing ->
        Mydia.Settings.RuntimeConfig.update_config_setting(existing, %{value: ""})
    end
  end

  def set_default_quality_profile(profile_id) when is_binary(profile_id) do
    attrs = %{
      key: "media.default_quality_profile_id",
      value: profile_id,
      category: :media,
      description: "Default quality profile for adding media"
    }

    case Mydia.Settings.RuntimeConfig.get_config_setting_by_key(
           "media.default_quality_profile_id"
         ) do
      nil ->
        Mydia.Settings.RuntimeConfig.create_config_setting(attrs)

      existing ->
        Mydia.Settings.RuntimeConfig.update_config_setting(existing, attrs)
    end
  end

  def set_default_quality_profile(profile_id) when is_integer(profile_id) do
    set_default_quality_profile(to_string(profile_id))
  end

  ## Private Functions

  # Seeds `media.default_quality_profile_id` on a genuinely fresh install.
  #
  # Only runs when the ConfigSetting row is absent entirely.
  # `set_default_quality_profile(nil)` stores `value: ""` rather than deleting
  # the row, so an operator who deliberately cleared the default leaves a row
  # behind and is never overridden on the next boot.
  defp maybe_seed_default_quality_profile do
    existing =
      Mydia.Settings.RuntimeConfig.get_config_setting_by_key("media.default_quality_profile_id")

    if is_nil(existing) do
      case Repo.get_by(QualityProfile, name: @seeded_default_profile_name) do
        %QualityProfile{id: id} -> log_seed_result(set_default_quality_profile(id))
        nil -> :ok
      end
    end

    :ok
  end

  defp log_seed_result({:error, reason}) do
    Logger.warning(
      "Failed to seed the default quality profile #{inspect(@seeded_default_profile_name)}; " <>
        "searches for items with no profile will fall back to a plain seeders sort " <>
        "until a default is set under Admin > Quality Profiles. Reason: #{inspect(reason)}"
    )

    :ok
  end

  defp log_seed_result(_ok), do: :ok

  defp apply_quality_profile_filters(query, opts) do
    query
    |> apply_is_system_filter(opts[:is_system])
    |> apply_version_filter(opts[:version])
    |> apply_source_url_filter(opts[:source_url])
  end

  defp apply_is_system_filter(query, nil), do: query

  defp apply_is_system_filter(query, is_system) when is_boolean(is_system) do
    where(query, [q], q.is_system == ^is_system)
  end

  defp apply_version_filter(query, nil), do: query

  defp apply_version_filter(query, version) when is_integer(version) do
    where(query, [q], q.version == ^version)
  end

  defp apply_source_url_filter(query, nil), do: query

  defp apply_source_url_filter(query, source_url) when is_binary(source_url) do
    where(query, [q], q.source_url == ^source_url)
  end

  defp encode_json(data, true) do
    case Jason.encode(data, pretty: true) do
      {:ok, json} -> {:ok, json}
      {:error, error} -> {:error, "JSON encoding failed: #{inspect(error)}"}
    end
  end

  defp encode_json(data, false) do
    case Jason.encode(data) do
      {:ok, json} -> {:ok, json}
      {:error, error} -> {:error, "JSON encoding failed: #{inspect(error)}"}
    end
  end

  defp encode_yaml(data) do
    case Ymlr.document(data) do
      {:ok, yaml} -> {:ok, yaml}
      {:error, error} -> {:error, "YAML encoding failed: #{inspect(error)}"}
    end
  end

  defp fetch_import_content(source, opts) when is_binary(source) do
    cond do
      # Check if it's a URL
      String.starts_with?(source, "http://") or String.starts_with?(source, "https://") ->
        fetch_from_url(source, opts)

      # Check if it's a file path
      File.exists?(source) ->
        File.read(source)

      # Assume it's raw content
      true ->
        {:ok, source}
    end
  end

  defp fetch_import_content(_source, _opts) do
    {:error, "Invalid source: must be a file path, URL, or raw content string"}
  end

  defp fetch_from_url(url, _opts) do
    timeout = 30_000

    # Disable auto-decoding to get raw body
    case Req.get(url,
           connect_options: [timeout: timeout],
           receive_timeout: timeout,
           decode_body: false
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, "Failed to fetch from URL: HTTP #{status}"}

      {:error, error} ->
        {:error, "Failed to fetch from URL: #{inspect(error)}"}
    end
  end

  defp parse_import_content(content) when is_binary(content) do
    # Try JSON first
    case Jason.decode(content) do
      {:ok, data} ->
        {:ok, data}

      {:error, _json_error} ->
        # Try YAML if JSON fails
        case YamlElixir.read_from_string(content) do
          {:ok, data} ->
            {:ok, data}

          {:error, yaml_error} ->
            {:error, "Failed to parse content as JSON or YAML: #{inspect(yaml_error)}"}
        end
    end
  end

  defp validate_import_schema(%{"schema_version" => 1} = data) do
    # Schema version 1 - validate required fields
    required_fields = ["name", "quality_standards"]

    missing_fields =
      required_fields
      |> Enum.reject(&Map.has_key?(data, &1))

    if Enum.empty?(missing_fields) do
      {:ok, data}
    else
      {:error, "Missing required fields: #{Enum.join(missing_fields, ", ")}"}
    end
  end

  defp validate_import_schema(%{"schema_version" => version}) do
    {:error,
     "Unsupported schema version: #{version}. This version only supports schema version 1. Please export the profile from a compatible version."}
  end

  defp validate_import_schema(_data) do
    {:error,
     "Invalid profile format: missing schema_version field. This may be a legacy format that is no longer supported. Please export the profile from a newer version."}
  end

  defp prepare_import_attrs(data, source, opts) do
    # Extract attributes from import data
    attrs = %{
      name: Keyword.get(opts, :name, data["name"]),
      description: data["description"],
      upgrades_allowed: data["upgrades_allowed"],
      upgrade_until_quality: data["upgrade_until_quality"],
      quality_standards: atomize_keys(data["quality_standards"]),
      version: data["version"] || 1,
      is_system: false,
      source_url: determine_source_url(source, opts),
      last_synced_at: DateTime.utc_now()
    }

    {:ok, attrs}
  end

  defp determine_source_url(source, opts) do
    case Keyword.get(opts, :source_url) do
      nil ->
        # Auto-detect if source is a URL
        if is_binary(source) and
             (String.starts_with?(source, "http://") or String.starts_with?(source, "https://")) do
          source
        else
          nil
        end

      url ->
        url
    end
  end

  defp atomize_keys(nil), do: nil

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = if is_binary(k), do: String.to_atom(k), else: k
      value = atomize_keys_value(v)
      {key, value}
    end)
  end

  defp atomize_keys_value(map) when is_map(map), do: atomize_keys(map)
  defp atomize_keys_value(list) when is_list(list), do: Enum.map(list, &atomize_keys_value/1)
  defp atomize_keys_value(value), do: value

  defp perform_import(attrs, true) do
    # Dry run - validate and return preview
    changeset = QualityProfile.changeset(%QualityProfile{}, attrs)

    if changeset.valid? do
      # Check for conflicts
      conflicts = detect_profile_conflicts(attrs.name)

      preview = %{
        action: if(Enum.empty?(conflicts), do: :create, else: :update),
        profile: Ecto.Changeset.apply_changes(changeset),
        conflicts: conflicts,
        dry_run: true
      }

      {:ok, preview}
    else
      {:error, "Validation failed: #{format_changeset_errors(changeset)}"}
    end
  end

  defp perform_import(attrs, false) do
    # Real import - check for conflicts and create/update
    existing_profile = get_quality_profile_by_name(attrs.name)

    case existing_profile do
      nil ->
        # No conflict, create new profile
        create_quality_profile(attrs)

      _profile ->
        # Profile exists, return conflict error
        {:error,
         "Profile '#{attrs.name}' already exists. Use dry_run mode to preview changes or provide a different name."}
    end
  end

  defp detect_profile_conflicts(name) do
    case get_quality_profile_by_name(name) do
      nil -> []
      profile -> [%{type: :name_conflict, existing_profile_id: profile.id, name: name}]
    end
  end

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join("; ", fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
  end
end
