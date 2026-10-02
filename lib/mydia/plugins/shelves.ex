defmodule Mydia.Plugins.Shelves do
  @moduledoc """
  Plugin shelves: named, ordered lists of titles a plugin fills and the host
  stores, verifies and renders.

  A plugin declares a shelf in its manifest (`shelves`, under `surfaces:shelf`)
  and returns ids and reasons from its `fill-shelf` export. Everything else is
  here: which shelves exist, whose row is whose, when a row is stale, and what
  a user dismissed. The fill itself is in this module too (`fill/3`), run by
  `Mydia.Jobs.ShelfFill`.

  This is the only module that reads or writes the three shelf tables.
  """

  import Ecto.Query

  require Logger

  alias Mydia.Accounts
  alias Mydia.Accounts.User
  alias Mydia.Jobs.ShelfFill
  alias Mydia.Media.ProviderKey
  alias Mydia.Plugins
  alias Mydia.Plugins.Error
  alias Mydia.Plugins.Plugin
  alias Mydia.Plugins.Shelf
  alias Mydia.Plugins.ShelfDismissal
  alias Mydia.Plugins.ShelfItem
  alias Mydia.Plugins.Shelves.Declared
  alias Mydia.Plugins.Shelves.Pick
  alias Mydia.Plugins.Shelves.Verifier
  alias Mydia.Plugins.Shelves.View
  alias Mydia.Repo

  @capability "surfaces:shelf"

  # What the dashboard shows, and what a plugin is asked for. Twice the rail so
  # that the picks the verifier drops still leave a full row.
  @rail_limit 12
  @fill_limit 24
  @error_max 500

  # However often its events fire, a shelf is not refilled within this long of
  # its last fill. A binge would otherwise cost a model run per dashboard visit.
  @min_refresh_seconds 3_600

  # ── Declarations ──────────────────────────────────────────────────────────

  @doc "Every shelf declared by an enabled plugin holding `surfaces:shelf`."
  @spec declared() :: [Declared.t()]
  def declared do
    for %Plugin{enabled: true, shelves: shelves} = plugin <- Plugins.list_plugins(),
        Plugin.granted?(plugin, @capability),
        shelf <- shelves do
      %Declared{
        slug: plugin.slug,
        key: shelf["key"],
        title: shelf["title"],
        placement: shelf["placement"],
        scope: shelf["scope"],
        ttl_seconds: shelf["ttl_seconds"],
        refresh_on: shelf["refresh_on"] || []
      }
    end
  end

  @doc "The declared shelves for one placement, such as `:home`."
  @spec declared(atom() | String.t()) :: [Declared.t()]
  def declared(placement) do
    placement = to_string(placement)
    Enum.filter(declared(), &(&1.placement == placement))
  end

  @doc "One declared shelf, or `nil` when the plugin no longer declares it."
  @spec get_declared(String.t(), String.t()) :: Declared.t() | nil
  def get_declared(slug, key), do: Enum.find(declared(), &(&1.slug == slug and &1.key == key))

  # ── Reading ───────────────────────────────────────────────────────────────

  @doc """
  The user's shelves for a placement, with whatever items they currently hold.

  Returns immediately from the database. A shelf the user has never seen gets
  its row here and reads as stale; filling it is the caller's next step
  (`refresh_stale/1`).
  """
  @spec list_for(User.t(), atom() | String.t(), DateTime.t()) :: [View.t()]
  def list_for(%User{} = user, placement, now \\ DateTime.utc_now()) do
    for %Declared{} = declared <- declared(placement) do
      shelf = ensure_shelf(declared, user)
      %View{declared: declared, shelf: shelf, items: items(shelf), stale?: stale?(shelf, now)}
    end
  end

  @doc "True when the shelf has never been filled or its `stale_at` has passed."
  @spec stale?(Shelf.t(), DateTime.t()) :: boolean()
  def stale?(%Shelf{stale_at: nil}, _now), do: true
  def stale?(%Shelf{stale_at: stale_at}, now), do: DateTime.compare(now, stale_at) != :lt

  @doc "A shelf row by id, or `nil`."
  @spec get_shelf(String.t()) :: Shelf.t() | nil
  def get_shelf(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(Shelf, uuid)
      :error -> nil
    end
  end

  defp ensure_shelf(%Declared{slug: slug, key: key}, %User{id: user_id}) do
    identity = [plugin_slug: slug, shelf_key: key, user_id: user_id]

    Repo.get_by(Shelf, identity) ||
      (
        Repo.insert!(struct!(Shelf, identity),
          on_conflict: :nothing,
          conflict_target: [:plugin_slug, :shelf_key, :user_id]
        )

        Repo.get_by!(Shelf, identity)
      )
  end

  defp items(%Shelf{id: id}) do
    Repo.all(from i in ShelfItem, where: i.shelf_id == ^id, order_by: [asc: i.position])
  end

  # ── Filling ───────────────────────────────────────────────────────────────

  @doc """
  Enqueues a fill for every stale shelf among `views`. Jobs are unique per
  shelf, so two tabs or two visits cause one run.
  """
  @spec refresh_stale([View.t()]) :: :ok
  def refresh_stale(views) when is_list(views) do
    for %View{stale?: true, shelf: shelf} <- views, do: request_fill(shelf)
    :ok
  end

  @doc """
  Marks a user's shelves stale when an event their manifest names in
  `refresh_on` fires for that user.

  `stale_at` moves to now, or to an hour after the last fill if that is later,
  and never moves later than it already was. A shelf that has never been
  filled is already stale and is left alone. Nothing runs here: the fill
  happens on the user's next visit.
  """
  @spec mark_stale(map(), DateTime.t()) :: :ok
  def mark_stale(event, now \\ DateTime.utc_now())

  def mark_stale(%{type: type, actor_id: user_id} = event, now)
      when is_binary(type) and is_binary(user_id) do
    watching = for %Declared{} = d <- declared(), type in d.refresh_on, do: {d.slug, d.key}

    if watching != [] and to_string(Map.get(event, :actor_type)) == "user" do
      shelves =
        Repo.all(from s in Shelf, where: s.user_id == ^user_id and not is_nil(s.filled_at))

      for %Shelf{} = shelf <- shelves, {shelf.plugin_slug, shelf.shelf_key} in watching do
        earliest = DateTime.add(shelf.filled_at, @min_refresh_seconds)
        target = if DateTime.compare(now, earliest) == :lt, do: earliest, else: now

        if DateTime.compare(target, shelf.stale_at) == :lt do
          shelf |> Shelf.changeset(%{stale_at: target}) |> Repo.update!()
        end
      end
    end

    :ok
  end

  def mark_stale(_event, _now), do: :ok

  @doc "Enqueues a fill for one shelf."
  @spec request_fill(Shelf.t()) :: :ok
  def request_fill(%Shelf{id: id}) do
    case Mydia.Jobs.insert(ShelfFill.new(%{shelf_id: id})) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        # Best effort: the page that asked still renders, and the next visit asks again.
        Logger.warning("Failed to enqueue ShelfFill", shelf_id: id, reason: inspect(reason))
        :ok
    end
  end

  @doc """
  Asks the plugin for picks, verifies them, and stores the result.

  Returns `:filled` when the items changed (and broadcasts), `:kept` when the
  plugin had nothing new worth storing, `:failed` when the plugin or the relay
  failed (the shelf backs off and keeps its items), and `:busy` when a fill for
  this user is already running, which leaves the row untouched.

  Options: `:now`, and two test seams, `:invoker` (in place of
  `Mydia.Plugins.invoke_fill_shelf/4`) and `:resolver` (passed to the verifier).
  """
  @spec fill(Shelf.t(), Declared.t(), keyword()) :: :filled | :kept | :failed | :busy
  def fill(%Shelf{} = shelf, %Declared{} = declared, opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    invoker = Keyword.get(opts, :invoker) || (&Plugins.invoke_fill_shelf/4)

    case Accounts.get_user_by_id(shelf.user_id) do
      %User{} = user ->
        request = [exclude: exclude(shelf), limit: @fill_limit, now: now]
        claimed = claim(shelf, declared, now)

        case invoker.(declared.slug, declared.key, user, request) do
          {:ok, %{items: raw}} when is_list(raw) ->
            store_picks(claimed, declared, user, raw, now, opts)

          {:error, %Error{type: :busy}} ->
            release(claimed, shelf.stale_at)
            :busy

          {:error, %Error{message: message}} ->
            mark_failed(claimed, declared, message, now)

          _unexpected ->
            mark_failed(claimed, declared, "the plugin returned an unexpected result", now)
        end

      nil ->
        :kept
    end
  end

  @doc """
  Records a fill that raised: counts the failure, backs the shelf off and keeps
  `message` (clipped) as `last_error`. Returns `:failed`.
  """
  @spec record_crash(Shelf.t(), Declared.t(), String.t()) :: :failed
  def record_crash(%Shelf{} = shelf, %Declared{} = declared, message),
    do: mark_failed(shelf, declared, message, DateTime.utc_now())

  # Moves `stale_at` out before the plugin is called, as if this fill had
  # already failed once more. A fill that finishes overwrites it; one that is
  # killed at the job timeout, or crashes, leaves it, so the shelf does not
  # request another model run on every visit.
  defp claim(shelf, declared, now) do
    stale_at = DateTime.add(now, backoff_seconds(shelf.failure_count + 1, declared.ttl_seconds))
    shelf |> Shelf.changeset(%{stale_at: stale_at}) |> Repo.update!()
  end

  defp release(shelf, stale_at),
    do: shelf |> Shelf.changeset(%{stale_at: stale_at}) |> Repo.update!()

  defp store_picks(shelf, declared, user, raw, now, opts) do
    picks = Enum.map(raw, &Pick.from_wit/1)

    verify_opts = [
      dismissed: dismissed_keys(shelf),
      limit: @rail_limit,
      resolver: Keyword.get(opts, :resolver)
    ]

    case Verifier.verify(picks, user, verify_opts) do
      {:ok, items} ->
        replace_items(shelf, declared, items, now)

      {:error, :too_few} ->
        mark_filled(shelf, declared, now)
        :kept

      {:error, :relay_unavailable} ->
        mark_failed(
          shelf,
          declared,
          "could not verify picks: the metadata relay is unavailable",
          now
        )
    end
  end

  defp replace_items(shelf, declared, items, now) do
    rows =
      for {attrs, position} <- Enum.with_index(items) do
        Map.merge(attrs, %{
          id: Ecto.UUID.generate(),
          shelf_id: shelf.id,
          position: position,
          inserted_at: now,
          updated_at: now
        })
      end

    {:ok, _} =
      Repo.transaction(fn ->
        Repo.delete_all(from i in ShelfItem, where: i.shelf_id == ^shelf.id)
        Repo.insert_all(ShelfItem, rows)
        mark_filled(shelf, declared, now)
      end)

    # After the commit, so a subscriber that reloads sees the new rows.
    Phoenix.PubSub.broadcast(Mydia.PubSub, topic(shelf.user_id), {:shelf_updated, shelf.id})
    :filled
  end

  defp mark_filled(shelf, declared, now) do
    shelf
    |> Shelf.changeset(%{
      status: :idle,
      filled_at: now,
      stale_at: DateTime.add(now, declared.ttl_seconds),
      failure_count: 0,
      last_error: nil
    })
    |> Repo.update!()
  end

  defp mark_failed(shelf, declared, message, now) do
    failures = shelf.failure_count + 1

    shelf
    |> Shelf.changeset(%{
      status: :failed,
      stale_at: DateTime.add(now, backoff_seconds(failures, declared.ttl_seconds)),
      failure_count: failures,
      last_error: message |> to_string() |> String.slice(0, @error_max)
    })
    |> Repo.update!()

    :failed
  end

  # One hour, then six, then the shelf's own TTL: a misconfigured API key must
  # not spend a model call on every page load.
  defp backoff_seconds(1, ttl), do: min(3_600, ttl)
  defp backoff_seconds(2, ttl), do: min(21_600, ttl)
  defp backoff_seconds(_failures, ttl), do: ttl

  # What the host would reject anyway: the cards on the shelf now, and what the
  # user dismissed. Sent to the plugin so it does not spend picks on them.
  defp exclude(%Shelf{} = shelf) do
    current =
      for %ShelfItem{} = item <- items(shelf),
          into: MapSet.new(),
          do: {item.media_type, item.provider, item.provider_id}

    for {media_type, provider, id} <- MapSet.union(current, dismissed_keys(shelf)) do
      %{
        media_type: media_type,
        tmdb_id: if(provider == :tmdb, do: id),
        tvdb_id: if(provider == :tvdb, do: id),
        imdb_id: nil
      }
    end
  end

  # ── Dismissals ────────────────────────────────────────────────────────────

  @doc """
  Records that `user` is not interested in an item and removes its card.

  The dismissal is keyed on the shelf's plugin and key, so the next fill
  excludes the title even though the item row is gone.
  """
  @spec dismiss_item(User.t(), String.t()) :: :ok | {:error, :not_found}
  def dismiss_item(%User{id: user_id}, item_id) do
    with {:ok, id} <- Ecto.UUID.cast(item_id),
         %ShelfItem{shelf: %Shelf{user_id: ^user_id} = shelf} = item <-
           ShelfItem |> Repo.get(id) |> Repo.preload(:shelf) do
      {:ok, _} =
        Repo.transaction(fn ->
          Repo.insert!(
            %ShelfDismissal{
              plugin_slug: shelf.plugin_slug,
              shelf_key: shelf.shelf_key,
              user_id: user_id,
              media_type: item.media_type,
              provider: item.provider,
              provider_id: item.provider_id
            },
            on_conflict: :nothing,
            conflict_target: [
              :plugin_slug,
              :shelf_key,
              :user_id,
              :media_type,
              :provider,
              :provider_id
            ]
          )

          # Not delete!/1: a fill may have replaced the items since the lookup.
          Repo.delete_all(from i in ShelfItem, where: i.id == ^item.id)
        end)

      :ok
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "The titles this shelf's user dismissed, as provider keys."
  @spec dismissed_keys(Shelf.t()) :: MapSet.t(ProviderKey.t())
  def dismissed_keys(%Shelf{} = shelf) do
    from(d in ShelfDismissal,
      where:
        d.plugin_slug == ^shelf.plugin_slug and d.shelf_key == ^shelf.shelf_key and
          d.user_id == ^shelf.user_id,
      select: {d.media_type, d.provider, d.provider_id}
    )
    |> Repo.all()
    |> MapSet.new()
  end

  # ── Operator view ─────────────────────────────────────────────────────────

  @doc """
  How many of a plugin's shelves are failing, and the `last_error` of the one
  that failed most recently. Shown on the plugin's row in the admin page.
  """
  @spec failure_summary(String.t()) :: %{failing: non_neg_integer(), last_error: String.t() | nil}
  def failure_summary(slug) when is_binary(slug) do
    failed = from s in Shelf, where: s.plugin_slug == ^slug and s.status == :failed

    latest =
      Repo.one(from s in failed, order_by: [desc: s.updated_at], limit: 1, select: s.last_error)

    %{failing: Repo.aggregate(failed, :count), last_error: latest}
  end

  # ── Lifecycle ─────────────────────────────────────────────────────────────

  @doc """
  Empties every shelf of a user and marks them stale, so the next visit refills
  under whatever rules now apply (an access restriction changed). Dismissals
  stay. Broadcasts `{:shelf_updated, shelf_id}` for each shelf so an open page
  drops its cards.
  """
  @spec reset_for_user(String.t()) :: :ok
  def reset_for_user(user_id) when is_binary(user_id) do
    shelf_ids = Repo.all(from s in Shelf, where: s.user_id == ^user_id, select: s.id)

    {:ok, _} =
      Repo.transaction(fn ->
        Repo.delete_all(from i in ShelfItem, where: i.shelf_id in ^shelf_ids)

        Repo.update_all(from(s in Shelf, where: s.id in ^shelf_ids),
          set: [stale_at: nil, filled_at: nil]
        )
      end)

    for id <- shelf_ids,
        do: Phoenix.PubSub.broadcast(Mydia.PubSub, topic(user_id), {:shelf_updated, id})

    :ok
  end

  @doc "Deletes every shelf, item and dismissal of a plugin. Called on revoke and remove."
  @spec purge(String.t()) :: :ok
  def purge(slug) when is_binary(slug) do
    # Items go with their shelf through the foreign key.
    Repo.delete_all(from s in Shelf, where: s.plugin_slug == ^slug)
    Repo.delete_all(from d in ShelfDismissal, where: d.plugin_slug == ^slug)
    :ok
  end

  # ── Live updates ──────────────────────────────────────────────────────────

  @doc "The PubSub topic a user's shelf updates are broadcast on."
  @spec topic(String.t()) :: String.t()
  def topic(user_id), do: "plugin_shelves:#{user_id}"

  @doc "Subscribes the caller to `{:shelf_updated, shelf_id}` for this user."
  @spec subscribe(User.t()) :: :ok
  def subscribe(%User{id: user_id}),
    do: Phoenix.PubSub.subscribe(Mydia.PubSub, topic(user_id))
end
