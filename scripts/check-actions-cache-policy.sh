#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Firelock, LLC

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow_root="${1:-${root}/.github/workflows}"
action_root="${2:-$(dirname "${workflow_root}")/actions}"

ruby - "${workflow_root}" "${action_root}" <<'RUBY'
require "psych"
require "set"
require "yaml"

workflow_root = File.expand_path(ARGV.fetch(0))
action_root = File.expand_path(ARGV.fetch(1))
abort("FAIL: workflow directory does not exist: #{workflow_root}") unless Dir.exist?(workflow_root)

expected_counts = {
  "cache-seed.yml" => [1, 1],
  "ci.yml" => [1, 0],
  "kin-db-compat.yml" => [1, 0],
}.freeze
allowed_paths = ["~/.cargo/registry", "~/.cargo/git"].freeze
restore_inputs = ["key", "path", "restore-keys"].freeze
save_inputs = ["key", "path"].freeze
restore_key = "${{ runner.os }}-cargo-sources-v1"
restore_prefix = "${{ runner.os }}-cargo-sources-"
save_key = "${{ steps.cargo-sources.outputs.cache-primary-key }}"
save_condition = (
  "github.ref == 'refs/heads/main' && " \
  "steps.cargo-sources.outputs.cache-hit != 'true' && " \
  "steps.fetch-dependencies.outcome == 'success'"
).freeze
policy_commands = [
  "./scripts/check-actions-cache-policy.sh",
  "./scripts/test-actions-cache-policy.sh",
].freeze
approved_step_actions = Set.new([
  "./.github/actions/rust-toolchain",
  "./kin-model/.github/actions/rust-toolchain",
  "EmbarkStudios/cargo-deny-action@v2",
  "actions/cache/restore@v4",
  "actions/cache/save@v4",
  "actions/checkout@v6",
  # These setup actions are not currently used. They are approved only with
  # the explicit cache opt-outs enforced below, so adding them cannot create a
  # default-on Actions cache.
  "actions/setup-go@v6",
  "actions/setup-node@v6",
  "softprops/action-gh-release@v2",
]).freeze
approved_reusable_workflows = Set.new([
  "firelock-ai/kin-actions/.github/workflows/cargo-dependency-wave.yml@v0.1.32",
  "firelock-ai/kin-actions/.github/workflows/cargo-registry-release.yml@v0.1.32",
  "firelock-ai/kin-actions/.github/workflows/cargo-release-recovery.yml@v0.1.32",
  "firelock-ai/kin-actions/.github/workflows/merge-queue-ejection-notice.yml@v0.1.31",
]).freeze

errors = []
counts = {}
policy_invocations = 0
workflows = Dir[File.join(workflow_root, "*.{yml,yaml}")].sort
abort("FAIL: no workflow files found under #{workflow_root}") if workflows.empty?

def inspect_yaml_node(node, file_name, errors)
  case node
  when Psych::Nodes::Alias
    errors << "#{file_name}:#{node.start_line + 1}: YAML aliases are forbidden in workflow policy"
  when Psych::Nodes::Mapping
    seen = {}
    node.children.each_slice(2) do |key_node, value_node|
      unless key_node.is_a?(Psych::Nodes::Scalar)
        errors << "#{file_name}:#{key_node.start_line + 1}: complex YAML mapping keys are forbidden"
        inspect_yaml_node(value_node, file_name, errors)
        next
      end

      key = key_node.value
      if seen.key?(key)
        errors << (
          "#{file_name}:#{key_node.start_line + 1}: duplicate YAML mapping key #{key.inspect}; " \
          "first declared at line #{seen.fetch(key)}"
        )
      else
        seen[key] = key_node.start_line + 1
      end
      inspect_yaml_node(value_node, file_name, errors)
    end
  else
    Array(node.children).each { |child| inspect_yaml_node(child, file_name, errors) }
  end
end

def lines(value)
  return nil unless value.is_a?(String)

  value.lines.map(&:strip).reject(&:empty?)
