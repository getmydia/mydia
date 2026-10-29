defmodule Mydia.Media.AddDefaults do
  @moduledoc """
  Resolves the settings one add uses.

  Before this module there were four add paths that each answered this
  question differently: the Add page read a per-page toolbar, Discover passed
  almost nothing, and `SearchLive` read only `monitor_by_default`. Adding the
  same title from two screens produced two different rows.

  Per field, the first non-nil value wins:

    1. an explicit value in `opts`, from the config modal or library caret
    2. for a movie's library only: the library most of its franchise lives
       in, from `Mydia.Media.FranchiseLibrary` (#1293)
    3. the user's preference, where nil means inherit
    4. the instance setting
    5. a hard fallback

  The library layers are evaluated lazily, so the franchise lookup, which can
  reach the relay, never runs when an explicit library was given.

  A user preference pointing at a deleted quality profile or library path is
  ignored rather than fatal: the add proceeds on the instance default.
  """

  alias Mydia.Accounts
  alias Mydia.Accounts.User
  alias Mydia.Accounts.UserPreference
  alias Mydia.Media.FranchiseLibrary
  alias Mydia.Settings
  alias MydiaWeb.Live.Helpers.MediaAddHelpers

  defstruct [
    :library_path_id,
    :quality_profile_id,
    :monitored,
    :season_monitoring,
    :search_on_add
  ]

  @type t :: %__MODULE__{
          library_path_id: String.t() | nil,
          quality_profile_id: String.t() | nil,
          monitored: boolean(),
          season_monitoring: String.t(),
          search_on_add: boolean()
        }

  @doc """
  Resolves the effective add settings for `user` adding `media_type`.

  `user` may be nil for callers outside a LiveView session. `opts` accepts
  `:library_path_id`, `:quality_profile_id`, `:monitored`,
  `:season_monitoring` and `:search_on_add` as explicit overrides, plus
  `:tmdb_id` (the movie being added, which enables the franchise layer),
  `:franchise_lookup` (injects the lookup in tests) and `:config` to inject a
  `Mydia.Config.Schema` struct in tests.
  """
  @spec resolve(User.t() | nil, :movie | :tv_show, keyword()) :: t()
  def resolve(user, media_type, opts \\ []) when media_type in [:movie, :tv_show] do
    config = Keyword.get_lazy(opts, :config, &Mydia.Config.get/0)
    pref = preference_for(user)

    %__MODULE__{
      library_path_id: resolve_library(opts, pref, media_type),
      quality_profile_id:
        first_present(
          [
            opts[:quality_profile_id],
            pref && UserPreference.add_quality_profile_id(pref),
            Settings.get_default_quality_profile_id()
          ],
          &Settings.quality_profile_exists?/1
        ),
      monitored:
        first([
          opts[:monitored],
          pref && UserPreference.add_monitored(pref),
          config.media.monitor_by_default,
          true
        ]),
      season_monitoring:
        first([
          opts[:season_monitoring],
          pref && UserPreference.add_season_monitoring(pref),
          config.media.default_season_monitoring,
          "all"
        ]),
      search_on_add:
        first([
          opts[:search_on_add],
          pref && UserPreference.add_search_on_add(pref),
          config.media.auto_search_on_add,
          true
        ])
    }
  end

  @doc """
  Converts resolved defaults into the option list `Mydia.Media.Add` accepts.

  `search_on_add` is deliberately omitted: it drives an Oban job after the add,
  not the media item's attributes, and `Add` would ignore it.
  """
  @spec to_add_opts(t()) :: keyword()
  def to_add_opts(%__MODULE__{} = defaults) do
    [
      library_path_id: defaults.library_path_id,
      quality_profile_id: defaults.quality_profile_id,
      monitored: defaults.monitored,
      season_monitoring: defaults.season_monitoring
    ]
  end

  @doc """
  Same as `to_add_opts/1`, with `:search_on_add` put back on.

  For the callers that queue the search themselves, or forward the opts to
  one that will: `MediaAddHelpers.add_opts_from_config/3` pops it back off
  before calling `Add`, and `AdminRequestsLive.Index.do_approve/4` passes it
  straight through to `MediaRequests.approve_request/3`. Both used to build
  this list inline with `to_add_opts(defaults) |> Keyword.put(:search_on_add,
  defaults.search_on_add)`; kept here once so they cannot drift.
  """
  @spec to_add_opts_with_search(t()) :: keyword()
  def to_add_opts_with_search(%__MODULE__{} = defaults) do
    Keyword.put(to_add_opts(defaults), :search_on_add, defaults.search_on_add)
  end

  defp preference_for(%User{} = user), do: Accounts.get_user_preference!(user)
  defp preference_for(_), do: nil

  # Takes the first non-nil value.
  defp first(values), do: Enum.find(values, &(not is_nil(&1)))

  # Takes the first non-nil value that still points at a real row, so a
  # preference left behind by a deleted profile or library degrades to the
  # next layer instead of failing the add.
  defp first_present(values, exists?) do
    Enum.find(values, fn
      nil -> false
      value -> exists?.(value)
    end)
  end

  # Each layer is a thunk so later ones, the franchise lookup above all, only
  # run when every earlier one came up empty or invalid.
  defp resolve_library(opts, pref, media_type) do
    [
      fn -> opts[:library_path_id] end,
      fn -> franchise_library(opts, media_type) end,
      fn -> pref && UserPreference.add_library_path_id(pref, media_type) end,
      fn -> default_library_id(kind_for(media_type)) end,
      fn -> fallback_library_id(media_type) end
    ]
    |> Enum.find_value(&valid_layer(&1, media_type))
  end

  defp valid_layer(layer, media_type) do
    id = layer.()
    if id && library_path_valid?(id, media_type), do: id
  end

  defp franchise_library(opts, :movie) do
    case opts[:tmdb_id] do
      id when is_integer(id) ->
        Keyword.get(opts, :franchise_lookup, &FranchiseLibrary.library_for/1).(id)

      _ ->
        nil
    end
  end

  defp franchise_library(_opts, :tv_show), do: nil

  defp default_library_id(kind) do
    case Settings.default_library_for(kind) do
      nil -> nil
      library -> library.id
    end
  end

  defp fallback_library_id(media_type) do
    case MediaAddHelpers.candidate_libraries(media_type) do
      [first | _] -> first.id
      [] -> nil
    end
  end

  # Type compatibility, not just existence. A preference pointing at a
  # series-only library under the movie key must fall through to the instance
  # default rather than misfiling a movie. `Accounts.update_preference/2`
  # rejects such a value at write time; this is the read-time half, for a
  # library whose type changed after the preference was saved.
  defp library_path_valid?(id, media_type) do
    allowed = Mydia.Library.TargetResolver.allowed_types(kind_for(media_type))
    Settings.library_path_exists_as_type?(id, allowed)
  end

  defp kind_for(:movie), do: :movies
  defp kind_for(:tv_show), do: :series
end
