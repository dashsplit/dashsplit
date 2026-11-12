#!/usr/bin/env bash
# Copyright © 2026 DashSplit LLC. All rights reserved.
# DashSplit merge gate — the same checks locally (before every handover) and in GitHub Actions (pr.yml).
# Usage: bash tools/gate.sh            → FULL gate locally (build, lint, every test) → writes .gate/result
#        bash tools/gate.sh --ci       → FAST gate in GitHub Actions: secrets, workflow lint, OSV, Semgrep, tests-with-code;
#                                        build/lint/tests are trusted from the local run, whose "GATE PASS (<sha>)" the
#                                        PR body must carry for the exact head commit (saves CI minutes)
# Pass = every applicable check exits 0. A missing tool is a FAIL locally (install it), never a silent skip.
# App repos add their language steps (detekt, ktlint, Konsist, buf, SBOM) — never weaken a step.
set -uo pipefail
CI=0; [ "${1:-}" = "--ci" ] && CI=1
ROOT="$(git rev-parse --show-toplevel)"; cd "$ROOT"
SHA="$(git rev-parse HEAD)"
FAILED=(); RAN=()

step() {  # step <name> <command...>
  local name="$1"; shift
  echo "── $name"
  if "$@"; then RAN+=("$name ✓"); else FAILED+=("$name"); RAN+=("$name ✗"); fi
}
need() { command -v "$1" >/dev/null || { echo "missing tool: $1 (brew install $1)"; return 1; }; }

# 1. Secrets: nothing secret anywhere in the committed history (untracked local files like logs are not shipped)
step "gitleaks" bash -c 'command -v gitleaks >/dev/null || { echo "missing tool: gitleaks"; exit 1; };
  gitleaks git --no-banner --redact .'

# 1b. Workflow files must be valid (a broken pr.yml silently runs no checks)
if ls .github/workflows/*.yml >/dev/null 2>&1; then
  step "actionlint" bash -c 'command -v actionlint >/dev/null || { echo "missing tool: actionlint"; exit 1; }; actionlint'
fi

# 2. Known-vulnerable dependencies (only when the repo has lockfiles/manifests)
if ls package-lock.json pnpm-lock.yaml gradle/libs.versions.toml */build.gradle.kts build.gradle.kts requirements*.txt 2>/dev/null | grep -q .; then
  step "osv-scanner" bash -c 'command -v osv-scanner >/dev/null || { echo "missing tool: osv-scanner"; exit 1; };
    osv-scanner scan source -r . ; rc=$?; [ $rc -eq 0 ] || [ $rc -eq 128 ]'   # 128 = no package sources
fi

# 3. Static security analysis (free registry rules, no account, metrics off)
SEMGREP_VERSION=1.181.0   # one version locally and in pr-checks (specs: Semgrep CE 1.181.0)
step "semgrep" bash -c 'command -v semgrep >/dev/null || { echo "missing tool: semgrep (pipx install semgrep=='"$SEMGREP_VERSION"')"; exit 1; };
  v=$(semgrep --version 2>/dev/null); [ "$v" = "'"$SEMGREP_VERSION"'" ] || { echo "semgrep $v installed, '"$SEMGREP_VERSION"' required (pipx install semgrep=='"$SEMGREP_VERSION"')"; exit 1; };
  semgrep scan --config p/default --metrics off --error --quiet --exclude ".gate" --exclude "build" .'

# 3b. Tests travel with code: a branch that changes production code must change tests too
step "tests-with-code" bash -c '
  changed=$(git diff --name-only origin/main...HEAD 2>/dev/null)
  code=$(echo "$changed" | grep -E "\.(kt|kts|ts|tsx|js|jsx|swift|astro|py)$" | grep -vE "(^|/)(test|tests|androidTest|commonTest|jvmTest|iosTest|jsTest|e2e|__tests__)/|Test\.kt$|\.(test|spec)\.(ts|tsx|js)$|^tools/|^\.github/|build\.gradle\.kts$|settings\.gradle\.kts$|\.config\.(ts|js)$" || true)
  tests=$(echo "$changed" | grep -E "(^|/)(test|tests|androidTest|commonTest|jvmTest|iosTest|jsTest|e2e|__tests__)/|Test\.kt$|\.(test|spec)\.(ts|tsx|js)$" || true)
  if [ -n "$code" ] && [ -z "$tests" ]; then echo "production code changed without any test change:"; echo "$code"; exit 1; fi'