end

def each_mapping(value, &block)
  case value
  when Hash
    yield(value)
    value.each_value { |child| each_mapping(child, &block) }
  when Array
    value.each { |child| each_mapping(child, &block) }
  end
end

def hidden_cache_action?(action)
  normalized = action.downcase
  return false if normalized.start_with?("actions/cache")

  normalized.include?("rust-cache") ||
    normalized.include?("sccache") ||
    normalized.include?("cache-cargo") ||
    normalized.match?(%r{(^|/)cache([/@-]|$)})
end

def implicit_cache_opt_out_input(action)
  case action.downcase.split("@", 2).first
  when "actions/setup-node"
    "package-manager-cache"
  when "actions/setup-go"
    "cache"
  end
end

def implicit_cache_opted_out?(action, inputs)
  input = implicit_cache_opt_out_input(action)
  return true unless input
  return false unless inputs.is_a?(Hash)

  value = inputs[input]
  value == false || value == "false"
end

def cache_named_inputs(mapping)
  return [] unless mapping.is_a?(Hash)

  mapping.keys.map(&:to_s).select { |key| key.downcase.include?("cache") }
end

def gha_cache_text?(value)
  return false unless value.is_a?(String)

  normalized = value.downcase
  normalized.include?("type=gha") ||
    normalized.include?("actions_cache_url") ||
    normalized.include?("actions_results_url")
end

