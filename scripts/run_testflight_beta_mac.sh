#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_DIR="${ROOT_DIR}/ios"

export BUNDLE_GEMFILE="${BUNDLE_GEMFILE:-${IOS_DIR}/Gemfile}"
export BACKEND_BASE_URL="${BACKEND_BASE_URL:-http://120.197.118.22:21080}"
export APPLE_TEAM_ID="${APPLE_TEAM_ID:-76PHSCHPCK}"

if [ -n "${APPLE_ID:-}" ] && [ -z "${FASTLANE_USER:-}" ]; then
  export FASTLANE_USER="${APPLE_ID}"
fi

if [ -n "${APP_SPECIFIC_PASSWORD:-}" ] && [ -z "${FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD:-}" ]; then
  export FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD="${APP_SPECIFIC_PASSWORD}"
fi

export PATH="$HOME/.gem/ruby/$(ruby -e 'print RbConfig::CONFIG["ruby_version"]')/bin:$HOME/.local/bin:$HOME/bin:$PATH"

cd "${IOS_DIR}"
bundle install --jobs 4 --retry 3
bundle exec fastlane beta
