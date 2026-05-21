defmodule MydiaWeb.Schema.Resolvers.NodeId do
  @moduledoc """
  Encoding and decoding for GraphQL global node IDs.

  Supports composite IDs for different node types:
  - Movies: "movie:<id>"
  - TV Shows: "show:<id>"
  - Episodes: "episode:<id>"
  - Seasons: "season:<show_id>:<season_number>"
  - Library Paths: "library:<id>"
  """

  @doc """
  Encodes a node type and ID into a global node ID string.
  """
  def encode(:movie, id), do: "movie:#{id}"
  def encode(:tv_show, id), do: "show:#{id}"
  def encode(:episode, id), do: "episode:#{id}"
  def encode(:library_path, id), do: "library:#{id}"

  @doc """
  Encodes a season node with show_id and season_number.
  """
  def encode(:season, show_id, season_number), do: "season:#{show_id}:#{season_number}"

  @doc """
  Decodes a global node ID string into {type, id} or {type, id1, id2}.

  Returns:
  - {:movie, id}
  - {:tv_show, id}
  - {:episode, id}
  - {:season, show_id, season_number}
  - {:library_path, id}
  - {:error, :invalid_node_id}
  """
  def decode("movie:" <> id) do
    case parse_id(id) do
      {:ok, parsed_id} -> {:movie, parsed_id}
      :error -> {:error, :invalid_node_id}
    end
  end

  def decode("show:" <> id) do
    case parse_id(id) do
      {:ok, parsed_id} -> {:tv_show, parsed_id}
      :error -> {:error, :invalid_node_id}
    end
  end

  def decode("episode:" <> id) do
    case parse_id(id) do
      {:ok, parsed_id} -> {:episode, parsed_id}
      :error -> {:error, :invalid_node_id}
    end
  end

  def decode("library:" <> id) do
    case parse_id(id) do
      {:ok, parsed_id} -> {:library_path, parsed_id}
      :error -> {:error, :invalid_node_id}
    end
  end

  def decode("season:" <> rest) do
    case String.split(rest, ":") do
      [show_id, season_number_str] ->
        with {:ok, parsed_show_id} <- parse_id(show_id),
             {season_number, ""} <- Integer.parse(season_number_str) do
          {:season, parsed_show_id, season_number}
        else
          _ -> {:error, :invalid_node_id}
        end

      _ ->
        {:error, :invalid_node_id}
    end
  end

  def decode("tmdb:" <> rest) do
    case String.split(rest, ":") do
      [id, season_str, episode_str] ->
        with {season, ""} <- Integer.parse(season_str),
             {episode, ""} <- Integer.parse(episode_str) do
          {:tmdb_episode, id, season, episode}
        else
          _ -> {:tmdb, rest}
        end

      _ ->
        {:tmdb, rest}
    end
  end

  def decode("tvdb:" <> rest) do
    case String.split(rest, ":") do
      [id, season_str, episode_str] ->
        with {season, ""} <- Integer.parse(season_str),
             {episode, ""} <- Integer.parse(episode_str) do
          {:tvdb_episode, id, season, episode}
        else
          _ -> {:tvdb, rest}
        end

      _ ->
        {:tvdb, rest}
    end
  end

  def decode(_), do: {:error, :invalid_node_id}

  # Parse ID - handles both integer strings and UUIDs (or any string ID)
  defp parse_id(id_str) do
    # Try to parse as integer first
    case Integer.parse(id_str) do
      {int_id, ""} ->
        {:ok, int_id}

      _ ->
        # Accept any non-empty string as a valid ID (UUIDs, etc.)
        if String.length(id_str) > 0 do
          {:ok, id_str}
        else
          :error
        end
    end
  end
end
