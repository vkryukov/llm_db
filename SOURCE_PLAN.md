# Source Architecture Plan: Unified Source Behavior

## Summary

Simplify data ingestion by introducing a unified `Source` behavior that supports multiple remote sources, local TOML files, application config overrides, and runtime overrides. The core model is simple: **Provider → Model**. Sources provide data; filtering and policy are separate concerns.

## Current Problems

1. **Three separate override mechanisms** (packaged, config, behaviour) with unclear boundaries
2. **Complex precedence rules** spread across different concepts
3. **Confusing developer experience** - too many ways to provide data
4. **No support for multiple remote sources** with clear precedence
5. **Excludes mixed into source data** instead of being treated as filtering policy

## Design Goals

1. **Simple mental model**: Provider → Model is the core relationship
2. **Unified Source behavior** that works for all data sources
3. **Clear, deterministic precedence** across all layers
4. **Optimized developer experience** - common cases are simple
5. **Layered architecture** where each source type has a clear purpose
6. **Separation of concerns**: Sources provide data; filters control policy

---

## Architecture

### Source Behavior

A simple contract that all sources implement:

```elixir
defmodule LLMModels.Source do
  @moduledoc """
  Unified data source interface.
  
  Sources return only providers and models. No filtering, no excludes.
  """
  
  @type data :: %{providers: [map()], models: [map()]}
  
  @callback load(opts :: map()) :: {:ok, data()} | {:error, term()}
end
```

**Key principles:**
- Sources return **only** `%{providers: [...], models: [...]}`
- No excludes, no filters at source level
- Unknown keys allowed; schemas validate later
- Providers keyed by `:id` (atom)
- Models keyed by `{provider, id}` tuple

### Built-in Source Types

#### 1. Remote (Multiple JSON files)

**Module:** `LLMModels.Sources.Remote`

**Purpose:** Load model metadata from one or more remote JSON files (models.dev-compatible)

**Configuration:**
```elixir
config :llm_models,
  remote_sources: [
    "priv/llm_models/upstream/models-dev.json",
    "priv/llm_models/upstream/vendor-x.json"
  ]
```

**Behavior:**
- Reads multiple JSON files in order
- Later files override earlier files within the Remote layer
- Returns merged `%{providers: [...], models: [...]}`
- Errors are logged; failed sources skipped

**Example:**
```elixir
defmodule LLMModels.Sources.Remote do
  @behaviour LLMModels.Source
  
  @impl true
  def load(%{paths: paths}) do
    data = Enum.reduce(paths, %{providers: [], models: []}, fn path, acc ->
      case load_json_file(path) do
        {:ok, content} -> merge_layer(acc, normalize_remote(content))
        {:error, _} -> acc  # Skip failed sources
      end
    end)
    
    {:ok, data}
  end
end
```

#### 2. Local TOML (PR-friendly repository)

**Module:** `LLMModels.Sources.Local`

**Purpose:** Authoritative repository data, version-controlled, PR-friendly

**Directory structure:**
```
priv/llm_models/
├── openai/
│   ├── openai.toml          # Provider definition
│   ├── gpt-4o.toml          # Model
│   └── gpt-4o-mini.toml     # Model
├── anthropic/
│   ├── anthropic.toml
│   └── claude-3-5-sonnet.toml
└── ...
```

**Configuration:**
```elixir
config :llm_models,
  local_dir: "priv/llm_models"
```

**Example provider TOML** (`openai/openai.toml`):
```toml
id = "openai"
name = "OpenAI"
base_url = "https://api.openai.com"
env = ["OPENAI_API_KEY"]
doc = "https://platform.openai.com/docs"
```

**Example model TOML** (`openai/gpt-4o-mini.toml`):
```toml
id = "gpt-4o-mini"
provider = "openai"
name = "GPT-4o mini"
family = "gpt-4o"
release_date = "2024-05-13"

[limits]
context = 128000
output = 16384

[cost]
input = 0.15
output = 0.60

[capabilities]
chat = true

[capabilities.tools]
enabled = true
streaming = true
```

