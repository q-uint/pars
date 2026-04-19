#!/usr/bin/env bash
#
# Build the pars-lsp binary + VSCode extension, bundle them into a
# .vsix, and install it into the user's VSCode.
#
# The pars-lsp binary is copied into editors/vsx/bin/ so the extension
# can launch it via `context.extensionPath` with no user configuration.
# The .vsix is therefore self-contained for the current platform.
#
# Usage:
#   ./editors/vsx/install.sh              # build, package, install
#   ./editors/vsx/install.sh --no-install # build + package only
#   ./editors/vsx/install.sh --no-build   # skip zig build (reuse zig-out/bin/pars-lsp)

set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd -- "${here}/../.." && pwd)"

do_build=1
do_install=1
for arg in "$@"; do
  case "${arg}" in
    --no-build)   do_build=0 ;;
    --no-install) do_install=0 ;;
    -h|--help)
      sed -n '3,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "unknown flag: ${arg}" >&2; exit 2 ;;
  esac
done

say() { printf "\033[1;34m==>\033[0m %s\n" "$1"; }

if [[ "${do_build}" == "1" ]]; then
  say "building pars-lsp (ReleaseSafe)"
  (cd "${root}" && zig build -Doptimize=ReleaseSafe)
fi

say "bundling pars-lsp into the extension"
mkdir -p "${here}/bin"
cp "${root}/zig-out/bin/pars-lsp" "${here}/bin/pars-lsp"
chmod +x "${here}/bin/pars-lsp"
# A leftover `pars` binary from the previous task-provider bundle would
# be packaged back into the .vsix on install; scrub it here.
rm -f "${here}/bin/pars"

say "bundling icon into the extension"
mkdir -p "${here}/icons"
cp "${root}/assets/logo.svg" "${here}/icons/pars.svg"

say "installing extension dependencies"
(cd "${here}" && bun install --silent)

# Bundle extension.ts with its runtime deps into a single CommonJS
# file. `vscode` is provided by the host and must stay external.
say "bundling extension.js"
(cd "${here}" && bunx bun build src/extension.ts \
  --outfile=out/extension.js \
  --target=node \
  --format=cjs \
  --external=vscode)

say "packaging .vsix"
vsix_path="${here}/pars.vsix"
rm -f "${vsix_path}"
# --no-dependencies: we've already bundled everything via `bun build`,
#   so vsce doesn't need to collect node_modules.
# --skip-license: skip the required LICENSE check at the extension
#   root; the repo-level LICENSE at the root covers it.
(cd "${here}" && bunx -p @vscode/vsce vsce package \
  --no-dependencies \
  --skip-license \
  --out "${vsix_path}")

if [[ "${do_install}" == "0" ]]; then
  say "built ${vsix_path}; skipping install (--no-install)"
  exit 0
fi

if ! command -v code >/dev/null 2>&1; then
  cat >&2 <<EOF
the 'code' CLI is not on PATH. open the VSCode command palette and run
  "Shell Command: Install 'code' command in PATH"
then re-run this script, or install manually:
  code --install-extension ${vsix_path}
EOF
  exit 1
fi

say "installing into VSCode"
code --install-extension "${vsix_path}" --force

say "done. reload any open VSCode windows to pick up the new version."