workflows.each do |workflow|
  file_name = File.basename(workflow)
  content = File.read(workflow, encoding: "UTF-8")

  begin
    syntax_tree = Psych.parse_stream(content, filename: workflow)
    inspect_yaml_node(syntax_tree, file_name, errors)
    document = YAML.safe_load(
      content,
      permitted_classes: [],
      permitted_symbols: [],
      aliases: false,
      filename: workflow,
    )
  rescue Psych::Exception => error
    errors << "#{file_name}: YAML parse failed: #{error.message}"
    counts[file_name] = [0, 0]
    next
  end

  jobs = document.is_a?(Hash) ? document["jobs"] : nil
  unless jobs.is_a?(Hash)
    errors << "#{file_name}: jobs must be a YAML mapping"
    counts[file_name] = [0, 0]
    next
  end

  restore_count = 0
  save_count = 0

  jobs.each do |job_name, job|
    next unless job.is_a?(Hash)

    reusable = job["uses"]
    if reusable.is_a?(String) && !approved_reusable_workflows.include?(reusable)
      errors << (
        "#{file_name}: job #{job_name.inspect}: unapproved reusable workflow identity #{reusable}; " \
        "audit its cache behavior before allowlisting it"
      )
    end
    if reusable.is_a?(String) && hidden_cache_action?(reusable)
      errors << "#{file_name}: job #{job_name.inspect}: unaudited cache-capable reusable workflow #{reusable}"
    end
    job_cache_inputs = cache_named_inputs(job["with"])
    unless job_cache_inputs.empty?
      errors << (
        "#{file_name}: job #{job_name.inspect}: unaudited reusable-workflow cache input(s) " \
        "#{job_cache_inputs.inspect}"
      )
    end

    steps = job["steps"]
    next if steps.nil?
    unless steps.is_a?(Array)
      errors << "#{file_name}: job #{job_name.inspect} steps must be a YAML sequence"
      next
    end

    steps.each_with_index do |step, index|
      next unless step.is_a?(Hash)

      location = "#{file_name}: job #{job_name.inspect} step #{index + 1}"
      run_lines = lines(step["run"])
      invokes_policy = step["name"] == "Check Actions cache policy" ||
        Array(run_lines).any? { |line| policy_commands.include?(line) }
      if invokes_policy
        policy_invocations += 1
        unless file_name == "ci.yml" && job_name == "check"
          errors << "#{location}: Actions cache policy must be enforced by ci.yml job check"
        end
        unless step["name"] == "Check Actions cache policy" && run_lines == policy_commands
          errors << "#{location}: Actions cache policy commands must match the exact required pair"
        end
        if step.key?("if") || step.key?("continue-on-error")
          errors << "#{location}: Actions cache policy enforcement must be unconditional and fail closed"
        end
      end

      if gha_cache_text?(step["run"])
        errors << "#{location}: unaudited GitHub Actions cache backend in run step"
      end

      action = step["uses"]
      next unless action.is_a?(String)

      unless approved_step_actions.include?(action)
        errors << (
          "#{location}: unapproved action identity #{action}; audit its default and optional " \
          "cache behavior before allowlisting it"
        )
      end

      if hidden_cache_action?(action)
        errors << "#{location}: unaudited cache-capable action #{action}"
        next
      end

      action_inputs = step["with"]
      cache_inputs = cache_named_inputs(action_inputs)
      action_values = action_inputs.is_a?(Hash) ? action_inputs.values : []
      unless action.downcase.start_with?("actions/cache")
        opt_out_input = implicit_cache_opt_out_input(action)
        implicit_cache_disabled = implicit_cache_opted_out?(action, action_inputs)
        unless implicit_cache_disabled
          errors << (
            "#{location}: #{action.downcase.split("@", 2).first} must explicitly set " \
            "#{opt_out_input}: false"
          )
        end
        unsafe_cache_inputs = cache_inputs.reject do |input|
          input == opt_out_input && implicit_cache_disabled
        end
        unless unsafe_cache_inputs.empty?
          errors << "#{location}: unaudited cache input(s) #{unsafe_cache_inputs.inspect} on #{action}"
        end
        if action_values.any? { |value| gha_cache_text?(value) }
          errors << "#{location}: unaudited GitHub Actions cache backend configured on #{action}"
        end
        next
      end

      cache_paths = lines(step.dig("with", "path")) if step["with"].is_a?(Hash)
      key = step.dig("with", "key") if step["with"].is_a?(Hash)
      input_names = step["with"].is_a?(Hash) ? step["with"].keys.map(&:to_s).sort : []
      body = step.inspect

      case action
      when "actions/cache/restore@v4"
        restore_count += 1
        if input_names != restore_inputs
          errors << (
            "#{location}: restore inputs must be exactly #{restore_inputs.inspect}; " \
            "behavior-changing cache inputs are forbidden"
          )
        end
        errors << "#{location}: restore id must be cargo-sources" unless step["id"] == "cargo-sources"
        errors << "#{location}: cache restore must run on every workflow ref" if step.key?("if")
        if steps.take(index).any? { |prior| prior.is_a?(Hash) && prior.key?("run") }
          errors << "#{location}: cache restore must precede every run step"
        end
        errors << "#{location}: restore key must be the bounded epoch #{restore_key}" if key != restore_key
        restore_keys = lines(step.dig("with", "restore-keys")) if step["with"].is_a?(Hash)
        if restore_keys != [restore_prefix]
          errors << "#{location}: restore prefix must be #{restore_prefix}"
        end
      when "actions/cache/save@v4"
        save_count += 1
        if input_names != save_inputs
          errors << (
            "#{location}: save inputs must be exactly #{save_inputs.inspect}; " \
            "behavior-changing cache inputs are forbidden"
          )
        end
        if step["if"] != save_condition
          errors << "#{location}: cache save must require main, a cache miss, and a successful fetch"
        end
        if key != save_key
          errors << "#{location}: save key must come from the restore primary key"
        end
        if index != steps.length - 1
          errors << "#{location}: cache save must be the last declared job step"
        end
        unless steps.take(index).any? do |prior|
                 prior.is_a?(Hash) && prior["id"] == "cargo-sources" &&
                   prior["uses"] == "actions/cache/restore@v4"
               end
          errors << "#{location}: cache save must follow cargo-sources restore in the same job"
        end
        fetch = steps.take(index).find do |prior|
          prior.is_a?(Hash) && prior["id"] == "fetch-dependencies"
        end
        unless fetch && lines(fetch["run"]) == ["cargo fetch"] && fetch["continue-on-error"] == true
          errors << (
            "#{location}: cache save must follow the non-gating fetch-dependencies cargo fetch step"
          )
        end
      else
        errors << "#{location}: use actions/cache/restore@v4 or actions/cache/save@v4, not #{action}"
      end

      if body.include?("hashFiles(") || body.include?("github.sha") || body.include?("github.run_id")
        errors << "#{location}: cache keys must not expand per dependency hash, SHA, or run"
      end
      if cache_paths != allowed_paths
        errors << (
          "#{location}: cache paths must be exactly #{allowed_paths.inspect}; " \
          "target output is forbidden"
        )
      end
      if cache_paths&.any? { |path| path.split("/").any? { |part| part.casecmp?("target") } }
        errors << "#{location}: target output is forbidden in Actions caches"
      end
    end
  end

  counts[file_name] = [restore_count, save_count]