#### 3. Config Overrides (Application environment)

**Module:** `LLMModels.Sources.Config`

**Purpose:** Environment-specific tweaks (staging, production, etc.)

**Configuration:**
```elixir
config :llm_models,
  overrides: %{
    openai: %{
      base_url: "https://staging-api.openai.com",
      models: [
        %{id: "gpt-4o", cost: %{input: 0.0, output: 0.0}},
        %{id: "gpt-4o-mini", cost: %{input: 0.0, output: 0.0}}
      ]
    },
    anthropic: %{
      base_url: "https://proxy.example.com/anthropic",
      models: [
        %{id: "claude-3-5-sonnet", limits: %{context: 200_000}}
      ]
    }
  }
```

**Structure:**
- Map keyed by provider atom (`:openai`, `:anthropic`, etc.)
- Each provider entry contains:
  - Provider field overrides (e.g., `base_url`, `name`, `env`) merged directly
  - `models`: List of model overrides for that provider (special key)

**Example:**
```elixir
defmodule LLMModels.Sources.Config do
  @behaviour LLMModels.Source
  
  @impl true
  def load(%{overrides: overrides}) when is_map(overrides) do
    # Transform provider-keyed overrides into flat lists
    {providers, models} = 
      Enum.reduce(overrides, {[], []}, fn {provider_id, data}, {provs, mods} ->
        # Extract models list (special key)
        provider_models = Map.get(data, :models, [])
        
        # Everything except :models is provider-level data
        provider_data = 
          data
          |> Map.delete(:models)
          |> Map.put(:id, provider_id)
        
        # Add provider if it has fields beyond just :id
        updated_provs = if map_size(provider_data) > 1 do
          [provider_data | provs]
        else
          provs
        end
        
        # Add models with provider injected
        updated_mods = 
          provider_models
          |> Enum.map(fn model -> Map.put(model, :provider, provider_id) end)
          |> Kernel.++(mods)
        
        {updated_provs, updated_mods}
      end)
    
    {:ok, %{providers: providers, models: models}}
  end
  
  def load(%{overrides: _}), do: {:ok, %{providers: [], models: []}}
end
```

#### 4. Runtime Overrides (Tests & development)

**Module:** `LLMModels.Sources.Runtime`

**Purpose:** Per-call overrides for testing and development

**Usage:**
```elixir
# In tests
{:ok, _} = LLMModels.load(
  runtime_overrides: %{
    providers: [%{id: :sandbox, name: "Sandbox"}],
    models: [%{id: "fake-model", provider: :sandbox, capabilities: %{chat: true}}]
  }
)
```

**Example:**
```elixir
defmodule LLMModels.Sources.Runtime do
  @behaviour LLMModels.Source
  
  @impl true
  def load(%{overrides: nil}), do: {:ok, %{providers: [], models: []}}
  def load(%{overrides: overrides}) do
    {:ok, %{
      providers: Map.get(overrides, :providers, []),
      models: Map.get(overrides, :models, [])
    }}
  end
end
```

---

## Precedence (Clear & Deterministic)

### Precedence Order (Lowest → Highest)

```
Packaged Snapshot (fallback only)
  ↓
Remote Sources (left-to-right within layer)
  ↓
Local TOML
  ↓
Config Overrides
  ↓
Runtime Overrides
```

### Precedence Rules

1. **Packaged Snapshot**: Used ONLY when all other sources are empty (offline fallback)
2. **Remote Sources**: Merged left-to-right; later remotes override earlier remotes within the Remote layer
3. **Local TOML**: Overrides all remote sources
4. **Config Overrides**: Overrides local and remote
5. **Runtime Overrides**: Highest precedence (for testing/development)

### Merge Semantics

**Identity:**
- Providers: keyed by `:id` (atom)
- Models: keyed by `{provider, id}` (tuple)

**Merge behavior:**
- Scalar values: later layer wins
- Maps: deep merge, later layer keys win
- Lists: later layer replaces entirely
- Aliases: later layer replaces

