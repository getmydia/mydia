defmodule Mydia.Indexers.Cardigann.SearchRequest do
  @moduledoc """
  How one search path shapes its request: the mirrors it may try, the inputs it
  sends, its HTTP method and redirect flag, and which mirror answered.
  """

  alias Mydia.Indexers.Cardigann.AdapterSupport
  alias Mydia.Indexers.CardigannDefinition.Parsed

  # A later page of a multi-page search must hit the mirror page 1 answered on,
  # so `pin_base_url: true` tries `opts[:base_url]` alone.
  @spec candidates(Parsed.t(), keyword()) :: [String.t()]
  def candidates(definition, opts) do
    base_url = Keyword.get(opts, :base_url)

    if Keyword.get(opts, :pin_base_url, false) and is_binary(base_url) and base_url != "",
      do: [String.trim_trailing(base_url, "/")],
      else: AdapterSupport.search_candidates(definition, base_url)
  end

  # Records which mirror answered, so the later pages of a search can be pinned to it.
  @spec with_base_url(tuple(), String.t()) :: tuple()
  def with_base_url({:ok, response}, base_url),
    do: {:ok, Map.put(response, :base_url, base_url)}

  def with_base_url({:ok, response, markers}, base_url),
    do: {:ok, Map.put(response, :base_url, base_url), markers}

  # A path's own inputs are added to the search-level ones and win on a clash;
  # `inheritinputs: false` sends the path's inputs alone.
  @spec inputs(Parsed.t(), map()) :: map()
  def inputs(%Parsed{search: search}, path) do
    path_inputs = Map.get(path, :inputs) || %{}

    if Map.get(path, :inherit_inputs, true) == false,
      do: path_inputs,
      else: Map.merge(Map.get(search, :inputs) || %{}, path_inputs)
  end

  @spec method(map()) :: :get | :post
  def method(path) do
    case path |> Map.get(:method, "get") |> to_string() |> String.downcase() do
      "post" -> :post
      _ -> :get
    end
  end

  @default_receive_timeout 30_000
  @default_connect_timeout 10_000

  # A caller with a deadline names the time it has left as `:request_timeout_ms`.
  # It caps both timeouts of that one request, and without it they stay as they
  # were, so page 1, the health check and downloads are unchanged.
  @spec put_timeout(map(), keyword()) :: map()
  def put_timeout(request_params, opts) do
    case Keyword.get(opts, :request_timeout_ms) do
      ms when is_integer(ms) -> Map.put(request_params, :receive_timeout, max(ms, 1))
      _ -> request_params
    end
  end

  @spec receive_timeout(map()) :: pos_integer()
  def receive_timeout(request_params),
    do:
      min(
        Map.get(request_params, :receive_timeout, @default_receive_timeout),
        @default_receive_timeout
      )

  @spec connect_timeout(map()) :: pos_integer()
  def connect_timeout(request_params),
    do: min(receive_timeout(request_params), @default_connect_timeout)

  # A search path's own `followredirect` overrides the definition's.
  @spec follow_redirect?(Parsed.t(), map()) :: boolean()
  def follow_redirect?(definition, request_params) do
    case Map.get(request_params, :follow_redirect) do
      nil -> definition.follow_redirect == true
      value -> value == true
    end
  end
end
