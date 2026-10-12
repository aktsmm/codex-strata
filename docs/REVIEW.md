# v0.1.0 release review

Reviewed on 2026-10-12 before the initial public release.

## Scope and method

Source inspection and executable integration checks covered both entry points,
server startup and reuse, configuration, argument forwarding, authentication,
installation and updates, error paths, test cleanup, licensing, documentation,
images, and release contents. This was a maintainer self-review, not an
independent audit or a different-model review.

## Findings resolved

- Batch-based Codex invocation changed literal `%` and `&` prompt text. The
  official npm shim now resolves to Node plus `codex.js`; native arguments are
  forwarded directly. Custom batch backends are rejected. The PowerShell
  entry point is documented for shell-sensitive arguments.
- Detached servers could retain the caller's captured output handles. A Python
  entry point opens the startup logs in the detached process. Captured CLI runs
  now complete while the server stays available.
- Fixture cleanup now pins a process handle and verifies the unique fixture
  path before terminating a recorded PID.
- Installation and updates preserve user settings, back up replaced files, and
  include the license, attribution, and referenced Strata license text.
- Both README versions explain lazy loading, background lifetime, PATH
  conflicts, credentials, native backend selection, and known compatibility.

## Verification

PowerShell 7.6.6 and Python 3.12.10 on Windows:

- All 16 integration tests passed. They use mock servers without model files,
  a GPU, npm, or third-party Python test packages.
- Covered startup, server reuse, concurrent launch, spaces and quotes in paths
  and arguments, literal shell characters, port conflicts, service/model
  mismatch, credentials, startup crash, timeout, help/version, exit codes, and
  installation/update preservation.
- The installation/update test passed again after adding the upstream license
  to the installation payload.
- PowerShell source parsed without syntax errors.
- Real npm Codex CLI 0.160.0-alpha.6 with Strata returned exactly
  `CODEX_STRATA_READY` through the released launcher; exit code was zero.
- English and Japanese README links and screenshot paths were checked.
- Screenshot contents were visually inspected. Private paths, session IDs,
  credentials, and conversation history are absent from the published images.
- Release contents exclude personal settings, model files, executables,
  runtime caches, private skills, conversation logs, and credentials.

## Boundaries

Windows with PowerShell 7.3+ is required. Other Codex versions are unverified;
its custom model metadata schema may require future adjustments. The launcher
waits for a healthy HTTP API, while a lazily loaded model can load on the first
request. A supplied API key is not validated until the server handles a model
request. Codex's own plugin/update requests can produce network warnings;
local inference does not guarantee a completely offline CLI.

The CLI image is a browser-rendered excerpt of recorded command output, not a
native interactive terminal screenshot. The Strata image captures its actual
web interface with an empty chat. Both are labeled in the README.

No unresolved release-blocking findings remained after the fixes and checks.