**Example:**
```elixir
# Remote layer provides
%{id: "gpt-4o", provider: :openai, cost: %{input: 5.0, output: 15.0}}

# Local TOML overrides cost.input
%{id: "gpt-4o", provider: :openai, cost: %{input: 2.5}}

# Result after merge
%{id: "gpt-4o", provider: :openai, cost: %{input: 2.5, output: 15.0}}
```

---

## Configuration

### Complete Configuration Example

```elixir
# config/config.exs
config :llm_models,
  # Local authoritative data
  local_dir: "priv/llm_models",
  
  # Multiple remote sources (in precedence order)
  remote_sources: [
    "priv/llm_models/upstream/models-dev.json",
    "priv/llm_models/upstream/custom-vendor.json"
  ],
  
  # Application-level overrides
  overrides: %{
    providers: [],
    models: []
  },
  
  # Filtering (separate from sources)
  allow: :all,
  deny: %{},
  prefer: [:openai, :anthropic],
  
  # Optional
  compile_embed: false
```

### Runtime Override Example

```elixir
# In tests or IEx
{:ok, _} = LLMModels.load(
  runtime_overrides: %{
    providers: [
      %{id: :test_provider, name: "Test"}
    ],
    models: [
      %{id: "test-model", provider: :test_provider, capabilities: %{chat: true}}
    ]
  }
)
```

---

## Implementation Plan

### Phase 1: Core Infrastructure (1 day)

#### 1.1 Add Source Behavior

Create `lib/llm_models/source.ex`:

```elixir
defmodule LLMModels.Source do
  @moduledoc """
  Unified data source interface for LLM provider and model metadata.
  
  All sources return the same simple structure: providers and models.
  No filtering, no excludes - those are handled separately.
  """
  
  @type data :: %{providers: [map()], models: [map()]}
  
  @callback load(opts :: map()) :: {:ok, data()} | {:error, term()}
end
```

#### 1.2 Implement Built-in Sources

Create source modules:
- `lib/llm_models/sources/remote.ex` - Multiple JSON file loader
- `lib/llm_models/sources/local.ex` - TOML file loader (requires `{:toml, "~> 0.7"}`)
- `lib/llm_models/sources/config.ex` - Application config adapter
- `lib/llm_models/sources/runtime.ex` - Runtime override adapter

#### 1.3 Update Engine.ingest/1

**Before:**
```elixir
defp ingest(opts) do
  config = Keyword.get(opts, :config) || Config.get()
  packaged = Packaged.snapshot() || %{providers: [], models: []}
  # ... complex source assembly
end
```

**After:**
```elixir
defp ingest(opts) do
  config = Keyword.get(opts, :config) || Config.get()
  
  # Build source layers in precedence order
  sources = [
    {:remote, LLMModels.Sources.Remote, %{paths: config.remote_sources}},
    {:local, LLMModels.Sources.Local, %{dir: config.local_dir}},
    {:config, LLMModels.Sources.Config, %{overrides: config.overrides}},
    {:runtime, LLMModels.Sources.Runtime, %{overrides: opts[:runtime_overrides]}}
  ]
  
  # Load and merge all sources
  merged = load_and_merge_sources(sources)
  
  # Fallback to packaged if everything is empty
  data = if providers_empty?(merged) and models_empty?(merged) do
    Packaged.snapshot() || %{providers: [], models: []}
  else
    merged
  end
  
  {:ok, %{
    packaged: data,  # Rename to 'base' or 'merged' in next iteration
    filters: %{allow: config.allow, deny: config.deny},
    prefer: config.prefer
  }}
end

defp load_and_merge_sources(sources) do
  Enum.reduce(sources, %{providers: [], models: []}, fn {name, module, opts}, acc ->
    case module.load(opts) do
      {:ok, data} -> 
        merge_layer(acc, data)
      {:error, reason} ->
        Logger.warning("Failed to load source #{name}: #{inspect(reason)}")
        acc
    end
  end)
end
```

#### 1.4 Add Dependency

