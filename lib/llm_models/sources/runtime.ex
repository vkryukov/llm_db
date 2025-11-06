defmodule LLMModels.Sources.Runtime do
  @moduledoc """
  Runtime overrides for testing and development (per-call overrides).

  ## Options

  - `:overrides` - Map with `:providers` and `:models` keys, or `nil`

  ## Examples

      # In tests
      {:ok, _} = LLMModels.load(
        runtime_overrides: %{
          providers: [%{id: :sandbox, name: "Sandbox"}],
          models: [%{id: "fake-model", provider: :sandbox, capabilities: %{chat: true}}]
        }
      )

      # Or nil for no overrides
      {:ok, _} = LLMModels.load(runtime_overrides: nil)
  """

  @behaviour LLMModels.Source

  @impl true
  def load(%{overrides: nil}), do: {:ok, %{}}

  def load(%{overrides: overrides}) when is_map(overrides) do
    providers = Map.get(overrides, :providers, [])
    models = Map.get(overrides, :models, [])
    {:ok, convert_to_nested_format(providers, models)}
  end

  def load(_opts), do: {:ok, %{}}

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
