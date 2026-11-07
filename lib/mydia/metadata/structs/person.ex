defmodule Mydia.Metadata.Structs.Person do
  @moduledoc """
  A TMDB person with their filmography split into movies and TV, best-known first.
  """

  alias Mydia.Metadata.Structs.PersonCredit

  # TMDB genre ids for Talk (10767) and News (10763) shows. A person who hosts or
  # guests on those accrues hundreds of per-episode credits that bury the work.
  @excluded_tv_genres [10767, 10763]

  @character_separator " / "

  @enforce_keys [:tmdb_id, :name]
  defstruct [
    :tmdb_id,
    :name,
    :biography,
    :birthday,
    :place_of_birth,
    :known_for_department,
    :profile_path,
    movie_credits: [],
    tv_credits: []
  ]

  @type t :: %__MODULE__{
          tmdb_id: integer(),
          name: String.t(),
          biography: String.t() | nil,
          birthday: Date.t() | nil,
          place_of_birth: String.t() | nil,
          known_for_department: String.t() | nil,
          profile_path: String.t() | nil,
          movie_credits: [PersonCredit.t()],
          tv_credits: [PersonCredit.t()]
        }

  @doc """
  Builds a person from a raw TMDB `/person/{id}` response fetched with
  `append_to_response=combined_credits`.
  """
  @spec from_api_response(map()) :: t()
  def from_api_response(%{"id" => id} = data) do
    credits =
      data
      |> get_in(["combined_credits", "cast"])
      |> List.wrap()
      |> Enum.map(&PersonCredit.from_api_response/1)
      |> Enum.reject(&(is_nil(&1) or excluded?(&1)))
      |> merge_repeats()

    {movies, shows} = Enum.split_with(credits, &(&1.media_type == :movie))

    %__MODULE__{
      tmdb_id: id,
      name: data["name"] || "",
      biography: blank_to_nil(data["biography"]),
      birthday: parse_date(data["birthday"]),
      place_of_birth: blank_to_nil(data["place_of_birth"]),
      known_for_department: data["known_for_department"],
      profile_path: data["profile_path"],
      movie_credits: sort_credits(movies),
      tv_credits: sort_credits(shows)
    }
  end

  defp excluded?(%PersonCredit{media_type: :tv_show, genre_ids: genre_ids}),
    do: Enum.any?(genre_ids, &(&1 in @excluded_tv_genres))

  defp excluded?(_), do: false

  # TMDB lists a title once per character played. Collapse to one credit per
  # (media_type, id) with the characters joined; the first entry's data wins.
  defp merge_repeats(credits) do
    credits
    |> Enum.reduce({[], %{}}, fn credit, {order, by_key} ->
      key = {credit.media_type, credit.tmdb_id}

      case by_key do
        %{^key => existing} ->
          {order, Map.put(by_key, key, merge(existing, credit))}

        _ ->
          {[key | order], Map.put(by_key, key, credit)}
      end
    end)
    |> then(fn {order, by_key} ->
      order |> Enum.reverse() |> Enum.map(&Map.fetch!(by_key, &1))
    end)
  end

  # `existing.character` may already be a join from an earlier repeat, so it is
  # split back into names before de-duplicating: A, B, A must stay "A / B".
  defp merge(existing, credit) do
    characters =
      [existing.character, credit.character]
      |> Enum.reject(&is_nil/1)
      |> Enum.flat_map(&String.split(&1, @character_separator))
      |> Enum.uniq()

    %{
      existing
      | character:
          if(characters == [], do: nil, else: Enum.join(characters, @character_separator)),
        episode_count: sum_counts(existing.episode_count, credit.episode_count)
    }
  end

  defp sum_counts(nil, b), do: b
  defp sum_counts(a, nil), do: a
  defp sum_counts(a, b), do: a + b

  # Released titles first, then unreleased (undated or future-dated) ones,
  # which can carry hype votes. Within each, best-known first: TMDB's
  # vote_count measures how widely a title was seen over its lifetime, where
  # popularity tracks this week's traffic. Ties go to the newest.
  defp sort_credits(credits) do
    today = Date.utc_today()

    Enum.sort_by(
      credits,
      &{released?(&1.date, today), &1.vote_count || 0, date_rank(&1.date)},
      :desc
    )
  end

  defp released?(nil, _today), do: false
  defp released?(%Date{} = date, today), do: Date.compare(date, today) != :gt

  defp date_rank(nil), do: -1
  defp date_rank(%Date{} = date), do: Date.to_gregorian_days(date)

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(_), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(_), do: nil
end
