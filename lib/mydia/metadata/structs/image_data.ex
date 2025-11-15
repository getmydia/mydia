defmodule Mydia.Metadata.Structs.ImageData do
  @moduledoc """
  Represents image data from metadata providers (TMDB).

  This struct provides compile-time safety for image metadata including
  posters, backdrops, and logos from providers like TMDB.

  ## Examples

      iex> ImageData.new(
      ...>   file_path: "/poster.jpg",
      ...>   width: 1000,
      ...>   height: 1500,
      ...>   aspect_ratio: 0.667
      ...> )
      %ImageData{...}
  """

  defstruct [
    :file_path,
    :width,
    :height,
    :aspect_ratio,
    :vote_average,
    :vote_count
  ]

  @type t :: %__MODULE__{
          file_path: String.t() | nil,
          width: non_neg_integer() | nil,
          height: non_neg_integer() | nil,
          aspect_ratio: float() | nil,
          vote_average: float() | nil,
          vote_count: non_neg_integer() | nil
        }

  @doc """
  Creates a new ImageData struct from a map.

  Handles both string and atom keys from API responses.

  ## Examples

      iex> ImageData.from_api_response(%{
      ...>   "file_path" => "/poster.jpg",
      ...>   "width" => 1000,
      ...>   "height" => 1500
      ...> })
      %ImageData{file_path: "/poster.jpg", width: 1000, height: 1500, ...}
  """
  def from_api_response(data) when is_map(data) do
    %__MODULE__{
      file_path: data["file_path"],
      width: data["width"],
      height: data["height"],
      aspect_ratio: data["aspect_ratio"],
      vote_average: data["vote_average"],
      vote_count: data["vote_count"]
    }
  end

  @doc """
  Creates a new ImageData struct from keyword list or map.

  ## Examples

      iex> ImageData.new(file_path: "/poster.jpg", width: 1000)
      %ImageData{file_path: "/poster.jpg", width: 1000, ...}
  """
  def new(attrs \\ []) when is_list(attrs) or is_map(attrs) do
    struct(__MODULE__, attrs)
  end

  @doc """
  Returns an empty ImageData struct.
  """
  def empty do
    %__MODULE__{}
  end

  @doc """
  Builds a full URL for the image file.

  ## Examples

      iex> image = ImageData.new(file_path: "/poster.jpg")
      iex> ImageData.full_url(image, "https://image.tmdb.org/t/p/w500")
      "https://image.tmdb.org/t/p/w500/poster.jpg"
  """
  def full_url(%__MODULE__{file_path: nil}, _base_url), do: nil

  def full_url(%__MODULE__{file_path: file_path}, base_url) do
    base_url <> file_path
  end
end
