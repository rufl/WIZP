#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
cd "${repo_root}"

python3 scripts/check_dependency_consistency.py
python3 scripts/check_bundled_frontend_contract.py
python3 scripts/check_package_layout_contract.py
python3 scripts/check_ui_ux_audit_contract.py
python3 scripts/check_ui_visual_contract.py
python3 scripts/test_ui_contract.py
python3 scripts/check_native_ui_baseline_contract.py
python3 scripts/check_release_workflow_contract.py
python3 scripts/check_release_evidence_runbook.py
python3 scripts/dependency_update_report.py
python3 scripts/release_artifact_report.py
python3 -m unittest scripts/test_package_self_contained_audit.py
python3 -m unittest scripts/test_terminal_resource_report.py
python3 -m unittest scripts/test_native_ui_baseline_smoke.py
python3 scripts/check_alpha_dispositions.py
python3 -m unittest scripts/test_beta_readiness_contract.py scripts/test_beta_handoff_artifact.py
./scripts/zigw.sh fmt --check src/
./scripts/zigw.sh build test -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-gnu
python3 -m py_compile scripts/parity_daemon_smoke.py scripts/parity_extension_host_smoke.py
python3 scripts/check_core_extension_boundary.py
./scripts/zigw.sh build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-gnu
python3 scripts/parity_daemon_smoke.py
python3 scripts/parity_frontend_smoke.py
(cd frontend && npm run build && npm run format:check && npm run lint)
# The dev Electrobun package is intentionally glibc-linked and does not carry
# the vendored CEF runtime. Build the release-shaped package before running
# its strict audit; auditing the dev package here creates false failures. The
# package build also rebuilds frontend/dist, so generate bundle truth after it.
npm run build:self-contained
python3 scripts/frontend_bundle_report.py --fresh
python3 scripts/beta_readiness_report.py
python3 scripts/check_beta_readiness_contract.py
python3 scripts/check_beta_handoff_artifact.py
