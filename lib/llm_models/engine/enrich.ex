defmodule LLMModels.Enrich do
  @moduledoc """
  Lightweight, deterministic enrichment of model data.

  This module performs simple derivations and defaults, such as:
  - Deriving model family from model ID
  - Setting provider_model_id to id if not present
  - Ensuring capability defaults are applied (handled by Zoi schemas)
  """

  @doc """
  Derives the family name from a model ID using prefix logic.

  Extracts family from model ID by splitting on "-" and taking all but the last segment.
  Returns nil if the family cannot be reasonably derived.

  ## Examples

      iex> LLMModels.Enrich.derive_family("gpt-4o-mini")
      "gpt-4o"

      iex> LLMModels.Enrich.derive_family("claude-3-opus")
      "claude-3"

      iex> LLMModels.Enrich.derive_family("gemini-1.5-pro")
      "gemini-1.5"

      iex> LLMModels.Enrich.derive_family("single")
      nil

      iex> LLMModels.Enrich.derive_family("two-parts")
      "two"
  """
  @spec derive_family(String.t()) :: String.t() | nil
  def derive_family(model_id) when is_binary(model_id) do
    parts = String.split(model_id, "-")

    case parts do
      [_single] ->
        nil

      parts when length(parts) >= 2 ->
        parts
        |> Enum.slice(0..-2//1)
        |> Enum.join("-")
    end
  end

  @doc """
  Enriches a single model map with derived and default values.

  Sets the following fields if not already present:
  - `family`: Derived from model ID
  - `provider_model_id`: Set to model ID

  Note: Capability defaults are handled automatically by Zoi schema validation.

  ## Examples

      iex> LLMModels.Enrich.enrich_model(%{id: "gpt-4o-mini", provider: :openai})
      %{id: "gpt-4o-mini", provider: :openai, family: "gpt-4o", provider_model_id: "gpt-4o-mini"}

      iex> LLMModels.Enrich.enrich_model(%{id: "claude-3-opus", provider: :anthropic, family: "claude-3-custom"})
      %{id: "claude-3-opus", provider: :anthropic, family: "claude-3-custom", provider_model_id: "claude-3-opus"}

      iex> LLMModels.Enrich.enrich_model(%{id: "model", provider: :openai, provider_model_id: "custom-id"})
      %{id: "model", provider: :openai, provider_model_id: "custom-id"}
  """
  @spec enrich_model(map()) :: map()
  def enrich_model(model) when is_map(model) do
    model
    |> maybe_set_family()
    |> maybe_set_provider_model_id()
    |> apply_capability_defaults()
  end

  @doc """
  Enriches a list of model maps.

  Applies `enrich_model/1` to each model in the list.

  ## Examples

      iex> LLMModels.Enrich.enrich_models([
      ...>   %{id: "gpt-4o", provider: :openai},
      ...>   %{id: "claude-3-opus", provider: :anthropic}
      ...> ])
      [
        %{id: "gpt-4o", provider: :openai, family: "gpt", provider_model_id: "gpt-4o"},
        %{id: "claude-3-opus", provider: :anthropic, family: "claude-3", provider_model_id: "claude-3-opus"}
      ]
  """
  @spec enrich_models([map()]) :: [map()]
  def enrich_models(models) when is_list(models) do
    Enum.map(models, &enrich_model/1)
  end

  # Private helpers

  defp maybe_set_family(%{family: _} = model), do: model

  defp maybe_set_family(%{id: id} = model) do
    case derive_family(id) do
      nil -> model
      family -> Map.put(model, :family, family)
    end
  end

  defp maybe_set_provider_model_id(%{provider_model_id: _} = model), do: model

  defp maybe_set_provider_model_id(%{id: id} = model) do
    Map.put(model, :provider_model_id, id)
  end

  defp apply_capability_defaults(model) do
    case Map.get(model, :capabilities) do
      nil ->
        model

      caps ->
        enriched_caps =
          caps
          |> apply_nested_defaults(:reasoning, %{enabled: false})
          |> apply_nested_defaults(:tools, %{
            enabled: false,
            streaming: false,
            strict: false,
            parallel: false
          })
          |> apply_nested_defaults(:json, %{native: false, schema: false, strict: false})
          |> apply_nested_defaults(:streaming, %{text: true, tool_calls: false})

        Map.put(model, :capabilities, enriched_caps)
    end
  end

  defp apply_nested_defaults(caps, key, defaults) do
    case Map.get(caps, key) do
      nil ->
        caps

      existing when is_map(existing) ->
        merged = Map.merge(defaults, existing)
        Map.put(caps, key, merged)
    end
  end
end
