defmodule Mydia.Sync do
  @moduledoc """
  Audit trail for external sync attempts, across every provider.

  Deliberately provider-agnostic: Plex and Jellyfin media servers, Trakt user
  integrations, and plugins all record here, so the admin UI has one place to
  answer "did this actually run".
  """

  import Ecto.Query

  alias Mydia.Repo
  alias Mydia.Sync.Run

  @spec start_run(map()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def start_run(attrs) do
    attrs
    |> Map.put(:status, :ok)
    |> Map.put_new(:started_at, now())
    |> then(&Run.changeset(%Run{}, &1))
    |> Repo.insert()
  end

  @spec finish_run(Run.t(), :ok | :error, map(), String.t() | nil) ::
          {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def finish_run(%Run{} = run, status, counts, error) do
    run
    |> Run.changeset(%{status: status, counts: counts, error: error, finished_at: now()})
    |> Repo.update()
  end

  @doc """
  Records that a sync did not run, and why.

  `reason` is an atom from a closed set defined by callers, never external
  input, so converting it to a string here is safe.
  """
  @spec record_skip(map(), atom()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def record_skip(attrs, reason) when is_atom(reason) do
    attrs
    |> Map.merge(%{
      status: :skipped,
      skip_reason: Atom.to_string(reason),
      started_at: now(),
      finished_at: now()
    })
    |> then(&Run.changeset(%Run{}, &1))
    |> Repo.insert()
  end

  @spec last_run(String.t(), String.t()) :: Run.t() | nil
  def last_run(provider, instance_id) do
    Run
    |> where([r], r.provider == ^provider and r.provider_instance_id == ^instance_id)
    |> order_by([r], desc: r.inserted_at, desc: r.id)
    |> limit(1)
    |> Repo.one()
  end

  @spec prune(pos_integer()) :: {integer(), nil}
  def prune(older_than_days) do
    cutoff =
      DateTime.utc_now() |> DateTime.add(-older_than_days, :day) |> DateTime.truncate(:second)

    Run
    |> where([r], r.inserted_at < ^cutoff)
    |> Repo.delete_all()
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
