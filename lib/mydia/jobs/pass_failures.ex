defmodule Mydia.Jobs.PassFailures do
  @moduledoc """
  Reports the failures of a job pass over many media items as one `job.failed`
  event carrying the counts and a capped sample, instead of one event per item
  or none at all.

  Shared by `Mydia.Jobs.MetadataRefresh` and `Mydia.Jobs.AiringEpisodeRefresh`.
  """

  alias Mydia.Events

  # Cap on how many individual failures are attached to the reported event.
  @max_samples 10

  @doc """
  Records one `job.failed` event for `failures`, a list of `{item, reason}`
  pairs where `item` has `:id` and `:title`. Does nothing when the list is
  empty. `noun` names what was refreshed in the message, e.g. `"media items"`.
  """
  @spec report(String.t(), String.t(), [{map(), term()}], non_neg_integer()) :: :ok
  def report(_job_name, _noun, [], _total), do: :ok

  def report(job_name, noun, failures, total) do
    failed = length(failures)

    samples =
      failures
      |> Enum.take(@max_samples)
      |> Enum.map(fn {item, reason} ->
        %{"media_item_id" => item.id, "title" => item.title, "reason" => inspect(reason)}
      end)

    message =
      "#{failed} of #{total} #{noun} failed to refresh " <>
        "(showing #{length(samples)} of #{failed})"

    Events.job_failed(job_name, message, %{
      "total" => total,
      "succeeded" => total - failed,
      "failed" => failed,
      "sample_failures" => samples
    })
  end
end
