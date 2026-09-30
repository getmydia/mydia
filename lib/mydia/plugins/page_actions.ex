defmodule Mydia.Plugins.PageActions do
  @moduledoc """
  The write side of plugin pages.

  A page write arrives as a WIT record from a guest running `on-http` for a
  signed-in user. This module resolves it to host data (external ids matched,
  titles looked up), checks the plugin's `surfaces:write` grant and the user's
  role, then either executes it (the user granted the surface for this session
  or always) or parks it as a pending write for the host's confirmation modal.

  A write and its journal entry commit together: if the entry cannot be
  recorded the write is rolled back, so nothing changes without being undoable.

  The guest never learns anything but the outcome, and cannot mark a pending
  write as confirmed: only `confirm/5`, called from the host UI, can.
  """

  import Ecto.Query
  import Mydia.Plugins.PageContext, only: [page_user: 1, opt: 2]

  alias Mydia.Accounts.Authorization
  alias Mydia.Accounts.Scope
  alias Mydia.Accounts.User
  alias Mydia.Media
  alias Mydia.Metadata
  alias Mydia.Plugins.Error
  alias Mydia.Plugins.Grants
  alias Mydia.Plugins.Journal
  alias Mydia.Plugins.Matcher
  alias Mydia.Plugins.PageWrites
  alias Mydia.Plugins.PendingWrite
  alias Mydia.Plugins.Plugin
  alias Mydia.Repo
  alias Mydia.Settings

  @pending_ttl_seconds 3600

  # ── entry points (WIT records in) ──

  def media_add(plugin, ctx, target) do
    with {:ok, user} <- page_user(ctx) do
      type = Map.get(target, :"media-type")

      cond do
        type not in ["movie", "tv_show"] ->
          {:error, Error.new(:invalid_request, "media-type must be movie or tv_show")}

        Authorization.can_submit_request?(user) ->
          with {:ok, args} <- request_args(target, type),
               do: perform(plugin, ctx, user, "media_request", args)

        Authorization.can_create_media?(user) ->
          with {:ok, args} <- add_args(target, type),
               do: perform(plugin, ctx, user, "media_add", args)

        true ->
          {:error, Error.new(:capability_denied, "role #{user.role} cannot add media")}
      end
    end
  end

  def collection_create(plugin, ctx, attrs) do
    with {:ok, user} <- page_user(ctx) do
      args = %{
        "name" => opt(attrs, :name),
        "description" => opt(attrs, :description),
        "type" => opt(attrs, :kind) || "manual",
        "smart_rules" => opt(attrs, :"smart-rules-json")
      }

      perform(plugin, ctx, user, "collection_create", args)
    end
  end

  def collection_update(plugin, ctx, id, attrs) do
    with {:ok, user} <- page_user(ctx) do
      changes =
        %{
          "name" => opt(attrs, :name),
          "description" => opt(attrs, :description),
          "smart_rules" => opt(attrs, :"smart-rules-json")
        }
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()

      perform(plugin, ctx, user, "collection_update", %{"id" => id, "attrs" => changes})
    end
  end

  def collection_add_items(plugin, ctx, id, ids) do
    with {:ok, user} <- page_user(ctx),
         do:
           perform(plugin, ctx, user, "collection_add_items", %{
             "id" => id,
             "media_item_ids" => ids
           })
  end

  def collection_remove_items(plugin, ctx, id, ids) do
    with {:ok, user} <- page_user(ctx),
         do:
           perform(plugin, ctx, user, "collection_remove_items", %{
             "id" => id,
             "media_item_ids" => ids
           })
  end

  def mark_watched_state(plugin, ctx, target) do
    with {:ok, user} <- page_user(ctx),
         {:ok, content} <- match_content(target) do
      args = %{
        "content" => content,
        "watched" => Map.get(target, :watched) == true,
        "position_seconds" => opt(target, :"position-seconds"),
        "duration_seconds" => opt(target, :"duration-seconds")
      }

      perform(plugin, ctx, user, "watch_state", args)
    end
  end

  def add_favorite(plugin, ctx, target) do
    with {:ok, user} <- page_user(ctx) do
      match = %{
        imdb: opt(target, :"imdb-id"),
        tmdb: opt(target, :"tmdb-id"),
        tvdb: opt(target, :"tvdb-id")
      }

      case Matcher.match_item(match) do
        {:media_item, id} -> perform(plugin, ctx, user, "favorite_add", %{"media_item_id" => id})
        :not_found -> {:error, Error.new(:not_found, "no library item matches")}
      end
    end
  end

  # ── confirmation (host UI only) ──

  @spec pending(String.t(), binary(), String.t(), [binary()]) ::
          {:ok, [PendingWrite.t()]} | {:error, :invalid}
  def pending(slug, user_id, session_id, ids) do
    now = now()

    rows =
      PendingWrite
      |> where(
        [p],
        p.plugin_slug == ^slug and p.user_id == ^user_id and p.session_id == ^session_id
      )
      |> where([p], p.expires_at > ^now)
      |> maybe_ids(ids)
      |> order_by([p], asc: p.inserted_at)
      |> Repo.all()

    if ids != [] and length(rows) != length(Enum.uniq(ids)),
      do: {:error, :invalid},
      else: {:ok, rows}
  end

  @spec confirm(String.t(), User.t(), String.t(), [binary()], String.t()) ::
          {:ok, [map()]} | {:error, :invalid | :choice_not_allowed}
  def confirm(slug, %User{} = user, session_id, [_ | _] = ids, choice) do
    with {:ok, _rows} <- pending(slug, user.id, session_id, ids),
         :ok <- check_choice(slug, user, choice) do
      # Claiming deletes the rows, so a second confirmation of the same ids
      # (a double click) finds nothing left to run.
      rows = claim(slug, user.id, session_id, ids)

      rows
      |> Enum.map(& &1.surface)
      |> Enum.uniq()
      |> Enum.each(&Grants.grant(slug, user.id, &1, choice, session_id))

      batch_id = Ecto.UUID.generate()
      {:ok, Enum.map(rows, &run_pending(slug, user, &1, batch_id))}
    end
  end

  def confirm(_slug, _user, _session_id, [], _choice), do: {:error, :invalid}

  @spec deny(String.t(), binary(), String.t(), [binary()]) :: :ok
  def deny(slug, user_id, session_id, ids) do
    Repo.delete_all(
      from p in PendingWrite,
        where:
          p.plugin_slug == ^slug and p.user_id == ^user_id and p.session_id == ^session_id and
            p.id in ^ids
    )

    :ok
  end

  # ── core ──

  defp perform(%Plugin{} = plugin, ctx, %User{} = user, op, args) do
    surface = PageWrites.surface(op)

    with :ok <- require_surface(plugin.granted_capabilities, surface),
         :ok <- require_role(plugin.slug, user, op) do
      description = describe(op, args, user)

      if Grants.granted?(plugin.slug, user.id, surface, ctx.session_id) do
        execute_and_journal(plugin.slug, user, op, args, description, ctx.invocation_id)
      else
        park(plugin.slug, user, ctx.session_id, op, surface, args, description)
      end
    end
  end

  # The write and its journal entry commit together, or neither does.
  defp execute_and_journal(slug, user, op, args, description, batch_id) do
    outcome =
      Repo.transaction(fn ->
        with {:ok, result, inverse} <- PageWrites.execute(op, args, user, "plugin:#{slug}"),
             {:ok, _entry} <-
               Journal.record(slug, user.id, op, args, result, inverse, description, batch_id) do
          result
        else
          {:error, %Error{} = error} ->
            Repo.rollback(error)

          {:error, _changeset} ->
            Repo.rollback(Error.new(:unknown, "could not record the write in the journal"))
        end
      end)

    case outcome do
      {:ok, result} -> {:ok, {:done, Jason.encode!(result)}}
      {:error, %Error{} = error} -> {:error, error}
      {:error, _} -> {:error, Error.new(:unknown, "the write was rolled back")}
    end
  end

  defp park(slug, user, session_id, op, surface, args, description) do
    expires = DateTime.add(now(), @pending_ttl_seconds)

    %PendingWrite{}
    |> PendingWrite.changeset(%{
      plugin_slug: slug,
      user_id: user.id,
      session_id: session_id,
      op: op,
      surface: surface,
      args: args,
      description: description,
      expires_at: expires
    })
    |> Repo.insert()
    |> case do
      {:ok, row} -> {:ok, {:"needs-confirmation", row.id}}
      {:error, _} -> {:error, Error.new(:unknown, "could not queue the write")}
    end
  end

  defp claim(slug, user_id, session_id, ids) do
    {_count, rows} =
      Repo.delete_all(
        from(p in PendingWrite,
          where:
            p.plugin_slug == ^slug and p.user_id == ^user_id and p.session_id == ^session_id and
              p.id in ^ids,
          select: p
        )
      )

    Enum.sort_by(rows, & &1.inserted_at, DateTime)
  end

  # The plugin's grant and the user's role are checked again here: either may
  # have changed since the write was parked.
  defp run_pending(slug, user, row, batch_id) do
    with :ok <- require_surface(plugin_capabilities(slug), row.surface),
         :ok <- require_role(slug, user, row.op),
         {:ok, {:done, json}} <-
           execute_and_journal(slug, user, row.op, row.args, row.description, batch_id) do
      %{id: row.id, ok: true, result: Jason.decode!(json), error: nil}
    else
      {:error, %Error{message: m}} -> %{id: row.id, ok: false, result: nil, error: m}
    end
  end

  defp plugin_capabilities(slug) do
    case Settings.get_plugin_config_by_slug(slug) do
      %{enabled: true, granted_capabilities: %{} = caps} -> caps
      _ -> %{}
    end
  end

  defp check_choice(slug, user, choice) do
    if choice in Grants.allowed_choices(slug, user.role),
      do: :ok,
      else: {:error, :choice_not_allowed}
  end

  defp require_surface(capabilities, surface) do
    if surface in List.wrap(Map.get(capabilities, "surfaces:write")),
      do: :ok,
      else: {:error, Error.new(:capability_denied, "surfaces:write #{surface} not granted")}
  end

  defp require_role(slug, user, op) do
    cond do
      Grants.ceiling(slug, user.role) == "none" ->
        {:error, Error.new(:capability_denied, "role #{user.role} cannot write through #{slug}")}

      not op_allowed?(op, user) ->
        {:error, Error.new(:capability_denied, "role #{user.role} cannot do this")}

      true ->
        :ok
    end
  end

  # Add.from_provider does not check the role, so adding to the library is
  # gated here.
  defp op_allowed?("media_add", user), do: Authorization.can_create_media?(user)
  defp op_allowed?("media_request", user), do: Authorization.can_submit_request?(user)
  defp op_allowed?(_op, _user), do: true

  defp match_content(target) do
    match = %{
      imdb: opt(target, :"imdb-id"),
      tmdb: opt(target, :"tmdb-id"),
      tvdb: opt(target, :"tvdb-id"),
      season: opt(target, :"season-number"),
      episode: opt(target, :"episode-number")
    }

    case Matcher.match(match) do
      {:movie, id} -> {:ok, %{"media_item_id" => id}}
      {:episode, id} -> {:ok, %{"episode_id" => id}}
      :not_found -> {:error, Error.new(:not_found, "no library item matches")}
    end
  end

  defp request_args(target, type) do
    with {:ok, ref} <- ref_from(target, type),
         {:ok, meta} <- fetch_meta(ref, type) do
      {:ok,
       %{
         "media_type" => type,
         "tmdb_id" => opt(target, :"tmdb-id"),
         "tvdb_id" => opt(target, :"tvdb-id"),
         "title" => meta.title,
         "year" => meta.year
       }}
    end
  end

  defp add_args(target, type) do
    with {:ok, {provider, id} = ref} <- ref_from(target, type),
         {:ok, meta} <- fetch_meta(ref, type) do
      {:ok,
       %{
         "media_type" => type,
         "provider" => Atom.to_string(provider),
         "provider_id" => id,
         "title" => meta.title,
         "year" => meta.year
       }}
    end
  end

  defp ref_from(target, "tv_show") do
    case {opt(target, :"tvdb-id"), opt(target, :"tmdb-id")} do
      {tvdb, _} when is_integer(tvdb) -> {:ok, {:tvdb, tvdb}}
      {_, tmdb} when is_integer(tmdb) -> {:ok, {:tmdb, tmdb}}
      _ -> {:error, Error.new(:invalid_request, "tvdb-id or tmdb-id required")}
    end
  end

  defp ref_from(target, "movie") do
    case opt(target, :"tmdb-id") do
      tmdb when is_integer(tmdb) -> {:ok, {:tmdb, tmdb}}
      _ -> {:error, Error.new(:invalid_request, "tmdb-id required for a movie")}
    end
  end

  # Title and year for the confirmation text and the request row come from
  # metadata-relay, never from the guest.
  defp fetch_meta(ref, type) do
    type_atom = String.to_existing_atom(type)

    case Metadata.fetch_by_ref_cached(Metadata.default_relay_config(), ref, media_type: type_atom) do
      {:ok, meta} ->
        attrs = Mydia.Media.AttrsFromMetadata.from_metadata(meta, type_atom)
        {:ok, %{title: attrs.title, year: attrs[:year]}}

      {:error, _} ->
        {:error, Error.new(:not_found, "no catalog entry for that id")}
    end
  end

  defp describe("media_request", a, _u), do: "Request #{title_year(a)}"
  defp describe("media_add", a, _u), do: "Add #{title_year(a)} to the library"
  defp describe("favorite_add", a, u), do: "Add #{item_title(u, a["media_item_id"])} to Favorites"
  defp describe("collection_create", a, _u), do: "Create the collection \"#{a["name"]}\""

  defp describe("collection_update", a, u),
    do: "Edit the collection \"#{collection_name(u, a["id"])}\""

  defp describe("collection_add_items", a, u),
    do: "Add #{length(a["media_item_ids"])} item(s) to \"#{collection_name(u, a["id"])}\""

  defp describe("collection_remove_items", a, u),
    do: "Remove #{length(a["media_item_ids"])} item(s) from \"#{collection_name(u, a["id"])}\""

  defp describe("watch_state", %{"content" => content, "watched" => w}, u) do
    verb = if w, do: "Mark as watched:", else: "Mark as unwatched:"
    "#{verb} #{content_title(u, content)}"
  end

  defp title_year(%{"title" => t, "year" => y}) when is_integer(y), do: "#{t} (#{y})"
  defp title_year(%{"title" => t}), do: t

  defp item_title(user, id) do
    Media.get_media_item!(Scope.for_user(user), id).title
  rescue
    Ecto.NoResultsError -> "an item"
  end

  defp content_title(user, %{"media_item_id" => id}), do: item_title(user, id)

  defp content_title(user, %{"episode_id" => id}) do
    ep = Media.get_episode!(Scope.for_user(user), id, preload: [:media_item])
    "#{ep.media_item.title} S#{pad(ep.season_number)}E#{pad(ep.episode_number)}"
  rescue
    Ecto.NoResultsError -> "an episode"
  end

  defp collection_name(user, id) do
    case Mydia.Collections.get_collection(user, id) do
      %{name: name} -> name
      nil -> "a collection"
    end
  end

  defp pad(n) when is_integer(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
  defp pad(_), do: "??"

  defp maybe_ids(query, []), do: query
  defp maybe_ids(query, ids), do: where(query, [p], p.id in ^ids)

  # :utc_datetime columns reject microseconds.
  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)
end