Update `mix.exs`:

```elixir
defp deps do
  [
    {:toml, "~> 0.7"},
    # ... existing deps
  ]
end
```

### Phase 2: Deprecate Old Patterns (0.5 day)

#### 2.1 Deprecate Behaviour Overrides

Mark `:overrides_module` as deprecated in Config:

```elixir
# In Config module
@deprecated "Use runtime_overrides in LLMModels.load/1 instead"
def get_overrides_from_module(module) do
  # ... existing implementation
end
```

Optionally provide compatibility wrapper:

```elixir
defmodule LLMModels.Sources.BehaviourCompat do
  @behaviour LLMModels.Source
  
  @impl true
  def load(_opts) do
    case Application.get_env(:llm_models, :overrides_module) do
      nil -> {:ok, %{providers: [], models: []}}
      mod -> {:ok, %{providers: mod.providers(), models: mod.models()}}
    end
  end
end
```

#### 2.2 Remove Excludes from Sources

Document that excludes are now handled via `deny` filters:

```elixir
# OLD (deprecated)
config :llm_models,
  overrides: %{
    exclude: %{openai: ["gpt-3.5-*"]}
  }

# NEW
config :llm_models,
  deny: %{openai: ["gpt-3.5-*"]}
```

### Phase 3: Mix Task Updates (0.5 day)

#### 3.1 Update `mix llm_models.pull`

Support multiple upstream URLs:

```bash
mix llm_models.pull --url https://models.dev/api.json --url https://custom.source/models.json
```

Save each to separate files:
- `priv/llm_models/upstream/models-dev.json`
- `priv/llm_models/upstream/custom-source.json`

Update manifest to track multiple sources.

#### 3.2 Add `mix llm_models.local.check`

Validate local TOML files:

```bash
mix llm_models.local.check
```

Output:
```
Checking local metadata...
✓ Loaded 8 providers
✓ Loaded 142 models
✓ All validations passed
```

### Phase 4: Documentation (0.5 day)

#### 4.1 Update README

Add section on data sources and precedence.

#### 4.2 Update OVERVIEW.md

Replace "Data Sources & Extensibility" section with new architecture.

#### 4.3 Add Contribution Guide

Document how to contribute model metadata via local TOML files.

### Phase 5: Testing (1 day)

#### 5.1 Unit Tests

- Test each source module independently
- Test merge semantics (scalar, map, list)
- Test precedence order

#### 5.2 Integration Tests

- Test full pipeline with all source types
- Test fallback to packaged snapshot
- Test runtime overrides in tests

---

## Developer Experience Examples

### Example 1: Common Case (Local + Remote)

**Setup:**
```elixir
config :llm_models,
  local_dir: "priv/llm_models",
  remote_sources: ["priv/llm_models/upstream/models-dev.json"]
```

**Behavior:**
- Remote provides baseline data
- Local TOML overrides/extends remote
- Simple, predictable

### Example 2: Multiple Remotes with Precedence

**Setup:**
```elixir
config :llm_models,
  remote_sources: [
    "priv/llm_models/upstream/models-dev.json",      # Base
    "priv/llm_models/upstream/vendor-specific.json"  # Overrides
  ]
```

**Behavior:**
- vendor-specific.json overrides models-dev.json within Remote layer
- Local still wins over both

### Example 3: Test-time Override

**Test:**
```elixir
test "model selection with custom model" do
  {:ok, _} = LLMModels.load(
    runtime_overrides: %{
      models: [
        %{id: "fast-model", provider: :sandbox, capabilities: %{chat: true}}
      ]
    }
  )
  
  {:ok, {provider, model_id}} = LLMModels.select(require: [chat: true])
  assert {provider, model_id} == {:sandbox, "fast-model"}
end
```

### Example 4: Environment-Specific Config

**Production:**
```elixir
# config/prod.exs
config :llm_models,
  overrides: %{
    openai: %{
      base_url: "https://production-gateway.example.com/openai"
    }
  }
```

