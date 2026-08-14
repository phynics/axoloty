#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -euo pipefail

: "${REPOSITORY:?REPOSITORY is required}"
: "${RUN_URL:?RUN_URL is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY is required}"

branch="automation/dev-image-lock"
body="Automated lock refresh for the development image published by [run]($RUN_URL)."

if ! pr_exists=$(gh pr list --repo "$REPOSITORY" --head "$branch" --state open \
    --json number --jq 'length > 0'); then
    echo "failed to inspect existing image lock pull requests" >&2
    exit 1
fi

if [[ "$pr_exists" == "true" ]]; then
    gh pr edit --repo "$REPOSITORY" "$branch" --body "$body"
    exit 0
fi
if [[ "$pr_exists" != "false" ]]; then
    echo "unexpected image lock pull request query result: $pr_exists" >&2
    exit 1
fi

pr_error="$RUNNER_TEMP/image-lock-pr-error"
if gh pr create --repo "$REPOSITORY" --base main --head "$branch" \
    --title "build(dev-image): refresh image lock" --body "$body" 2>"$pr_error"; then
    exit 0
fi

expected_denial="pull request create failed: GraphQL: GitHub Actions is not permitted to create or approve pull requests (createPullRequest)"
actual_error=$(cat "$pr_error")
if [[ "$actual_error" != "$expected_denial" ]]; then
    printf '%s\n' "$actual_error" >&2
    exit 1
fi

compare_url="https://github.com/$REPOSITORY/compare/main...automation/dev-image-lock?expand=1"
echo "::warning title=Image lock PR requires a maintainer::The lock branch was refreshed, but repository policy prevents GitHub Actions from opening its PR. Open $compare_url"
{
    echo
    echo "### Image lock pull request requires a maintainer"
    echo
    echo "Repository policy prevented GitHub Actions from opening the pull request."
    echo "[Open the prepared comparison]($compare_url)."
} >> "$GITHUB_STEP_SUMMARY"
