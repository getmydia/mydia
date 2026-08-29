defmodule Mydia.Collections.SmartRulesFields do
  @moduledoc """
  Provides field definitions and value options for smart collection rules.

  This module centralizes field metadata and dynamically fetches available
  values from the database where appropriate.
  """

  import Ecto.Query, warn: false
  import Mydia.DB, only: [json_extract: 2, json_not_null: 2]

  alias Mydia.Media.MediaCategory
  alias Mydia.Media.MediaItem
  alias Mydia.Repo

  @doc """
  Returns field definitions with their types, operators, and value options.
  """
  def field_definitions do
    %{
      "type" => %{
        label: "Type",
        group: "Basic",
        type: :enum,
        operators: [:eq, :in, :not_in],
        values: &type_values/0
      },
      "category" => %{
        label: "Category",
        group: "Basic",
        type: :enum,
        operators: [:eq, :in, :not_in],
        values: &category_values/0
      },
      "year" => %{
        label: "Year",
        group: "Basic",
        type: :number,
        operators: [:eq, :gt, :gte, :lt, :lte, :between],
        values: nil
      },
      "title" => %{
        label: "Title",
        group: "Basic",
        type: :text,
        operators: [:eq, :contains],
        values: nil
      },
      "monitored" => %{
        label: "Monitored",
        group: "Basic",
        type: :boolean,
        operators: [:eq],
        values: &boolean_values/0
      },
      "metadata.vote_average" => %{
        label: "Rating",
        group: "Metadata",
        type: :number,
        operators: [:eq, :gt, :gte, :lt, :lte, :between],
        values: nil,
        input_opts: %{min: 0, max: 10, step: 0.1}
      },
      "metadata.genres" => %{
        label: "Genre",
        group: "Metadata",
        type: :enum,
        operators: [:contains, :contains_any],
        values: &genre_values/0
      },
      "metadata.original_language" => %{
        label: "Language",
        group: "Metadata",
        type: :enum,
        operators: [:eq, :in, :not_in],
        values: &language_values/0
      },
      "metadata.status" => %{
        label: "Status",
        group: "Metadata",
        type: :enum,
        operators: [:eq, :in, :not_in],
        values: &status_values/0
      },
      "inserted_at" => %{
        label: "Date Added",
        group: "Dates",
        type: :date,
        operators: [:gt, :gte, :lt, :lte],
        values: nil
      }
    }
  end

  @doc """
  Returns the definition for a specific field.
  """
  def get_field(field_name) do
    Map.get(field_definitions(), field_name)
  end

  @doc """
  Returns available values for a field (calls the values function if defined).
  """
  def get_values(field_name) do
    case get_field(field_name) do
      %{values: nil} -> []
      %{values: values_fn} when is_function(values_fn) -> values_fn.()
      _ -> []
    end
  end

  @doc """
  Returns operators for a field.
  """
  def get_operators(field_name) do
    case get_field(field_name) do
      %{operators: ops} -> ops
      _ -> [:eq, :gt, :gte, :lt, :lte, :in, :not_in, :contains, :between]
    end
  end

  @doc """
  Returns operator labels for display.
  """
  def operator_labels do
    %{
      eq: "equals",
      gt: "greater than",
      gte: "at least",
      lt: "less than",
      lte: "at most",
      in: "is one of",
      not_in: "is not one of",
      contains: "contains",
      contains_any: "contains any of",
      between: "between"
    }
  end

  @doc """
  Returns a label for an operator.
  """
  def operator_label(operator) when is_atom(operator) do
    Map.get(operator_labels(), operator, to_string(operator))
  end

  def operator_label(operator) when is_binary(operator) do
    operator_label(String.to_existing_atom(operator))
  rescue
    ArgumentError -> operator
  end

  # Value providers - query from database where possible

  defp type_values do
    [
      {"movie", "Movie"},
      {"tv_show", "TV Show"}
    ]
  end

  defp category_values do
    MediaCategory.all()
    |> Enum.map(fn cat -> {to_string(cat), MediaCategory.label(cat)} end)
  end

  defp boolean_values do
    [
      {"true", "Yes (Monitored)"},
      {"false", "No (Not Monitored)"}
    ]
  end

  @doc """
  Returns distinct genres from all media items in the database.
  """
  def genre_values do
    from(m in MediaItem,
      select: json_extract(m.metadata, "$.genres"),
      where: json_not_null(m.metadata, "$.genres")
    )
    |> Repo.all()
    |> Enum.flat_map(&decode_genre_list/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn genre -> {genre, genre} end)
  end

  defp decode_genre_list(json_str) when is_binary(json_str) do
    case Jason.decode(json_str) do
      {:ok, genres} when is_list(genres) -> Enum.filter(genres, &is_binary/1)
      _ -> []
    end
  end

  defp decode_genre_list(_), do: []

  @doc """
  Returns distinct languages from all media items in the database.
  """
  def language_values do
    # Common language code to name mapping
    language_names = %{
      "en" => "English",
      "ja" => "Japanese",
      "ko" => "Korean",
      "es" => "Spanish",
      "fr" => "French",
      "de" => "German",
      "it" => "Italian",
      "pt" => "Portuguese",
      "zh" => "Chinese",
      "ru" => "Russian",
      "hi" => "Hindi",
      "ar" => "Arabic",
      "th" => "Thai",
      "tr" => "Turkish",
      "pl" => "Polish",
      "nl" => "Dutch",
      "sv" => "Swedish",
      "da" => "Danish",
      "no" => "Norwegian",
      "fi" => "Finnish",
      "id" => "Indonesian",
      "vi" => "Vietnamese",
      "cs" => "Czech",
      "el" => "Greek",
      "he" => "Hebrew",
      "hu" => "Hungarian",
      "ro" => "Romanian",
      "uk" => "Ukrainian",
      "ms" => "Malay",
      "tl" => "Tagalog",
      "ta" => "Tamil",
      "te" => "Telugu",
      "bn" => "Bengali",
      "cn" => "Cantonese"
    }

    from(m in MediaItem,
      select: json_extract(m.metadata, "$.original_language"),
      where: json_not_null(m.metadata, "$.original_language"),
      distinct: true
    )
    |> Repo.all()
    |> Enum.filter(&is_binary/1)
    |> Enum.sort()
    |> Enum.map(fn code ->
      name = Map.get(language_names, code, String.upcase(code))
      {code, name}
    end)
  end

  @doc """
  Returns distinct status values from all media items in the database.
  """
  def status_values do
    from(m in MediaItem,
      select: json_extract(m.metadata, "$.status"),
      where: json_not_null(m.metadata, "$.status"),
      distinct: true
    )
    |> Repo.all()
    |> Enum.filter(&is_binary/1)
    |> Enum.sort()
    |> Enum.map(fn status -> {status, status} end)
  end
end