**Staging:**
```elixir
# config/staging.exs
config :llm_models,
  overrides: %{
    openai: %{
      models: [
        %{id: "gpt-4o", cost: %{input: 0.0, output: 0.0}},  # Free in staging
        %{id: "gpt-4o-mini", cost: %{input: 0.0, output: 0.0}}
      ]
    }
  }
```

---

## Migration from Current Architecture

### What Changes

#### Before:
- Three override mechanisms: packaged, config, behaviour
- Excludes mixed into source data
- Single upstream file
- Config format: `overrides: %{providers: [...], models: [...]}`
- Precedence: Packaged < Config < Behaviour

#### After:
- Unified Source behavior
- Four source types: Remote(s), Local, Config, Runtime
- Excludes → deny filters
- Multiple upstream files
- Config format: `overrides: %{provider_atom: %{base_url: "...", models: [...]}}`
- Precedence: Remote(s) < Local < Config < Runtime

### Migration Steps

1. **Add Source infrastructure** (new code, non-breaking)
2. **Update Engine.ingest** to use sources
3. **Mark `:overrides_module` as deprecated**
4. **Move excludes to deny filters** in config
5. **Update documentation**
6. **Run full test suite**

### Breaking Changes

**Minimal - mostly additive:**
- `:overrides_module` deprecated (not removed)
- `exclude` in overrides deprecated (use `deny` instead)
- Packaged snapshot no longer merged (fallback only)

### Compatibility

Provide shims for deprecated patterns during transition period.

---

## Benefits

### Simplicity

- **One mental model**: Provider → Model
- **Clear precedence**: Easy to understand, easy to debug
- **Unified interface**: Same contract for all sources

### Flexibility

- **Multiple remotes**: Compose data from many sources
- **Local authoritative**: PR-friendly, version-controlled
- **Environment-specific**: Config overrides per environment
- **Test-friendly**: Runtime overrides for tests

### Maintainability

- **Separation of concerns**: Sources provide data; filters control policy
- **Extensible**: Easy to add new source types
- **Testable**: Each source independently testable

### Performance

- **Deterministic**: Predictable merge behavior
- **Efficient**: Single merge pass across layers
- **Cacheable**: Sources can implement caching

---

## Risks & Mitigations

### Risk: Precedence Confusion

**Mitigation:**
- Single, clear precedence table in docs
- Unit tests asserting merge order
- Logging provenance in debug mode

### Risk: Duplicate Data Across Remotes

**Mitigation:**
- Last-write-wins merge (deterministic)
- Optional provenance tracking in `extra` field

### Risk: Atom Creation from Local Files

**Mitigation:**
- Files are repository-controlled
- Reuse existing Normalize patterns
- Generate `valid_providers.ex` as today

---

## Success Criteria

- [ ] Source behavior defined and documented
- [ ] Four built-in sources implemented
- [ ] Engine.ingest refactored to use sources
- [ ] Precedence clearly documented and tested
- [ ] All existing tests pass
- [ ] Migration guide written
- [ ] OVERVIEW.md updated

---

## Effort Estimate

- **Core infrastructure**: M (1 day)
- **Deprecations**: S (0.5 day)
- **Mix tasks**: S (0.5 day)
- **Documentation**: S (0.5 day)
- **Testing**: M (1 day)

**Total**: M (2-3 days), low risk, incremental

---

## Future Enhancements

### Remote HTTP Sources

Support live HTTP fetches with TTL and caching:

```elixir
config :llm_models,
  remote_sources: [
    {:http, "https://models.dev/api.json", ttl: :timer.hours(24)},
    {:file, "priv/llm_models/upstream/custom.json"}
  ]
```

### Provenance Tracking

Track which source provided each field:

```elixir
%Model{
  id: "gpt-4o",
  extra: %{
    provenance: %{
      id: :remote,
      cost: :local,
      limits: :config
    }
  }
}
```

### Git-based Local Source

Fetch local TOML from separate repository:

```bash
mix llm_models.local.sync --repo https://github.com/org/llm-metadata
```

---

**End of Source Architecture Plan**
