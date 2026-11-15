defmodule MydiaWeb.DownloadsLive.PathMappingIssues do
  @moduledoc """
  The Downloads page's side of path-mapping suggestions: how many downloads a
  one-click apply would re-run, and re-running them once a mapping is applied.

  The suggestion itself is computed when the import fails
  (`Mydia.Jobs.MediaImport.Failure`) and arrives on the row, so rendering never
  touches the filesystem (#1315).
  """

  alias Mydia.Downloads
  alias MydiaWeb.DownloadsLive.Issue

  @doc """
  Stamps `path_mapping_affected_count` on every download carrying a
  suggestion, counting once per remote prefix.
  """
  @spec enrich_counts([map()]) :: [map()]
  def enrich_counts(downloads) do
    {enriched, _counts} =
      Enum.map_reduce(downloads, %{}, fn
        %{path_mapping_suggestion: %{remote_prefix: prefix}} = d, counts ->
          {count, counts} =
            Map.get_and_update(counts, prefix, fn
              nil ->
                count =
                  prefix |> Downloads.list_path_mapping_mismatches_under_prefix() |> length()

                {count, count}

              count ->
                {count, count}
            end)

          {%{d | path_mapping_affected_count: count}, counts}

        d, counts ->
          {d, counts}
      end)

    enriched
  end

  @doc """
  `enrich_counts/1` for the downloads behind issue rows. The count is a query,
  so callers pass only the rows on screen.
  """
  @spec enrich_issues([Issue.t()]) :: [Issue.t()]
  def enrich_issues(issues) do
    downloads = for %Issue{download: d} <- issues, d, do: d
    by_id = downloads |> enrich_counts() |> Map.new(&{&1.id, &1})

    Enum.map(issues, fn
      %Issue{download: %{id: id}} = issue -> %{issue | download: Map.fetch!(by_id, id)}
      issue -> issue
    end)
  end

  @doc """
  Re-enqueues every failed mismatch download whose reported path is under the
  applied prefix, clearing its import-failure fields. Oban uniqueness keyed on
  download_id skips any import already in flight. Returns the count.
  """
  @spec retry_under_prefix(String.t()) :: non_neg_integer()
  def retry_under_prefix(remote_prefix) do
    downloads = Downloads.list_path_mapping_mismatches_under_prefix(remote_prefix)

    Enum.each(downloads, fn download ->
      case Downloads.update_download(
             download,
             Mydia.Downloads.Download.cleared_import_failure_attrs()
           ) do
        {:ok, updated} ->
          %{
            "download_id" => updated.id,
            "save_path" => nil,
            "cleanup_client" => true,
            "use_hardlinks" => true
          }
          # MediaImport declares worker-level uniqueness keyed on download_id,
          # so an import already queued/running for this download is not
          # double-enqueued.
          |> Mydia.Jobs.MediaImport.new()
          |> Oban.insert()

        {:error, _changeset} ->
          :ok
      end
    end)

    length(downloads)
  end
end
