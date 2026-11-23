defmodule Mydia.Jobs.MovieSearch.Args do
  @moduledoc false
  defstruct [
    :mode,
    :media_item_id,
    :media_file_id,
    :min_seeders,
    :size_range,
    :blocked_tags,
    :preferred_tags,
    :reasons,
    bypass_delay: false,
    recheck: false,
    ignore_availability: false
  ]

  @type t :: %__MODULE__{
          mode: String.t() | nil,
          media_item_id: String.t() | nil,
          media_file_id: String.t() | nil,
          min_seeders: integer() | nil,
          size_range: term() | nil,
          blocked_tags: [String.t()] | nil,
          preferred_tags: [String.t()] | nil,
          reasons: [:quality | :language] | nil,
          bypass_delay: boolean(),
          recheck: boolean(),
          ignore_availability: boolean()
        }

  # bypass_delay is set only by searches the user started (Search buttons,
  # search on add, GraphQL); they skip the profile's grab delay. See
  # Mydia.Indexers.GrabDelay. recheck is set only on the re-check a delayed
  # grab schedules. ignore_availability is set only by the Search button on
  # a movie's page; see Mydia.Media.MinimumAvailability.
  def parse(raw) do
    %{
      do_parse(raw)
      | bypass_delay: Map.get(raw, "bypass_delay") == true,
        recheck: Map.get(raw, "recheck") == true,
        ignore_availability: Map.get(raw, "ignore_availability") == true
    }
  end

  defp do_parse(%{"mode" => "all_monitored"} = raw) do
    %__MODULE__{
      mode: "all_monitored",
      min_seeders: Map.get(raw, "min_seeders"),
      size_range: Map.get(raw, "size_range"),
      blocked_tags: Map.get(raw, "blocked_tags"),
      preferred_tags: Map.get(raw, "preferred_tags")
    }
  end

  defp do_parse(%{"mode" => "specific", "media_item_id" => media_item_id} = raw) do
    %__MODULE__{
      mode: "specific",
      media_item_id: media_item_id,
      min_seeders: Map.get(raw, "min_seeders"),
      size_range: Map.get(raw, "size_range"),
      blocked_tags: Map.get(raw, "blocked_tags"),
      preferred_tags: Map.get(raw, "preferred_tags")
    }
  end

  defp do_parse(
         %{
           "mode" => "upgrade",
           "media_item_id" => media_item_id,
           "media_file_id" => media_file_id
         } = raw
       ) do
    %__MODULE__{
      mode: "upgrade",
      media_item_id: media_item_id,
      media_file_id: media_file_id,
      min_seeders: Map.get(raw, "min_seeders"),
      size_range: Map.get(raw, "size_range"),
      blocked_tags: Map.get(raw, "blocked_tags"),
      preferred_tags: Map.get(raw, "preferred_tags"),
      reasons: Mydia.Upgrades.Reasons.decode(Map.get(raw, "reasons"))
    }
  end
end
