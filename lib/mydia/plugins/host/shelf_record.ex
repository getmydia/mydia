defmodule Mydia.Plugins.Host.ShelfRecord do
  @moduledoc """
  Marshals a shelf fill payload into the WIT `shelf-request` record that
  `Mydia.Plugins.Host` hands to a guest's `fill-shelf` export.
  """

  @doc """
  `subject` is always absent: no placement passes one yet. `feedback` is a 1.7
  field: a 1.6 guest's record has no such field, so it is dropped for them.
  `now` is the already-resolved unix time, so the caller owns the clock.
  """
  @spec build(map(), :v16 | :v17 | :v18, integer()) :: map()
  def build(payload, version, now) do
    base = %{
      shelf: to_string(Map.get(payload, "shelf") || ""),
      "user-id": opt_string(Map.get(payload, "user_id")),
      subject: :none,
      exclude: Enum.map(Map.get(payload, "exclude") || [], &to_media_ref/1),
      limit: Map.get(payload, "limit") || 12,
      now: now,
      "config-json": Jason.encode!(Map.get(payload, "config") || %{})
    }

    # Feedback goes to every contract except 1.6 (older ones never reach fill-shelf).
    if version == :v16 do
      base
    else
      Map.put(
        base,
        :feedback,
        Enum.map(Map.get(payload, "feedback") || [], &to_shelf_feedback/1)
      )
    end
  end

  # Enums (`rating`, `via`) cross as atoms, like the other WIT enums.
  defp to_shelf_feedback(feedback) do
    %{
      item: to_media_ref(feedback),
      title: to_string(Map.get(feedback, :title) || ""),
      year: opt_value(Map.get(feedback, :year)),
      rating: Map.fetch!(feedback, :rating),
      via: opt_value(Map.get(feedback, :via))
    }
  end

  defp to_media_ref(ref) do
    %{
      "media-type": to_string(Map.get(ref, :media_type) || ""),
      "tmdb-id": opt_value(Map.get(ref, :tmdb_id)),
      "tvdb-id": opt_value(Map.get(ref, :tvdb_id)),
      "imdb-id": opt_string(Map.get(ref, :imdb_id))
    }
  end

  defp opt_value(nil), do: :none
  defp opt_value(value), do: {:some, value}

  defp opt_string(nil), do: :none
  defp opt_string(value), do: {:some, to_string(value)}
end
