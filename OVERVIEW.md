# LLMModels – Technical Architecture Overview

This document provides a technical overview of the `llm_models` library for developers integrating it or extending it. It emphasizes architectural boundaries, performance characteristics, schemas, the ETL pipeline, data sources and precedence, storage, and the public API.

## Table of Contents

- [Schema for LLM Provider & Model Data](#schema-for-llm-provider--model-data)
- [ETL Pipeline Architecture](#etl-pipeline-architecture)
- [Data Sources & Extensibility](#data-sources--extensibility)
- [Mix Tasks](#mix-tasks)
- [Storage & Performance](#storage--performance)
- [Public API](#public-api)
- [Configuration Options](#configuration-options)
- [Architectural Boundaries](#architectural-boundaries)

---

## Schema for LLM Provider & Model Data

LLMModels uses **Zoi schemas** for compile-time types and runtime validation. All records flow through these schemas during the ETL pipeline, ensuring type safety and stable defaults. Struct modules wrap schema-validated maps to provide typed structs.

### Provider Schema (`LLMModels.Schema.Provider`)

```elixir
%{
  id: atom(),           # required
  name: string(),       # optional
  base_url: string(),   # optional
  env: [string()],      # optional
  doc: string(),        # optional
  extra: map()          # optional
}
```

**Struct:** `LLMModels.Provider.new/1` and `new!/1` validate and return `%LLMModels.Provider{}`.

### Model Schema (`LLMModels.Schema.Model`)

#### Identity and Lifecycle

```elixir
%{
  id: string(),                    # required
  provider: atom(),                # required
  provider_model_id: string(),     # optional (set to id if missing by Enrich)
  name: string(),                  # optional
  family: string(),                # optional (derived by Enrich if missing)
  release_date: string(),          # optional (date normalization helper exists)
  last_updated: string(),          # optional
  knowledge: string(),             # optional
  deprecated?: boolean(),          # default: false
  aliases: [string()],             # default: []
  tags: [string()],                # optional
  extra: map()                     # optional
}
```

#### Limits (`LLMModels.Schema.Limits`)

```elixir
%{
  context: integer() >= 1,  # optional
  output: integer() >= 1    # optional
}
```

#### Cost (`LLMModels.Schema.Cost`)

Per-1M tokens unless otherwise noted:

```elixir
%{
  input: number(),       # optional
  output: number(),      # optional
  cache_read: number(),  # optional
  cache_write: number(), # optional
  training: number(),    # optional
  image: number(),       # optional
  audio: number()        # optional
}
```

#### Modalities

```elixir
%{
  modalities: %{
    input: [atom()],   # optional
    output: [atom()]   # optional
  }
}
```

**Known modalities** normalized to atoms: `:text`, `:image`, `:audio`, `:video`, `:code`, `:document`, `:embedding`

#### Capabilities (`LLMModels.Schema.Capabilities`)

Defaults applied if missing:

```elixir
%{
  chat: boolean(),                                    # default: true
  embeddings: boolean(),                              # default: false
  reasoning: %{
    enabled: boolean(),                               # default: false
    token_budget: integer() >= 0                      # optional
  },
  tools: %{
    enabled: boolean(),                               # default: false
    streaming: boolean(),                             # default: false
    strict: boolean(),                                # default: false
    parallel: boolean()                               # default: false
  },
  json: %{
    native: boolean(),                                # default: false
    schema: boolean(),                                # default: false
    strict: boolean()                                 # default: false
  },
  streaming: %{
    text: boolean(),                                  # default: true
    tool_calls: boolean()                             # default: false
  }
}
```

**Struct:** `LLMModels.Model.new/1` and `new!/1` validate and return `%LLMModels.Model{}`.

### Notes

- Zoi schemas enforce types and defaults; unknown upstream keys can be captured in the `extra` field per provider/model
- Normalization and enrichment ensure modalities, family, and provider_model_id are consistently populated

---

## ETL Pipeline Architecture

The engine orchestrates a deterministic **8-stage ETL pipeline** to build a snapshot optimized for O(1) lookups.

### Stages (`LLMModels.Engine.run/1`)

#### 1. Ingest

- Read list of sources from `Config.sources!/0` (or `:sources` option)
- Append Runtime source if `:runtime_overrides` option is passed
- Read allow/deny/prefer filters from `Config.get/0`
- Each source returns `%{providers: [...], models: [...]}`

#### 2. Normalize

- Normalize provider IDs, models, and modalities (convert known modality strings to atoms)
- Apply normalization to each layer independently

#### 3. Validate

- Validate all providers/models against Zoi schemas (`LLMModels.Validate.*`)
- Invalid entries are dropped; counts are logged per layer

#### 4. Merge

- Deep merge across all layers with **last-wins precedence**
- Source order determines precedence (first = lowest, last = highest)
- **Special list handling:**
  - `:aliases` lists are union-deduped
  - Other lists are replaced (last wins)
- Maps are deep-merged; scalars are replaced (last wins)

#### 5. Enrich

- Derive model family from ID (by removing the last hyphenated segment)
- Ensure `provider_model_id` is set to `id` if not provided
- Capabilities defaults are enforced by schema validation

#### 6. Filter

- Compile allow/deny patterns to Regex once (globs supported)
- Deny wins over allow
- Apply global filters to produce the final model set

#### 7. Index

Build indexes for fast lookup:

```elixir
%{
  providers_by_id: %{provider_atom => provider},
  models_by_key: %{{provider_atom, id} => model},
  models_by_provider: %{provider_atom => [model]},
  aliases_by_key: %{{provider_atom, alias} => canonical_id}
}
```

Engine returns the snapshot; the caller (`LLMModels.load/1`) publishes it atomically to `:persistent_term`.

#### 8. Ensure Viable

After indexing, Engine ensures at least one provider and one model exist; otherwise returns `{:error, :empty_catalog}`.

### Snapshot Shape (`Engine.build_snapshot/1`)

```elixir
%{
  providers_by_id: %{atom => map()},
  models_by_key: %{{atom, String.t()} => map()},
  aliases_by_key: %{{atom, String.t()} => String.t()},
  providers: [map()],
  models: %{atom => [map()]},
  filters: %{
    allow: :all | %{atom => [Regex.t() | String.t()]},
    deny: %{atom => [Regex.t() | String.t()]}
  },
  prefer: [atom()],
  meta: %{epoch: nil, generated_at: iso8601_string}
}
```

### Validation Logging

Dropped counts per source are logged via `Logger.warning/1` to aid diagnostics.

---

## Data Sources & Extensibility

### Unified Source Behavior

All sources implement the `LLMModels.Source` behavior with a single contract:

```elixir
@callback load(opts :: map()) :: {:ok, data()} | {:error, term()}

# Where data() is:
%{
  providers: [provider_map()],
  models: [model_map()]
}
```

**Key principles:**
- Sources return **only** providers and models data
- No filtering or excludes at source level
- Validation happens later in the Engine pipeline
- Sources should handle failures gracefully (log and skip bad data)

### Built-in Source Types

#### 1. Packaged (`LLMModels.Sources.Packaged`)

Loads the bundled snapshot that ships with the library.

**Options:** None

**Example:**
```elixir
{LLMModels.Sources.Packaged, %{}}
```

**Behavior:**
- Reads from `LLMModels.Packaged.snapshot/0`
- Provides baseline providers and models
- Config `:compile_embed` can embed at compile time for zero IO reads

#### 2. Remote (`LLMModels.Sources.Remote`)

Loads from one or more JSON files (models.dev-compatible format).

**Options:**
- `:paths` - List of file paths to load (required)
- `:file_reader` - Function for reading files (default: `File.read!/1`, for testing)

**Example:**
```elixir
{LLMModels.Sources.Remote, %{
  paths: [
    "priv/llm_models/upstream/models-dev.json",
    "priv/llm_models/upstream/vendor-specific.json"
  ]
}}
```

**Behavior:**
- Loads multiple files in order
- **Later files override earlier files** within this source layer
- Failed files are logged and skipped
- Returns `{:error, :no_data}` if no files could be loaded

#### 3. Local (`LLMModels.Sources.Local`)

Loads from TOML files in a directory structure.

**Options:**
- `:dir` - Directory path to scan (required)
- `:file_reader` - Function for reading files (for testing)
- `:dir_reader` - Function for listing directories (for testing)

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
```

**Example:**
```elixir
{LLMModels.Sources.Local, %{dir: "priv/llm_models"}}
```

**Behavior:**
- Provider file named `{provider_id}.toml` contains provider metadata
- Other `.toml` files in provider directory are models
- Parse errors are logged and files skipped

#### 4. Config (`LLMModels.Sources.Config`)

Loads overrides from application configuration (environment-specific tweaks).

**Options:**
- `:overrides` - Map with provider-keyed overrides (required)

**New format (provider-keyed):**
```elixir
{LLMModels.Sources.Config, %{
  overrides: %{
    openai: %{
      base_url: "https://staging-api.openai.com",
      models: [
        %{id: "gpt-4o", cost: %{input: 0.0, output: 0.0}},
        %{id: "gpt-4o-mini", limits: %{context: 200_000}}
      ]
    },
    anthropic: %{
      base_url: "https://proxy.example.com/anthropic"
    }
  }
}}
```

**Legacy format (still supported):**
```elixir
{LLMModels.Sources.Config, %{
  overrides: %{
    providers: [...],
    models: [...]
  }
}}
```

**Behavior:**
- Provider fields (except `:models`) are merged into provider data
- `:models` list contains model overrides for that provider
- Provider is automatically injected into each model

#### 5. Runtime (`LLMModels.Sources.Runtime`)

Per-call overrides for testing and development.

**Options:**
- `:overrides` - Map with `:providers` and `:models` keys, or `nil`

**Example:**
```elixir
# In tests
LLMModels.load(
  runtime_overrides: %{
    providers: [%{id: :sandbox, name: "Sandbox"}],
    models: [%{id: "fake-model", provider: :sandbox, capabilities: %{chat: true}}]
  }
)
```

**Behavior:**
- Automatically appended as the last source when `:runtime_overrides` is passed to `Engine.run/1` or `LLMModels.load/1`
- Highest precedence (always wins)

### Source Precedence

Sources are processed in the order returned by `Config.sources!/0`:

- **First source = lowest precedence**
- **Last source = highest precedence**  
- **Runtime source** is always appended last (if provided)

**Example configuration:**
```elixir
config :llm_models,
  sources: [
    {LLMModels.Sources.Packaged, %{}},        # 1. Base (lowest)
    {LLMModels.Sources.Remote, %{...}},       # 2. Override Packaged
    {LLMModels.Sources.Local, %{...}},        # 3. Override Remote
    {LLMModels.Sources.Config, %{...}}        # 4. Override Local
  ]
# Runtime (if passed) is appended as #5 (highest precedence)
```

**Default when :sources not configured:** `[{LLMModels.Sources.Packaged, %{}}]`

**Within Remote source:** Later files in `:paths` override earlier files.

### Merge Semantics

- **Providers:** Merged by `:id`
- **Models:** Merged by `{provider, id}` tuple
- **Deep merge:** Maps are recursively merged
- **Scalars:** Last-wins (higher precedence source wins)
- **Lists:** 
  - `:aliases` lists are **union-deduped**
  - All other lists are **replaced** (last-wins)

**Filters:** allow/deny compiled once (`Config.compile_filters/2`); deny always wins; glob support via `*` → `.*` regex.

### Custom Sources

To create a custom source, implement the `LLMModels.Source` behavior:

```elixir
defmodule MyApp.CustomSource do
  @behaviour LLMModels.Source

  @impl true
  def load(opts) do
    # Fetch data from your custom source
    providers = fetch_providers(opts)
    models = fetch_models(opts)
    
    {:ok, %{providers: providers, models: models}}
  end
end
```

Then add it to your sources configuration:

```elixir
config :llm_models,
  sources: [
    {LLMModels.Sources.Packaged, %{}},
    {MyApp.CustomSource, %{endpoint: "https://api.example.com"}}
  ]
```

### Extensibility Points

- **Multiple remote sources:** Compose data from many JSON files with clear precedence
- **Local TOML repository:** PR-friendly, version-controlled model metadata
- **Environment-specific config:** Use Config source for staging/production tweaks
- **Runtime overrides:** Perfect for testing and development
- **Custom sources:** Implement Source behavior for databases, APIs, etc.
- **Aliases:** Add aliases to model records to support canonicalization without breaking callers
- **Modalities:** Normalization recognizes a fixed, known set; new modalities require code changes to add into `Normalize`'s `@valid_modalities` set

---

## Mix Tasks

### `mix llm_models.pull`

**Purpose:** Fetch upstream provider/model metadata, regenerate snapshot, and generate a valid providers module.

**Default source:** `https://models.dev/api.json` (configurable via `--url`)

**Steps:**

1. Download upstream JSON via Req and write:
   - `priv/llm_models/upstream.json`
   - `priv/llm_models/upstream.manifest.json` (includes SHA256, size, timestamp, source_url)

2. Transform upstream into library-native shapes:
   - **providers:** drop models, keep provider metadata fields, keep string keys initially
   - **models:** flatten provider.models into a list, set model.provider to provider.id
   - atomize keys and provider IDs (unsafe conversion OK at build time)

3. Temporarily write the transformed snapshot to `priv/llm_models/snapshot.json`

4. Run `Engine.run/1` with current (normalized) config to validate, merge, enrich, filter, and index

5. Save final snapshot (pretty JSON) to `priv/llm_models/snapshot.json`:
   - providers: `snapshot.providers`
   - models: flattened values from `snapshot.models`

6. Generate `lib/llm_models/generated/valid_providers.ex`:
   - A compile-time list of provider atoms to avoid atom leaks at runtime

7. Print summary (provider count, model count)

**Example:**

```bash
mix llm_models.pull
mix llm_models.pull --url https://custom.source/models.json
```

**Notes:**

- The task subsumes "activation"; the activation process is performed within pull today
- After running pull, you can `:ok = LLMModels.reload()` in development to republish to `:persistent_term` without recompilation

---

## Storage & Performance

### Persistent Storage (`LLMModels.Store`)

- **Backing store:** `:persistent_term` under key `:llm_models_store`
- **Structure:** `%{snapshot: map(), epoch: non_neg_integer, opts: keyword()}`
- **Atomic publish:** `Store.put!/2` swaps the entire state with a new monotonic epoch (`unique_integer`)
- **Fast reads:** All public queries read from `:persistent_term` for **O(1), lock-free access**
- **Snapshot accessors:**
  - `Store.snapshot/0` returns the current snapshot map
  - `Store.epoch/0` returns the current epoch
  - `Store.last_opts/0` returns last load options (enables `LLMModels.reload/0`)
- **No ETS required; no locks on read path**

### Compile-time Embedding (`LLMModels.Packaged`)

- Option `:compile_embed` (`Application.compile_env`) controls whether `priv/llm_models/snapshot.json` is embedded at compile time
- **When embedded:**
  - Snapshot is embedded as a module attribute; **zero IO at runtime**
- **When not embedded:**
  - Snapshot is read at runtime via `File.read/1`
- Mix pull updates the on-disk snapshot consumed by runtime loads

### Indexing

`Engine.build_indexes/2` builds:

- `providers_by_id`
- `models_by_key`
- `models_by_provider`
- `aliases_by_key`

Aliases are expanded into a `%{{provider, alias} => canonical_id}` index for constant-time canonicalization.

---

## Public API

### Main Module: `LLMModels`

#### Lifecycle

```elixir
@spec load(opts :: keyword()) :: {:ok, snapshot :: map()} | {:error, term()}
# Runs the ETL pipeline and publishes to persistent_term via Store.put!/2
# Options:
#   - sources: list of {module, opts} tuples (overrides Config.sources!/0)
#   - runtime_overrides: %{providers: [...], models: [...]} (appends Runtime source)

@spec reload() :: :ok | {:error, term()}
# Re-runs load/1 using Store.last_opts/0

@spec snapshot() :: map() | nil

@spec epoch() :: non_neg_integer()
```

#### Providers

```elixir
@spec provider() :: [LLMModels.Provider.t()]
# Returns all providers as validated structs (sorted by id)

@spec provider(id :: atom()) :: {:ok, Provider.t()} | :error
```

#### Models

```elixir
@spec model() :: [LLMModels.Model.t()]
# Returns all models as validated structs

@spec models(provider :: atom()) :: [LLMModels.Model.t()]

@spec model(spec :: String.t()) :: {:ok, Model.t()} | {:error, atom()}
# spec format: "provider:model"

@spec model(provider :: atom(), id :: String.t()) :: 
  {:ok, Model.t()} | {:error, :not_found}
# Handles alias resolution automatically

@spec capabilities(spec :: {atom(), String.t()} | String.t()) :: map() | nil
```

#### Selection and Policy

```elixir
@spec select(opts :: keyword()) :: 
  {:ok, {provider :: atom(), id :: String.t()}} | {:error, :no_match}
```

**Options:**

- `require: keyword()` – capability requirements
- `forbid: keyword()` – capability forbids
- `prefer: [atom()]` – provider preference ordering for search
- `scope: :all | atom()` – restrict search to specific provider

**Supported capability keys:**

- `:chat`
- `:embeddings`
- `:reasoning` → `capabilities.reasoning.enabled`
- `:tools` → `capabilities.tools.enabled`
- `:tools_streaming` → `capabilities.tools.streaming`
- `:tools_strict` → `capabilities.tools.strict`
- `:tools_parallel` → `capabilities.tools.parallel`
- `:json_native` → `capabilities.json.native`
- `:json_schema` → `capabilities.json.schema`
- `:json_strict` → `capabilities.json.strict`
- `:streaming_text` → `capabilities.streaming.text`
- `:streaming_tool_calls` → `capabilities.streaming.tool_calls`

**Example:**

```elixir
{:ok, {provider, model_id}} = LLMModels.select(
  require: [chat: true, tools: true, json_native: true],
  prefer: [:openai, :anthropic]
)
```

#### Filtering

```elixir
@spec allowed?(spec :: {atom(), String.t()} | String.t()) :: boolean()
# Evaluates against compiled allow/deny filters in the snapshot
# Deny always wins
```

#### Spec Parsing

```elixir
@spec parse_provider(atom() | binary()) :: 
  {:ok, provider_atom :: atom()} | {:error, :unknown_provider | :bad_provider}
# Validates existence in the current catalog

@spec parse_spec(String.t()) :: 
  {:ok, {provider_atom :: atom(), model_id :: String.t()}} | {:error, term()}

@spec resolve(input, opts :: keyword()) :: 
  {:ok, {provider :: atom(), canonical_id :: String.t(), model :: map()}} | 
  {:error, term()}
# Supports spec strings, tuples, or bare model IDs with scope
# Returns the raw model map from the snapshot (not a struct)
# Resolves aliases to canonical IDs
# Reports :ambiguous for bare IDs across providers without scope
```

#### Backwards-compatibility Wrappers (deprecated)

- `list_providers/0`, `get_provider/1`
- `list_models/1`, `list_models/2`
- `get_model/2`

**Prefer:** `provider/0`, `provider/1`, `models/1`, `model/2`

### Startup

`LLMModels.Application.start/2` calls `LLMModels.load/0` at app start, so catalogs are available immediately.

---

## Configuration Options

### Application Environment

The `:llm_models` application environment supports the following keys:

```elixir
config :llm_models,
  sources: [
    {LLMModels.Sources.Packaged, %{}},
    {LLMModels.Sources.Remote, %{paths: ["priv/llm_models/upstream/models-dev.json"]}},
    {LLMModels.Sources.Local, %{dir: "priv/llm_models"}},
    {LLMModels.Sources.Config, %{overrides: %{...}}}
  ],
  compile_embed: false,
  allow: :all,  # or %{provider_atom => [pattern_strings]}
  deny: %{provider_atom => [pattern_strings]},
  prefer: [:openai, :anthropic]
```

### Configuration Keys

#### `sources` (list of `{module, opts}` tuples)

Defines the list of sources to load, in precedence order (first = lowest, last = highest).

**Default when not configured:** `[{LLMModels.Sources.Packaged, %{}}]`

**Example:**
```elixir
config :llm_models,
  sources: [
    {LLMModels.Sources.Packaged, %{}},
    {LLMModels.Sources.Remote, %{
      paths: [
        "priv/llm_models/upstream/models-dev.json",
        "priv/llm_models/upstream/custom.json"
      ]
    }},
    {LLMModels.Sources.Local, %{dir: "priv/llm_models"}},
    {LLMModels.Sources.Config, %{
      overrides: %{
        openai: %{
          base_url: "https://staging.openai.com",
          models: [
            %{id: "gpt-4o", cost: %{input: 0.0, output: 0.0}}
          ]
        }
      }
    }}
  ]
```

See [Data Sources & Extensibility](#data-sources--extensibility) for details on each source type.

#### `compile_embed` (boolean, default: `false`)

When `true`, packaged snapshot is compile-time embedded for faster runtime (zero IO).

#### `allow` (`:all` | map)

- Glob syntax supported (`*`) and compiled into Regex once
- **Semantics:**
  - If `allow` is `:all`: all models are allowed unless denied
  - If `allow` is a map and provider key is missing while the map is non-empty: that provider is blocked

#### `deny` (map)

- Deny always wins over allow
- Pattern: `%{provider_atom => [pattern_strings]}`

#### `prefer` ([atom()])

- Captured into `snapshot.meta` and `snapshot.prefer` for informational usage
- Selection uses `opts[:prefer]`; global prefer is not implicitly applied by `select/1`

### Pattern Compilation

Filters are compiled once during the Filter stage (Stage 6):

- `Config.compile_filters/2` → `%{allow: :all | %{provider => [Regex.t()]}, deny: %{provider => [Regex.t()]}}`
- `Merge.compile_pattern/1` converts globs (`*` → `.*`) to anchored regex (`^...$`)
- Exact strings are compared literally (no regex overhead)

### Type Safety

- All records validate via Zoi schemas (Provider/Model/Capabilities/Cost/Limits)
- Public API returns typed structs for providers and models (except `Spec.resolve/2` which returns raw map)
- **Provider string-to-atom conversion:**
  - Runtime parsing prefers `String.to_existing_atom` with validation against the loaded catalog (no atom leaks)
  - Mix pull generates `lib/llm_models/generated/valid_providers.ex` to pre-create atoms at build time

---

## Architectural Boundaries

```
Schema (Zoi) → ETL (Engine) → Storage (Store/persistent_term) → API (LLMModels)
```

- **Schema:** Canonical data shape and defaults
- **ETL:** Deterministic processing with clear stages and precedence rules
- **Storage:** O(1) reads via `:persistent_term`; atomic, monotonic epochs on publish
- **API:** Simple, capability-aware queries; explicit selection and filter semantics

### Performance Characteristics

- **Compile-time processing:** Optional snapshot embedding eliminates runtime disk IO
- **Runtime queries:** O(1) lock-free reads on `:persistent_term`; no dynamic schema checks
- **Filters compiled once:** Glob to regex conversion happens up front
- **Atomic swaps on reload:** Eliminate lock contention while guaranteeing consistency

### Extensibility

- Upstream source fetch via `mix llm_models.pull`
- Overrides via application config and behaviour modules
- Add aliases to support canonicalization without breaking references
- Modalities are normalized to a fixed set; expanding requires code updates (`Normalize`)

### Signals for Revisiting Design

- **Need for dynamic, per-request policy or AB testing of allow/deny** → consider layering policy on top of the catalog
- **Very large datasets or frequent reloads** → evaluate memory footprint and possibly ETS for partial indexes
- **Additional modalities or capability dimensions** → extend schemas and `Normalize`'s modality set

---

**End of Technical Overview**