if [ $CI -eq 1 ]; then  # build, lint and tests ran locally — stop here in CI
  echo; printf '%s\n' "${RAN[@]}"; [ ${#FAILED[@]} -eq 0 ] && echo "GATE (CI fast) PASS" || echo "GATE (CI fast) FAIL: ${FAILED[*]}"
  [ ${#FAILED[@]} -eq 0 ]; exit $?
fi

# 3c. Parent repo only: every project folder is a proper submodule (company CLAUDE.md hard rule)
if [ -f .gitmodules ] && [ -f .claude/hooks/submodule_check.py ]; then
  step "submodules" env CLAUDE_PROJECT_DIR="$ROOT" python3 .claude/hooks/submodule_check.py --strict
fi

# 4. Kotlin / Gradle repos
if [ -x ./gradlew ]; then
  if ./gradlew -q tasks --all 2>/dev/null | grep -q "^qualityCheck"; then step "gradle qualityCheck" ./gradlew qualityCheck --no-daemon; fi
  step "gradle check" ./gradlew check --no-daemon
fi

# 5. Web repos (React / Astro / Figma plugin): pnpm when pnpm-lock.yaml exists (DashSplit standard), npm otherwise
if [ -f package.json ]; then
  if [ -f pnpm-lock.yaml ]; then PM=pnpm; step "pnpm install" pnpm install --frozen-lockfile
  else PM=npm; step "npm ci" npm ci --no-audit --no-fund; fi
  for s in lint typecheck test build; do
    if node -e "process.exit(require('./package.json').scripts?.['$s']?0:1)"; then step "$PM run $s" $PM run "$s"; fi
  done
fi

# 5b. Coverage: lines ≥ 80 %, methods/functions ≥ 80 %, every changed source file ≥ 80 % lines.
#     Kotlin: Kover XML (./gradlew koverXmlReport); web: Vitest json-summary (npm test runs with coverage).
if [ -x ./gradlew ] || [ -f package.json ]; then
  if [ -x ./gradlew ]; then step "kover report" ./gradlew koverXmlReport --no-daemon; fi
  changed=$(git diff --name-only origin/main...HEAD 2>/dev/null | grep -E "\.(kt|ts|tsx)$" | grep -vE "(^|/)(test|tests|commonTest|jvmTest|androidTest|iosTest|jsTest|e2e|__tests__)/|Test\.kt$|\.(test|spec)\.(ts|tsx)$" || true)
  if [ -f tools/coverage_check.py ]; then
    step "coverage ≥ 80 % (lines, methods, changed files)" python3 tools/coverage_check.py --min 80 --changed $changed
  else
    step "coverage check present (add tools/coverage_check.py with the first app code)" false
  fi
fi

# 5c. Copyright line on every tracked source file (company CLAUDE.md, Documentation and copyright)
step "copyright line" bash -c '
  missing=$(git ls-files "*.py" "*.sh" "*.kt" "*.kts" "*.ts" "*.tsx" "*.js" "*.mjs" "*.swift" .githooks \
    | grep -vE "(^|/)(dist|build|node_modules|generated)/|\.min\.js$" \
    | while read -r f; do [ -f "$f" ] && ! head -5 "$f" | grep -q "Copyright ©" && echo "$f"; done)
  if [ -n "$missing" ]; then echo "missing \"Copyright © <year> DashSplit LLC. All rights reserved.\":"; echo "$missing"; exit 1; fi'

# 5d. SDDs follow rules/process/sdd_rule.md (format, diagrams, error codes, no open owner questions)
if [ -d knowledge/sdd ] && [ -f tools/sdd_check.py ]; then step "SDD check" python3 tools/sdd_check.py knowledge/sdd; fi

# 6. Python tools and hooks: compile + unit tests
if ls tools/*.py >/dev/null 2>&1; then step "python compile" python3 -m py_compile tools/*.py; fi
for d in tests; do
  if ls "$d"/test_*.py >/dev/null 2>&1; then step "python tests ($d)" python3 -m unittest discover -s "$d" -q; fi
done

echo; printf '%s\n' "${RAN[@]}"
if [ ${#FAILED[@]} -eq 0 ]; then RESULT="PASS"; else RESULT="FAIL: ${FAILED[*]}"; fi
if [ $CI -eq 0 ]; then
  mkdir -p .gate && printf '%s %s %s\n' "$RESULT" "$SHA" "$(date -u +%FT%TZ)" > .gate/result
  printf '%s\n' "${RAN[@]}" > .gate/steps
fi
echo "GATE $RESULT ($SHA)"
[ ${#FAILED[@]} -eq 0 ]