end

Dir[File.join(action_root, "**", "*.{yml,yaml}")].sort.each do |action_file|
  relative_name = action_file.delete_prefix("#{action_root}/")
  content = File.read(action_file, encoding: "UTF-8")

  begin
    syntax_tree = Psych.parse_stream(content, filename: action_file)
    inspect_yaml_node(syntax_tree, relative_name, errors)
    document = YAML.safe_load(
      content,
      permitted_classes: [],
      permitted_symbols: [],
      aliases: false,
      filename: action_file,
    )
  rescue Psych::Exception => error
    errors << "#{relative_name}: YAML parse failed: #{error.message}"
    next
  end

  each_mapping(document) do |mapping|
    action = mapping["uses"]
    if action.is_a?(String)
      unless approved_step_actions.include?(action)
        errors << (
          "#{relative_name}: unapproved composite action identity #{action}; audit its default " \
          "and optional cache behavior before allowlisting it"
        )
      end
      cache_inputs = cache_named_inputs(mapping["with"])
      cache_values = mapping["with"].is_a?(Hash) ? mapping["with"].values : []
      opt_out_input = implicit_cache_opt_out_input(action)
      implicit_cache_disabled = implicit_cache_opted_out?(action, mapping["with"])
      unsafe_cache_inputs = cache_inputs.reject do |input|
        input == opt_out_input && implicit_cache_disabled
      end
      if action.downcase.start_with?("actions/cache") || hidden_cache_action?(action) ||
          !implicit_cache_disabled || !unsafe_cache_inputs.empty? ||
          cache_values.any? { |value| gha_cache_text?(value) }
        errors << (
          "#{relative_name}: repo-local composite actions must not invoke or configure " \
          "cache-capable action #{action}; declare bounded caches in an audited workflow job"
        )
      end
    end
    if gha_cache_text?(mapping["run"])
      errors << (
        "#{relative_name}: repo-local composite actions must not configure a GitHub Actions " \
        "cache backend in a run step"
      )
    end
  end
end

if policy_invocations != 1
  errors << (
    "ci.yml: expected exactly one unconditional fail-closed Actions cache policy invocation; " \
    "found #{policy_invocations}"
  )
end

expected_counts.each do |workflow_name, expected|
  actual = counts.fetch(workflow_name, [0, 0])
  next if actual == expected

  errors << (
    "#{workflow_name}: expected #{expected[0]} restore and #{expected[1]} save steps; " \
    "found #{actual[0]} restore and #{actual[1]} save steps"
  )
end

counts.each do |workflow_name, actual|
  next if expected_counts.key?(workflow_name) || actual == [0, 0]

  errors << "#{workflow_name}: unexpected cache action; add it to the bounded policy deliberately"
end

unless errors.empty?
  warn("FAIL: GitHub Actions cache policy is not bounded:")
  errors.each { |error| warn("  - #{error}") }
  exit(1)
end

puts(
  "OK: repo-local Actions caches are source-only, epoch-bounded, and save only from main " \
  "(3 restores, 1 save)."
)
RUBY
