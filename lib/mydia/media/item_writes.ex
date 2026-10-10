defmodule Mydia.Media.ItemWrites do
  @moduledoc false

  alias Mydia.Repo
  alias Mydia.Media.{Items, MediaItem}
  alias Mydia.Metadata.Access, as: MetadataAccess
  alias Mydia.Events

  # Callers want a tagged tuple to thread through `with`.
  @doc false
  def authorize_write(scope, attrs) do
    if Items.writable?(scope, attrs), do: :ok, else: {:error, :restricted}
  end

  # An update that does not mention metadata leaves the stored metadata in
  # place, so judging the attrs alone would classify the item as though it had
  # none and wrongly refuse an in-bounds edit.
  @doc false
  def merged_write_attrs(%MediaItem{} = item, attrs) do
    %{
      type: Map.get(attrs, :type) || Map.get(attrs, "type") || item.type,
      metadata: Map.get(attrs, :metadata) || Map.get(attrs, "metadata") || item.metadata
    }
  end

  @doc false
  def persist_and_audit_media_item(changeset, original, opts) do
    case Repo.update(changeset) do
      {:ok, updated} ->
        actor_type = Keyword.get(opts, :actor_type, :system)
        actor_id = Keyword.get(opts, :actor_id, "media_context")
        reason = Keyword.get(opts, :reason, "Updated")
        changes = extract_meaningful_changes(changeset, original)

        if changes != %{} do
          Events.media_item_updated(updated, actor_type, actor_id, reason, changes)
        end

        {:ok, updated}

      error ->
        error
    end
  end

  # :monitored and :monitor_new_seasons are operator settings, not metadata.
  # They are here so that a write of either lands in the item's history with
  # its old and new value, whichever caller made it. Without that, the
  # enricher's silent re-enable in getmydia/mydia#653 was indistinguishable
  # from an ordinary "Metadata enriched" update for three weeks.
  #
  # Every field here must render in the activity feed; presentation_test.exs
  # enforces it, because an audited field the feed cannot show reads as a
  # refresh that changed nothing.
  @audited_media_item_fields [
    :title,
    :original_title,
    :year,
    :monitored,
    :monitor_new_seasons,
    :category,
    :category_override,
    :tmdb_id,
    :tvdb_id
  ]

  @doc false
  def audited_media_item_fields, do: @audited_media_item_fields

  @doc false
  def extract_meaningful_changes(changeset, original) do
    changes = changeset.changes

    simple_changes =
      changes
      |> Map.take(@audited_media_item_fields)
      |> Enum.map(fn {field, new_value} ->
        old_value = Map.get(original, field)
        {field, %{old: old_value, new: new_value}}
      end)
      |> Map.new()

    # Extract meaningful changes from nested metadata
    metadata_changes =
      if Map.has_key?(changes, :metadata) do
        extract_metadata_changes(original.metadata, changes.metadata)
      else
        %{}
      end

    Map.merge(simple_changes, metadata_changes)
  end

  @doc false
  def extract_metadata_changes(nil, _new), do: %{metadata: %{old: nil, new: "added"}}
  def extract_metadata_changes(_old, nil), do: %{}

  def extract_metadata_changes(old_metadata, new_metadata) do
    # Compare interesting metadata fields
    fields_to_compare = [
      {:overview, "overview"},
      {:poster_path, "poster"},
      {:backdrop_path, "backdrop"},
      {:tagline, "tagline"},
      {:vote_average, "rating"},
      {:runtime, "runtime"},
      {:genres, "genres"}
    ]

    changes =
      Enum.reduce(fields_to_compare, [], fn {field, label}, acc ->
        old_val = MetadataAccess.get(old_metadata, field)
        new_val = MetadataAccess.get(new_metadata, field)

        if metadata_value_changed?(field, old_val, new_val) do
          [{label, format_metadata_change(field, old_val, new_val)} | acc]
        else
          acc
        end
      end)

    # Check cast/crew count changes
    changes = maybe_add_count_change(changes, old_metadata, new_metadata, :cast, "cast")
    changes = maybe_add_count_change(changes, old_metadata, new_metadata, :crew, "crew")

    if changes == [] do
      %{}
    else
      %{metadata_fields: Enum.reverse(changes)}
    end
  end

  # A rating is shown to one decimal, so it only counts as changed at that
  # precision. Comparing raw floats recorded provider vote drift (7.81 to 7.84)
  # as "Rating 7.8 → 7.8" on every weekly refresh.
  @doc false
  def metadata_value_changed?(:vote_average, old, new),
    do: format_rating(old) != format_rating(new)

  def metadata_value_changed?(_field, old, new), do: values_differ?(old, new)

  @doc false
  def values_differ?(nil, nil), do: false
  def values_differ?(nil, ""), do: false
  def values_differ?("", nil), do: false
  def values_differ?(old, new), do: old != new

  @doc false
  def format_metadata_change(:vote_average, old, new) do
    %{old: format_rating(old), new: format_rating(new)}
  end

  def format_metadata_change(:runtime, old, new) do
    %{old: format_runtime(old), new: format_runtime(new)}
  end

  def format_metadata_change(:genres, old, new) do
    %{old: format_genres(old), new: format_genres(new)}
  end

  def format_metadata_change(_field, old, new) do
    %{old: present?(old), new: present?(new)}
  end

  @doc false
  def format_rating(nil), do: nil
  def format_rating(val) when is_number(val), do: Float.round(val / 1, 1)
  def format_rating(val), do: val

  @doc false
  def format_runtime(nil), do: nil
  def format_runtime(minutes) when is_integer(minutes), do: "#{minutes}m"
  def format_runtime(val), do: val

  @doc false
  def format_genres(nil), do: nil
  def format_genres([]), do: nil
  def format_genres(genres) when is_list(genres), do: Enum.count(genres)
  def format_genres(val), do: val

  @doc false
  def present?(nil), do: nil
  def present?(""), do: nil
  def present?(_), do: true

  @doc false
  def maybe_add_count_change(changes, old_metadata, new_metadata, field, label) do
    old_count = count_list(MetadataAccess.get(old_metadata, field))
    new_count = count_list(MetadataAccess.get(new_metadata, field))

    if old_count != new_count do
      [{label, %{old: old_count, new: new_count}} | changes]
    else
      changes
    end
  end

  @doc false
  def count_list(nil), do: 0
  def count_list(list) when is_list(list), do: length(list)
  def count_list(_), do: 0
end
