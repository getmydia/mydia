defmodule Mydia.Indexers.CardigannDefinition.Parsed do
  @moduledoc """
  Parsed representation of a Cardigann v11 YAML indexer definition.

  This struct contains the normalized and validated structure after parsing
  the YAML definition. It's optimized for search execution and validation.
  """

  @type selector :: map()
  @type search_path :: map()
  @type search_config :: map()
  @type login_config :: map()
  @type capabilities :: map()
  @type download_config :: map()
  @type setting :: map()

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          description: String.t(),
          language: String.t(),
          type: String.t(),
          encoding: String.t(),
          links: [String.t()],
          legacylinks: [String.t()],
          capabilities: capabilities(),
          search: search_config(),
          login: login_config() | nil,
          download: download_config() | nil,
          settings: [setting()],
          request_delay: float() | nil,
          follow_redirect: boolean(),
          test_link_torrent: boolean(),
          certificates: [String.t()],
          replaces: [String.t()]
        }

  defstruct [
    :id,
    :name,
    :description,
    :language,
    :type,
    :encoding,
    :links,
    :capabilities,
    :search,
    :login,
    :download,
    settings: [],
    legacylinks: [],
    request_delay: nil,
    follow_redirect: false,
    test_link_torrent: false,
    certificates: [],
    replaces: []
  ]
end
