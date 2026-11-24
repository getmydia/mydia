defmodule Mydia.Events.Presentation.Changes do
  @moduledoc """
  Summarizes and labels the fields a `media_item.updated` event changed.

  `Mydia.Events.Presentation` uses `summary/1` for the one-line feed label, and
  the Activity Feed's expanded breakdown reads the same field list and labels
  (through `Mydia.Events.Presentation`), so both renderers agree.
  """

  # The top-level (non-metadata) fields a media_item.updated changeset can
  # carry. Shared by summary/1 and
  # MydiaWeb.ActivityLive.Index.format_change_details/1 so the one-line summary
  # and the expanded breakdown always render the same fields.
  @simple_change_fields ~w(title original_title year monitored monitor_new_seasons category category_override poster_override tmdb_id tvdb_id)

  @doc "Top-level media_item.updated change fields the feed renders."
  @spec simple_change_fields() :: [String.t()]
  def simple_change_fields, do: @simple_change_fields

  @doc """
  Short summary of a media_item.updated changeset, for the one-line label, or
  nil when nothing changed. The expandable per-field breakdown stays in the
  LiveView.
  """
  @spec summary(map() | nil) :: String.t() | nil
  def summary(nil), do: nil
  def summary(changes) when changes == %{}, do: nil

  def summary(changes) do
    metadata_fields =
      case Map.get(changes, "metadata_fields") do
        fields when is_list(fields) -> summarize_fields(fields)
        _ -> []
      end

    simple_fields =
      changes
      |> Map.take(@simple_change_fields)
      |> Map.keys()
      |> Enum.map(&field_label/1)

    case metadata_fields ++ simple_fields do
      [] -> nil
      parts -> Enum.join(parts, ", ")
    end
  end

  defp summarize_fields(fields) do
    names = fields |> Enum.take(3) |> Enum.map(&(&1 |> field_name() |> field_label()))
    remaining = length(fields) - 3

    if remaining > 0 do
      ["#{Enum.join(names, ", ")} +#{remaining} more"]
    else
      [Enum.join(names, ", ")]
    end
  end

  defp field_name(%{"field" => field}) when is_binary(field), do: field
  defp field_name(field) when is_binary(field), do: field
  defp field_name(_), do: "field"

  # Field labels used by both renderers of a media_item.updated changeset:
  # this module's one-line `summary/1` and the expanded breakdown in
  # `MydiaWeb.ActivityLive.Index.format_change_details/1`. One map keeps them
  # from drifting apart, which is how the summary once rendered the raw
  # `monitor_new_seasons` beside the expanded view's "New season monitoring".
  @field_labels %{
    "title" => "Title",
    "original_title" => "Original Title",
    "year" => "Year",
    "monitored" => "Monitoring",
    "monitor_new_seasons" => "New season monitoring",
    "category" => "Category",
    "category_override" => "Category override",
    "poster_override" => "Poster",
    "tmdb_id" => "TMDB ID",
    "tvdb_id" => "TVDB ID",
    "overview" => "Description",
    "poster" => "Poster",
    "backdrop" => "Backdrop",
    "tagline" => "Tagline",
    "rating" => "Rating",
    "runtime" => "Runtime",
    "genres" => "Genres",
    "cast" => "Cast",
    "crew" => "Crew"
  }

  @doc """
  Human-readable label for a `media_item.updated` changed-field name.

  Shared by `summary/1` here and
  `MydiaWeb.ActivityLive.Index.format_change_details/1`, so the short
  summary and the expanded Activity Feed breakdown always agree on how a
  field is labeled.

  `MydiaWeb.ActivityLive.Index.format_change_details/1` calls this directly
  with a raw `"field"` value pulled out of persisted event metadata, without
  going through `field_name/1` first. A malformed or legacy event (hand-edited,
  or written by a version of this code with a different metadata shape) can
  carry `nil` or a number there instead of a string. `Phoenix.Naming.humanize/1`
  only has clauses for an atom or a binary and raises `FunctionClauseError` on
  anything else, which would take down the whole Activity Feed and item
  history timeline over one bad row. Guarded here so a non-binary, non-atom
  value renders a fixed fallback label instead.
  """
  @spec field_label(term()) :: String.t()
  def field_label(field) when is_binary(field) do
    Map.get(@field_labels, field, Phoenix.Naming.humanize(field))
  end

  def field_label(field) when is_atom(field) and not is_nil(field) do
    # @field_labels is keyed by binary. Looking an atom up in it never hit, so
    # every atom field fell through to humanize/1, which also strips a trailing
    # "_id" and turned :tmdb_id into "Tmdb".
    Map.get(@field_labels, Atom.to_string(field), Phoenix.Naming.humanize(field))
  end

  def field_label(_field), do: "Unknown field"
end
