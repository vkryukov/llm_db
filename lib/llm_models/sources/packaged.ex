defmodule LLMModels.Sources.Packaged do
  @moduledoc """
  Loads model metadata from the packaged snapshot file.

  This source reads the snapshot.json file that ships with the library,
  providing a baseline set of providers and models.

  ## Options

  No options required. Reads from `priv/llm_models/snapshot.json`.

  ## Examples

      iex> Packaged.load(%{})
      {:ok, %{"openai" => %{id: :openai, models: [...]}, ...}}
  """

  @behaviour LLMModels.Source

  @impl true
  def load(_opts) do
    case LLMModels.Packaged.snapshot() do
      nil ->
        {:error, :snapshot_not_found}

      snapshot ->
        providers = Map.get(snapshot, :providers, [])
        models = Map.get(snapshot, :models, [])
        {:ok, convert_to_nested_format(providers, models)}
    end
  end

  defp convert_to_nested_format(providers, models) do
    provider_map = Map.new(providers, fn p -> {to_string(p[:id] || p["id"]), p} end)

    models_by_provider =
      Enum.group_by(models, fn m ->
        to_string(m[:provider] || m["provider"])
      end)

    Enum.reduce(provider_map, %{}, fn {provider_id, provider_data}, acc ->
      provider_models = Map.get(models_by_provider, provider_id, [])
      provider_with_models = Map.put(provider_data, :models, provider_models)
      Map.put(acc, provider_id, provider_with_models)
    end)
  end
end
