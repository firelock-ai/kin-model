// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Firelock, LLC

// This test is independent of the shell policy step it protects. The existing
// `cargo test` CI authority still runs it if someone accidentally deletes or
// softens that earlier step.
const CI_WORKFLOW: &str = include_str!("../.github/workflows/ci.yml");
const STEP_NAME: &str = "      - name: Check Actions cache policy";
const REQUIRED_STEP: &str = r#"      - name: Check Actions cache policy
        run: |
          ./scripts/check-actions-cache-policy.sh
          ./scripts/test-actions-cache-policy.sh"#;

fn policy_step(workflow: &str) -> &str {
    assert_eq!(
        workflow.matches(STEP_NAME).count(),
        1,
        "CI must declare exactly one Actions cache policy step"
    );
    let start = workflow.find(STEP_NAME).expect("policy step counted above");
    let tail = &workflow[start..];
    let end = tail.find("\n      - ").unwrap_or(tail.len());
    tail[..end].trim_end()
}

#[test]
fn ci_runs_the_actions_cache_policy_as_a_required_step() {
    assert_eq!(
        policy_step(CI_WORKFLOW),
        REQUIRED_STEP,
        "CI must run the exact Actions cache checker and falsifier suite once, without an if condition or continue-on-error"
    );
}

#[test]
fn trailing_step_controls_cannot_hide_after_the_run_block() {
    let softened =
        format!("{REQUIRED_STEP}\n        continue-on-error: true\n\n      - name: Next");
    assert_ne!(policy_step(&softened), REQUIRED_STEP);
}
