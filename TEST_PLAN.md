# LLMModels Test Plan - Pre-Release Validation

This document outlines the comprehensive testing strategy for validating the `llm_models` library before its initial public release on Hex.pm.

## Table of Contents

1. [Overview](#overview)
2. [Pre-Release Code Cleanup](#pre-release-code-cleanup)
3. [Test Categories](#test-categories)
4. [Test Execution](#test-execution)
5. [Integration Testing](#integration-testing)
6. [Performance Testing](#performance-testing)
7. [Release Checklist](#release-checklist)

---

## Overview

### Goals

- Validate all core functionality works as documented
- Ensure build-time and runtime separation is clean
- Verify performance characteristics (O(1) lookups)
- Test all public API functions
- Validate packaging and Hex release process
- Ensure documentation accuracy

### Test Environment

- Elixir versions: 1.14, 1.15, 1.16, 1.17
- OTP versions: 25, 26, 27
- Operating systems: Linux, macOS, Windows (if applicable)

---

## Pre-Release Code Cleanup

**Priority: HIGH - Must complete before testing**

Based on Oracle review, remove the following before release:

### 2. Remove Deprecated API (Pre-Release Cleanup)

In `lib/llm_models.ex`, delete:

- `list_providers/0` - Use `provider/0`
- `get_provider/1` - Use `provider/1`
- `list_models/1` - Use `models/1`
- `list_models/2` - Use `models/1` + `Enum.filter`
- `get_model/2` - Use `model/2`

### 3. Remove Internal Spec Delegates

In `lib/llm_models.ex`, remove:

- `parse_provider/1`
- `parse_spec/1`
- `resolve/2`

Keep internal usage in `capabilities/1`, just don't expose publicly.

### 4. Simplify RuntimeOverrides Validation

In `lib/llm_models/runtime_overrides.ex`:

- Remove `alias LLMModels.Generated.ValidProviders`
- Remove `require Logger`
- Simplify `validate_prefer/1`:

```elixir
defp validate_prefer(nil), do: :ok
defp validate_prefer([]), do: :ok
defp validate_prefer(prefer) when is_list(prefer) do
  if Enum.all?(prefer, &is_atom/1) do
    :ok
  else
    {:error, "prefer must be a list of atoms"}
  end
end
defp validate_prefer(_), do: {:error, "prefer must be a list of atoms"}
```

Optional: Filter prefer against current providers dynamically in `maybe_update_prefer/2`.

### 5. Remove Unused Logger Requires

- In `lib/llm_models/config.ex` - remove `require Logger`

### 6. Fix Documentation Inconsistencies

- Ensure `load/1` docs reference correct mix task name
- Update `reload/0` docs to clarify it doesn't re-run full ETL
- Remove references to Application auto-loading

---

## Test Categories

### 1. Unit Tests (Existing)

**Status:** Already comprehensive via existing test suite

Run all existing tests:

```bash
mix test
```

**Verify Coverage:**

```bash
mix test --cover
```

**Target:** >90% line coverage for all core modules

### 2. Build-Time Pipeline Tests

#### 2.1 Mix Tasks

**Test `mix llm_models.pull`:**

```bash
# Test fresh pull
mix llm_models.pull

# Verify output files
ls -la priv/llm_models/upstream/
ls -la lib/llm_models/generated/valid_providers.ex

# Test with custom URL
mix llm_models.pull --url https://models.dev/api/v1/models.json

# Test conditional requests (run twice, should use cache)
mix llm_models.pull
mix llm_models.pull  # Should skip download if ETag matches
```

**Expected Results:**
- Creates `models-dev-<hash>.json` in upstream/
- Creates manifest with ETag, Last-Modified, SHA256
- Generates valid_providers.ex with correct atoms
- Conditional requests use cached data when available

**Test `mix llm_models.build`:**

```bash
# Build from pulled data
mix llm_models.build

# Verify snapshot
cat priv/llm_models/snapshot.json | jq '.providers | length'
cat priv/llm_models/snapshot.json | jq '.models | length'

# Test with empty sources
# Edit config to sources: []
mix llm_models.build  # Should warn but succeed
```

**Expected Results:**
- Creates valid snapshot.json
- Contains providers and models arrays
- Has generated_at timestamp
- Warns if no providers/models found

**Test `mix llm_models.version`:**

```bash
# Test version determination
mix llm_models.version

# Test with multiple releases same day
git tag v2025.11.6
mix llm_models.version  # Should suggest 2025.11.6.1
```

**Expected Results:**
- Reads generated_at from snapshot
- Proposes correct date-based version
- Increments sequence for same-day releases

#### 2.2 Engine Pipeline

**Test Full Pipeline:**

```elixir
# In iex -S mix
sources = [
  {LLMModels.Sources.ModelsDev, %{}},
  {LLMModels.Sources.Local, %{dir: "priv/llm_models"}}
]

{:ok, snapshot} = LLMModels.Engine.run(sources: sources)

# Verify structure
assert Map.has_key?(snapshot, :providers_by_id)
assert Map.has_key?(snapshot, :models_by_key)
assert Map.has_key?(snapshot, :aliases_by_key)
assert Map.has_key?(snapshot, :filters)
assert Map.has_key?(snapshot, :prefer)
assert Map.has_key?(snapshot, :meta)
```

**Test Each Stage:**

- **Ingest:** Load from multiple sources
- **Normalize:** String IDs → atoms, modalities conversion
- **Validate:** Schema validation, dropped record logging
- **Merge:** Last-wins precedence, alias union
- **Filter:** Allow/deny patterns
- **Enrich:** Family derivation, defaults
- **Index:** Build lookups for O(1) access

### 3. Runtime Tests

#### 3.1 Load Process

**Test Explicit Load:**

```elixir
# Clear any existing data
LLMModels.Store.clear!()

# Load packaged snapshot
{:ok, snapshot} = LLMModels.load()

# Verify persistent_term storage
assert LLMModels.Store.snapshot() != nil
assert LLMModels.Store.epoch() > 0
```

**Test Load with Runtime Overrides:**

```elixir
# Load with filters
{:ok, _} = LLMModels.load(
  runtime_overrides: %{
    filters: %{
      allow: %{openai: ["gpt-4*"]},
      deny: %{}
    }
  }
)

# Verify only gpt-4 models allowed
assert LLMModels.allowed?({:openai, "gpt-4o"})
refute LLMModels.allowed?({:openai, "gpt-3.5-turbo"})
```

**Test Load with Preferences:**

```elixir
{:ok, _} = LLMModels.load(
  runtime_overrides: %{
    prefer: [:anthropic, :openai]
  }
)

# Verify prefer order affects selection
{:ok, {provider, _}} = LLMModels.select(require: [chat: true])
assert provider == :anthropic
```

**Test Reload:**

```elixir
# Load with options
LLMModels.load(runtime_overrides: %{prefer: [:openai]})

# Reload with last options
:ok = LLMModels.reload()

# Verify same options applied
snapshot = LLMModels.Store.snapshot()
assert snapshot.prefer == [:openai]
```

#### 3.2 Public API

**Provider Functions:**

```elixir
# Get all providers
providers = LLMModels.provider()
assert is_list(providers)
assert length(providers) > 0

# Get specific provider
{:ok, provider} = LLMModels.provider(:openai)
assert provider.id == :openai
assert is_binary(provider.name)

# Non-existent provider
assert LLMModels.provider(:nonexistent) == :error
```

**Model Functions:**

```elixir
# Get all models
models = LLMModels.model()
assert is_list(models)
assert length(models) > 0

# Get models by provider
models = LLMModels.models(:openai)
assert Enum.all?(models, &(&1.provider == :openai))

# Get specific model
{:ok, model} = LLMModels.model(:openai, "gpt-4o-mini")
assert model.id == "gpt-4o-mini"

# Parse spec string
{:ok, model} = LLMModels.model("openai:gpt-4o-mini")
assert model.id == "gpt-4o-mini"

# Test alias resolution
{:ok, model} = LLMModels.model(:openai, "gpt-4-mini")  # alias
assert model.id == "gpt-4o-mini"  # canonical

# Non-existent model
assert LLMModels.model(:openai, "nonexistent") == {:error, :not_found}
```

**Selection:**

```elixir
# Select with requirements
{:ok, {provider, model_id}} = LLMModels.select(
  require: [chat: true, tools: true]
)
assert is_atom(provider)
assert is_binary(model_id)

# Verify capabilities
{:ok, model} = LLMModels.model(provider, model_id)
assert model.capabilities.chat == true
assert model.capabilities.tools.enabled == true

# Select with preferences
{:ok, {provider, _}} = LLMModels.select(
  require: [chat: true],
  prefer: [:openai, :anthropic]
)
assert provider in [:openai, :anthropic]

# Select with scope
{:ok, {provider, _}} = LLMModels.select(
  require: [chat: true],
  scope: :anthropic
)
assert provider == :anthropic

# No match scenario
result = LLMModels.select(
  require: [chat: true, some_nonexistent_capability: true]
)
assert result == {:error, :no_match}
```

**Filtering:**

```elixir
# Load with deny filter
LLMModels.load(
  runtime_overrides: %{
    filters: %{
      allow: :all,
      deny: %{openai: ["gpt-3.5*"]}
    }
  }
)

# Test allowed?
assert LLMModels.allowed?({:openai, "gpt-4o"})
refute LLMModels.allowed?({:openai, "gpt-3.5-turbo"})

# Test with spec string
assert LLMModels.allowed?("openai:gpt-4o")
refute LLMModels.allowed?("openai:gpt-3.5-turbo")
```

**Capabilities:**

```elixir
# Get capabilities by tuple
caps = LLMModels.capabilities({:openai, "gpt-4o-mini"})
assert is_map(caps)
assert Map.has_key?(caps, :chat)
assert Map.has_key?(caps, :tools)

# Get capabilities by spec string
caps = LLMModels.capabilities("openai:gpt-4o-mini")
assert is_map(caps)

# Non-existent model
assert LLMModels.capabilities({:openai, "nonexistent"}) == nil
```

### 4. Schema Validation Tests

**Test Provider Schema:**

```elixir
# Valid provider
provider = %{
  id: :test,
  name: "Test Provider",
  env: ["TEST_API_KEY"]
}

{:ok, validated} = LLMModels.Schema.Provider.validate(provider)
assert validated.id == :test

# Invalid provider
invalid = %{id: "not-atom", name: "Test"}
{:error, _} = LLMModels.Schema.Provider.validate(invalid)
```

**Test Model Schema:**

```elixir
# Valid model
model = %{
  id: "test-model",
  provider: :test,
  name: "Test Model",
  capabilities: %{
    chat: true,
    tools: %{enabled: true}
  }
}

{:ok, validated} = LLMModels.Schema.Model.validate(model)

# Invalid model
invalid = %{id: 123, provider: :test}
{:error, _} = LLMModels.Schema.Model.validate(invalid)
```

### 5. Source Tests

**ModelsDev Source:**

```elixir
# Load from models.dev
{:ok, data} = LLMModels.Sources.ModelsDev.load(%{})
assert is_map(data)
assert Map.keys(data) |> length() > 0

# Verify structure
[{provider_id, provider_data}] = Enum.take(data, 1)
assert is_atom(provider_id)
assert Map.has_key?(provider_data, :models)
```

**Local Source:**

```elixir
# Load from local TOML
{:ok, data} = LLMModels.Sources.Local.load(%{dir: "priv/llm_models"})
assert is_map(data)
```

**Config Source:**

```elixir
# Load from config overrides
overrides = %{
  custom: %{
    id: :custom,
    name: "Custom",
    models: [
      %{id: "custom-1", provider: :custom, name: "Custom Model"}
    ]
  }
}

{:ok, data} = LLMModels.Sources.Config.load(%{overrides: overrides})
assert Map.has_key?(data, :custom)
```

### 6. RuntimeOverrides Tests

**Filter Updates:**

```elixir
# Load initial snapshot
{:ok, _} = LLMModels.load()
snapshot = LLMModels.Store.snapshot()

# Apply runtime filter override
{:ok, updated} = LLMModels.RuntimeOverrides.apply(
  snapshot,
  %{filters: %{allow: %{openai: ["gpt-4*"]}, deny: %{}}}
)

# Verify filters updated
assert updated.filters.allow == %{openai: [~r/^gpt-4.*$/]}

# Verify models filtered
openai_models = Map.get(updated.models, :openai, [])
assert Enum.all?(openai_models, &String.starts_with?(&1.id, "gpt-4"))
```

**Preference Updates:**

```elixir
snapshot = LLMModels.Store.snapshot()

{:ok, updated} = LLMModels.RuntimeOverrides.apply(
  snapshot,
  %{prefer: [:anthropic, :openai]}
)

assert updated.prefer == [:anthropic, :openai]
```

**Validation:**

```elixir
snapshot = LLMModels.Store.snapshot()

# Invalid filter structure
{:error, _} = LLMModels.RuntimeOverrides.apply(
  snapshot,
  %{filters: "invalid"}
)

# Invalid prefer (not atoms)
{:error, _} = LLMModels.RuntimeOverrides.apply(
  snapshot,
  %{prefer: ["string", "not", "atom"]}
)
```

---

## Test Execution

### Automated Test Suite

```bash
# Run all tests
mix test

# Run with coverage
mix test --cover

# Run specific test file
mix test test/llm_models_test.exs

# Run specific test line
mix test test/llm_models_test.exs:42

# Run with verbose output
mix test --trace
```

### Quality Checks

```bash
# Format check
mix format --check-formatted

# Dialyzer (static analysis)
mix dialyzer

# Credo (code quality)
mix credo --strict

# All quality checks
mix quality
```

### Continuous Integration

Ensure CI runs on:

- Multiple Elixir versions (1.14, 1.15, 1.16, 1.17)
- Multiple OTP versions (25, 26, 27)
- All quality checks pass
- Test coverage >90%

---

## Integration Testing

### 1. Fresh Application Test

Create a new Phoenix/Elixir app and test integration:

```bash
# Create new app
mix new test_app --sup
cd test_app

# Add llm_models dependency
# In mix.exs:
{:llm_models, "~> 2025.11.6"}

mix deps.get
```

**Test in application:**

```elixir
# In lib/test_app/application.ex
defmodule TestApp.Application do
  use Application

  def start(_type, _args) do
    # Explicitly load on app start
    case LLMModels.load() do
      {:ok, _snapshot} ->
        IO.puts("LLMModels loaded successfully")
      {:error, reason} ->
        IO.puts("Failed to load: #{inspect(reason)}")
    end

    children = []
    opts = [strategy: :one_for_one, name: TestApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

**Test queries:**

```elixir
# In iex -S mix
{:ok, model} = LLMModels.model("openai:gpt-4o-mini")
IO.inspect(model.capabilities)

{:ok, {provider, model_id}} = LLMModels.select(require: [chat: true, tools: true])
IO.puts("Selected: #{provider}:#{model_id}")
```

### 2. Packaging Test

```bash
# Build package
mix hex.build

# Inspect tarball
tar -tzf llm_models-*.tar | grep -E "(lib/|priv/)"

# Verify snapshot included
tar -xzf llm_models-*.tar -O priv/llm_models/snapshot.json | jq '.'
```

**Verify package contents:**
- All `lib/` files
- `priv/llm_models/snapshot.json`
- Generated ValidProviders
- No build artifacts
- No test files

### 3. Documentation Test

```bash
# Generate docs
mix docs

# Open in browser
open doc/index.html
```

**Verify:**
- README renders correctly
- All public functions documented
- Examples work
- Links are valid
- Changelog included

---

## Performance Testing

### 1. Load Time Benchmarking

```elixir
# Benchmark load/1
{time_us, {:ok, _}} = :timer.tc(fn -> LLMModels.load() end)
IO.puts("Load time: #{time_us / 1000}ms")

# Target: <25ms for runtime load
assert time_us < 25_000
```

### 2. Query Performance

```elixir
# Benchmark provider/1 (O(1) lookup)
{time_us, _} = :timer.tc(fn ->
  for _ <- 1..10_000, do: LLMModels.provider(:openai)
end)
IO.puts("10k provider lookups: #{time_us / 1000}ms")
# Target: <1μs per lookup

# Benchmark model/2 (O(1) lookup)
{time_us, _} = :timer.tc(fn ->
  for _ <- 1..10_000, do: LLMModels.model(:openai, "gpt-4o-mini")
end)
IO.puts("10k model lookups: #{time_us / 1000}ms")
# Target: <1μs per lookup

# Benchmark select/1
{time_us, _} = :timer.tc(fn ->
  for _ <- 1..1_000, do: LLMModels.select(require: [chat: true])
end)
IO.puts("1k select calls: #{time_us / 1000}ms")
# Target: <10μs per select (short-circuits on first match)
```

### 3. Memory Usage

```elixir
# Before load
:erlang.memory(:total) |> div(1024 * 1024)  # MB

# Load
{:ok, _} = LLMModels.load()

# After load
:erlang.memory(:total) |> div(1024 * 1024)  # MB

# Snapshot size
snapshot = LLMModels.Store.snapshot()
:erts_debug.size(snapshot) |> IO.inspect(label: "Snapshot size (words)")

# Target: <400KB in-memory
```

### 4. Concurrent Access

```elixir
# Load once
{:ok, _} = LLMModels.load()

# Spawn many concurrent readers
tasks = for _ <- 1..100 do
  Task.async(fn ->
    for _ <- 1..100 do
      LLMModels.model(:openai, "gpt-4o-mini")
      LLMModels.provider(:anthropic)
      LLMModels.select(require: [chat: true])
    end
  end)
end

# Wait for all
Task.await_many(tasks, 30_000)

# Verify no crashes, consistent results
```

---

## Release Checklist

### Pre-Release

- [ ] Complete code cleanup (remove Application, deprecated functions, etc.)
- [ ] All tests pass (`mix test`)
- [ ] Quality checks pass (`mix quality`)
- [ ] Coverage >90% (`mix test --cover`)
- [ ] Dialyzer passes (`mix dialyzer`)
- [ ] Documentation complete (`mix docs`)
- [ ] CHANGELOG.md updated
- [ ] README.md accurate
- [ ] AGENTS.md updated with final commands

### Build-Time Validation

- [ ] `mix llm_models.pull` succeeds
- [ ] `mix llm_models.build` succeeds
- [ ] `priv/llm_models/snapshot.json` valid
- [ ] `lib/llm_models/generated/valid_providers.ex` generated
- [ ] Snapshot contains providers and models

### Runtime Validation

- [ ] `LLMModels.load()` succeeds in fresh iex
- [ ] All public API functions work
- [ ] Alias resolution works
- [ ] Filtering works (allow/deny)
- [ ] Selection works (require/forbid/prefer)
- [ ] RuntimeOverrides work
- [ ] No warnings on load
- [ ] No atom leaks (all provider IDs pre-generated)

### Package Validation

- [ ] `mix hex.build` succeeds
- [ ] Tarball contains all necessary files
- [ ] Snapshot included in package
- [ ] No build artifacts included
- [ ] Correct version in mix.exs
- [ ] LICENSE file included
- [ ] Documentation builds correctly

### Integration Testing

- [ ] Fresh app can use as dependency
- [ ] Works in supervised application
- [ ] No conflicts with common dependencies
- [ ] README examples work in fresh app

### Performance Validation

- [ ] Load time <25ms
- [ ] Provider lookup <1μs
- [ ] Model lookup <1μs
- [ ] Select <10μs
- [ ] Memory usage <400KB
- [ ] Concurrent access stable

### Documentation Validation

- [ ] Hexdocs generated correctly
- [ ] All public functions documented
- [ ] Examples tested and working
- [ ] README comprehensive
- [ ] CHANGELOG accurate
- [ ] Links valid

### Final Checks

- [ ] Git tag created (`v2025.11.6`)
- [ ] Tag pushed to GitHub
- [ ] CI passes on tag
- [ ] Ready for `mix hex.publish`

---

## Post-Release Validation

After publishing to Hex:

```bash
# In fresh directory
mix new validate_release --sup
cd validate_release

# Add published dependency
# In mix.exs: {:llm_models, "~> 2025.11.6"}

mix deps.get
iex -S mix

# Test basic functionality
{:ok, _} = LLMModels.load()
{:ok, model} = LLMModels.model("openai:gpt-4o-mini")
IO.inspect(model.capabilities)
```

### Smoke Tests

- [ ] Package downloads from Hex
- [ ] Deps compile without warnings
- [ ] Load succeeds
- [ ] Basic queries work
- [ ] Hexdocs live and correct
- [ ] GitHub release created

---

## Notes

### Test Data

Ensure test fixtures include:

- Multiple providers (OpenAI, Anthropic, etc.)
- Models with various capabilities
- Models with aliases
- Edge cases (missing fields, invalid data)
- Filter patterns (glob, regex)

### Common Issues

**Issue:** ValidProviders not found
**Fix:** Run `mix llm_models.pull` to generate

**Issue:** No snapshot found
**Fix:** Run `mix llm_models.build` to create

**Issue:** Application startup error
**Fix:** Call `LLMModels.load()` explicitly after cleanup

**Issue:** Atom leaks in tests
**Fix:** Use pre-generated atoms from ValidProviders in production

### Testing Philosophy

- **Build-time:** Tests should validate ETL pipeline, mix tasks, snapshot generation
- **Runtime:** Tests should validate O(1) lookups, filtering, selection, minimal overhead
- **Integration:** Tests should validate real-world usage patterns
- **Performance:** Tests should validate <25ms load, <1μs lookups, <400KB memory

---

## Conclusion

This test plan ensures comprehensive validation of the `llm_models` library before public release. Execute all sections in order, checking off items as completed. Address any failures before proceeding to release.

**Success Criteria:**
- All automated tests pass
- All quality checks pass
- All manual integration tests successful
- Performance targets met
- Documentation complete and accurate
- Package builds and installs correctly
