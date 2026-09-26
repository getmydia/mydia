defmodule MydiaWeb.MediaLive.Show.RenameSelection do
  @moduledoc """
  Which files the rename modal will rename.

  The selection is a `MapSet` of media file IDs held in the LiveView. Every
  function takes the server-held previews too, so an ID the client sends can
  only ever select a file that is in the preview and would actually change.
  """

  alias Mydia.Library.Structs.RenamePreview

  @spec initial([RenamePreview.t()]) :: MapSet.t(String.t())
  def initial(previews), do: previews |> changed_ids() |> MapSet.new()

  @spec toggle_file(MapSet.t(), [RenamePreview.t()], String.t()) :: MapSet.t()
  def toggle_file(selected, previews, file_id) do
    cond do
      file_id not in changed_ids(previews) -> selected
      MapSet.member?(selected, file_id) -> MapSet.delete(selected, file_id)
      true -> MapSet.put(selected, file_id)
    end
  end

  @spec toggle_season(MapSet.t(), [RenamePreview.t()], integer()) :: MapSet.t()
  def toggle_season(selected, previews, season_number) do
    ids = previews |> Enum.filter(&(&1.season_number == season_number)) |> changed_ids()

    if Enum.all?(ids, &MapSet.member?(selected, &1)),
      do: MapSet.difference(selected, MapSet.new(ids)),
      else: MapSet.union(selected, MapSet.new(ids))
  end

  @spec season_state(MapSet.t(), [RenamePreview.t()]) :: :all | :some | :none
  def season_state(selected, previews) do
    ids = changed_ids(previews)
    picked = Enum.count(ids, &MapSet.member?(selected, &1))

    cond do
      picked == 0 -> :none
      picked == length(ids) -> :all
      true -> :some
    end
  end

  @spec groups([RenamePreview.t()]) :: [{integer() | nil, [RenamePreview.t()]}]
  def groups(previews) do
    previews
    |> Enum.chunk_by(& &1.season_number)
    |> Enum.map(fn [first | _] = chunk -> {first.season_number, chunk} end)
  end

  @spec specs(MapSet.t(), [RenamePreview.t()]) :: [%{file_id: String.t(), new_path: String.t()}]
  def specs(selected, previews) do
    for %RenamePreview{changed?: true} = p <- previews, MapSet.member?(selected, p.file_id) do
      %{file_id: p.file_id, new_path: p.proposed_path}
    end
  end

  defp changed_ids(previews), do: for(%{changed?: true, file_id: id} <- previews, do: id)
end
