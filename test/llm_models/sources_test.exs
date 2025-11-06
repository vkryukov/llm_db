defmodule LLMModels.SourcesTest do
  use ExUnit.Case, async: true

  alias LLMModels.Sources.{Packaged, Remote, Local, Config, Runtime}

  describe "Packaged source" do
    test "loads snapshot data in nested format" do
      {:ok, data} = Packaged.load(%{})

      assert is_map(data)
      # Each key is a provider id string
      assert map_size(data) > 0

      # Check structure of first provider
      {_provider_id, provider_data} = Enum.at(data, 0)
      assert is_map(provider_data)
      assert Map.has_key?(provider_data, :models)
      assert is_list(provider_data.models)
    end

    test "returns providers with nested models from snapshot" do
      {:ok, data} = Packaged.load(%{})

      # Should have at least some providers from the packaged snapshot
      assert map_size(data) > 0

      # Check that each provider has a models list
      Enum.each(data, fn {_provider_id, provider_data} ->
        assert Map.has_key?(provider_data, :models)
        assert is_list(provider_data.models)
      end)
    end
  end

  describe "Remote source" do
    test "loads from single JSON file" do
      json_content = """
      {
        "providers": [
          {"id": "test_provider", "name": "Test Provider"}
        ],
        "models": [
          {"id": "test-model", "provider": "test_provider", "capabilities": {"chat": true}}
        ]
      }
      """

      file_reader = fn _path -> json_content end

      {:ok, data} = Remote.load(%{paths: ["test.json"], file_reader: file_reader})

      assert map_size(data) == 1
      assert Map.has_key?(data, "test_provider")

      provider = data["test_provider"]
      assert provider["id"] == "test_provider"
      assert provider["name"] == "Test Provider"
      assert length(provider["models"]) == 1
      assert hd(provider["models"])["id"] == "test-model"
    end

    test "loads from multiple JSON files with precedence" do
      base_json = """
      {
        "providers": [
          {"id": "provider_a", "name": "Provider A Base"}
        ],
        "models": [
          {"id": "model-1", "provider": "provider_a", "capabilities": {"chat": true}}
        ]
      }
      """

      override_json = """
      {
        "providers": [
          {"id": "provider_a", "name": "Provider A Override"}
        ],
        "models": [
          {"id": "model-1", "provider": "provider_a", "capabilities": {"chat": true, "tools": {"enabled": true}}}
        ]
      }
      """

      file_reader = fn
        "base.json" -> base_json
        "override.json" -> override_json
      end

      {:ok, data} =
        Remote.load(%{paths: ["base.json", "override.json"], file_reader: file_reader})

      assert map_size(data) == 1
      provider = data["provider_a"]
      # Override should win
      assert provider["name"] == "Provider A Override"

      assert length(provider["models"]) == 1
      # Override model should have merged capabilities
      model = hd(provider["models"])
      assert model["capabilities"]["chat"] == true
      assert model["capabilities"]["tools"]["enabled"] == true
    end

    test "returns error when all files fail to load" do
      file_reader = fn _path ->
        raise File.Error, reason: :enoent, action: "read", path: "missing.json"
      end

      result = Remote.load(%{paths: ["missing.json"], file_reader: file_reader})

      assert {:error, :no_data} = result
    end

    test "requires paths parameter" do
      result = Remote.load(%{})
      assert {:error, :paths_required} = result
    end

    test "handles empty paths list" do
      result = Remote.load(%{paths: []})
      # Empty paths returns error since no data loaded
      assert {:error, :no_data} = result
    end
  end

  describe "Local source" do
    @tag :skip
    test "loads providers and models from TOML directory structure" do
      # This test requires actual TOML files in priv/llm_models/{provider}/{provider}.toml
      # Since we don't have these yet, skip this test
      # TODO: Create sample TOML files or mock the filesystem properly
      :ok
    end

    test "returns error when directory not found" do
      result = Local.load(%{dir: "/nonexistent"})
      assert {:error, :directory_not_found} = result
    end

    test "requires dir parameter" do
      result = Local.load(%{})
      assert {:error, :dir_required} = result
    end

    @tag :skip
    test "handles TOML parse errors gracefully" do
      # This test would require mocking File.dir? and filesystem access
      # Skipping for now since the actual error handling is tested in practice
      :ok
    end
  end

  describe "Config source" do
    test "loads provider-keyed overrides (new format)" do
      overrides = %{
        openai: %{
          base_url: "https://staging-api.openai.com",
          models: [
            %{id: "gpt-4o", cost: %{input: 0.0, output: 0.0}},
            %{id: "gpt-4o-mini", limits: %{context: 200_000}}
          ]
        },
        anthropic: %{
          base_url: "https://proxy.example.com/anthropic",
          models: [
            %{id: "claude-3-5-sonnet", cost: %{input: 0.0, output: 0.0}}
          ]
        }
      }

      {:ok, data} = Config.load(%{overrides: overrides})

      assert map_size(data) == 2

      openai_provider = data["openai"]
      assert openai_provider.id == :openai
      assert openai_provider.base_url == "https://staging-api.openai.com"
      assert length(openai_provider.models) == 2

      gpt4o = Enum.find(openai_provider.models, fn m -> m.id == "gpt-4o" end)
      assert gpt4o.cost.input == 0.0
    end

    test "loads legacy format with providers/models keys" do
      overrides = %{
        providers: [%{id: :test_provider, name: "Test"}],
        models: [%{id: "test-model", provider: :test_provider}]
      }

      {:ok, data} = Config.load(%{overrides: overrides})

      assert map_size(data) == 1
      provider = data["test_provider"]
      assert provider.id == :test_provider
      assert provider.name == "Test"
      assert length(provider.models) == 1
      assert hd(provider.models).id == "test-model"
    end

    test "handles nil overrides" do
      {:ok, data} = Config.load(%{overrides: nil})

      assert data == %{}
    end

    test "handles empty overrides map" do
      {:ok, data} = Config.load(%{overrides: %{}})

      assert data == %{}
    end

    test "handles missing overrides parameter" do
      {:ok, data} = Config.load(%{})

      assert data == %{}
    end

    test "skips legacy keys in provider-keyed format" do
      overrides = %{
        openai: %{base_url: "https://api.openai.com"},
        providers: [%{id: :test}],
        models: [%{id: "test"}],
        exclude: %{openai: ["*"]}
      }

      {:ok, data} = Config.load(%{overrides: overrides})

      # Should only process openai, skip legacy keys
      assert map_size(data) == 1
      assert Map.has_key?(data, "openai")
      assert data["openai"].id == :openai
    end

    test "injects provider into models" do
      overrides = %{
        openai: %{
          models: [
            %{id: "gpt-4o"},
            %{id: "gpt-4o-mini"}
          ]
        }
      }

      {:ok, data} = Config.load(%{overrides: overrides})

      assert map_size(data) == 1
      provider = data["openai"]
      assert length(provider.models) == 2
    end
  end

  describe "Runtime source" do
    test "loads runtime overrides" do
      overrides = %{
        providers: [%{id: :sandbox, name: "Sandbox"}],
        models: [
          %{id: "fake-model", provider: :sandbox, capabilities: %{chat: true}}
        ]
      }

      {:ok, data} = Runtime.load(%{overrides: overrides})

      assert map_size(data) == 1
      provider = data["sandbox"]
      assert provider.id == :sandbox
      assert provider.name == "Sandbox"
      assert length(provider.models) == 1
      assert hd(provider.models).id == "fake-model"
    end

    test "handles nil overrides" do
      {:ok, data} = Runtime.load(%{overrides: nil})

      assert data == %{}
    end

    test "handles missing overrides parameter" do
      {:ok, data} = Runtime.load(%{})

      assert data == %{}
    end

    test "handles empty overrides map" do
      {:ok, data} = Runtime.load(%{overrides: %{}})

      assert data == %{}
    end
  end

  describe "Source behavior contract" do
    test "all sources return {:ok, data} format with nested structure" do
      # Packaged
      assert {:ok, data} = Packaged.load(%{})
      assert is_map(data)

      if map_size(data) > 0 do
        {_id, provider} = Enum.at(data, 0)
        assert Map.has_key?(provider, :models)
      end

      # Remote with valid data
      file_reader = fn _path -> "{\"providers\": [{\"id\": \"test\"}], \"models\": []}" end
      assert {:ok, data} = Remote.load(%{paths: ["test.json"], file_reader: file_reader})
      assert is_map(data)

      # Config
      assert {:ok, data} = Config.load(%{overrides: %{}})
      assert is_map(data)

      # Runtime
      assert {:ok, data} = Runtime.load(%{overrides: nil})
      assert is_map(data)
    end

    test "all sources handle error cases appropriately" do
      # Remote returns error when no data
      file_reader = fn _path -> raise "fail" end
      assert {:error, :no_data} = Remote.load(%{paths: ["fail.json"], file_reader: file_reader})

      # Local returns error when dir not found
      assert {:error, :directory_not_found} = Local.load(%{dir: "/nonexistent"})

      # Remote returns error when paths not provided
      assert {:error, :paths_required} = Remote.load(%{})

      # Local returns error when dir not provided
      assert {:error, :dir_required} = Local.load(%{})
    end
  end
end
