defmodule Mydia.Metadata.Structs.ImagesResponse do
  @moduledoc """
  Represents a collection of images returned by metadata provider's fetch_images/3 callback.

  This struct provides compile-time safety for image collection responses from external
  metadata providers. Individual images are represented as ImageData structs.

  ## Fields

  - `:posters` - List of poster images (vertical orientation, typically 2:3 aspect ratio)
  - `:backdrops` - List of backdrop images (horizontal orientation, typically 16:9)
  - `:logos` - List of logo images (transparent PNGs with show/movie branding)
  """

  alias Mydia.Metadata.Structs.ImageData

  @enforce_keys [:posters, :backdrops, :logos]
  defstruct [:posters, :backdrops, :logos]

  @type t :: %__MODULE__{
          posters: [ImageData.t()],
          backdrops: [ImageData.t()],
          logos: [ImageData.t()]
        }

  @doc """
  Creates a new ImagesResponse struct.

  ## Examples

      iex> new(posters: [], backdrops: [], logos: [])
      %ImagesResponse{posters: [], backdrops: [], logos: []}
  """
  @spec new(map() | keyword()) :: t()
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    struct!(__MODULE__, attrs)
  end

  @doc """
  Creates an ImagesResponse from API response data.

  Parses raw API response containing image lists and converts them to ImageData structs.

  ## Parameters

  - `data` - Map containing "posters", "backdrops", and "logos" keys with image data

  ## Returns

  ImagesResponse struct with parsed ImageData structs for each image type.

  ## Examples

      iex> from_api_response(%{"posters" => [%{"file_path" => "/p.jpg"}], "backdrops" => [], "logos" => []})
      %ImagesResponse{posters: [%ImageData{...}], backdrops: [], logos: []}
  """
  @spec from_api_response(map()) :: t()
  def from_api_response(%{"posters" => posters, "backdrops" => backdrops, "logos" => logos}) do
    new(%{
      posters: Enum.map(posters || [], &ImageData.from_api_response/1),
      backdrops: Enum.map(backdrops || [], &ImageData.from_api_response/1),
      logos: Enum.map(logos || [], &ImageData.from_api_response/1)
    })
  end

  def from_api_response(_), do: new(%{posters: [], backdrops: [], logos: []})
end
