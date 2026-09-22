defmodule Mydia.Downloads.AutoRejectCap do
  @moduledoc """
  The per-media-item cap on automatic rejections.

  `Mydia.Jobs.DownloadMonitor` records each automatic give-up (a torrent with
  nothing importable in it, a stall past the escalation window) as a failure
  on the `"auto_reject"` search backoff of the download's media item. Once the
  count reaches the limit, the monitor stops rejecting that item's downloads:
  when the same title keeps tripping a detector, the detector is the likelier
  thing to be wrong. The Downloads page reads the same rule, so it can tell the
  operator a stall will not be acted on.
  """

  import Ecto.Query

  alias Mydia.Repo
  alias Mydia.Search.SearchBackoff

  @resource_type "auto_reject"

  @doc """
  The configured `downloads.auto_reject_limit`, 3 when unset.

  Read through the layered runtime config rather than a flat
  `Application.get_env/2` key: nothing explodes the resolved `Config.Schema`
  struct back out to flat top-level keys, so a flat read would silently ignore
  both the env var and the settings UI.
  """
  @spec limit() :: pos_integer()
  def limit do
    case Mydia.Config.get() do
      %{downloads: %{auto_reject_limit: limit}} when is_integer(limit) and limit > 0 -> limit
      _ -> 3
    end
  end

  @doc """
  Whether `media_item_id` has used up its automatic rejections.

  A download bound to no media item has no counter to consult, so it is never
  capped.
  """
  @spec exhausted?(binary() | nil) :: boolean()
  def exhausted?(nil), do: false

  def exhausted?(media_item_id) do
    case Mydia.Search.get_backoff_info(@resource_type, media_item_id) do
      %{failure_count: count} -> count >= limit()
      _ -> false
    end
  end

  @doc """
  Returns the subset of `media_item_ids` that are capped, in one query.
  """
  @spec exhausted_ids([binary() | nil]) :: MapSet.t(binary())
  def exhausted_ids(media_item_ids) when is_list(media_item_ids) do
    case media_item_ids |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] ->
        MapSet.new()

      ids ->
        limit = limit()

        from(b in SearchBackoff,
          where: b.resource_type == @resource_type,
          where: b.resource_id in ^ids,
          where: is_nil(b.season_number),
          where: b.failure_count >= ^limit,
          select: b.resource_id
        )
        |> Repo.all()
        |> MapSet.new()
    end
  end
end
