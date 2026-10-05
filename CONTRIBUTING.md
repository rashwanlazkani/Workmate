# Contributing

Open an issue to discuss a bug or a substantial feature before sending a pull request. Include macOS/toolchain versions, reproduction steps and expected behavior. Use synthetic notes in screenshots and examples.

## Checks

- Native: `zsh Scripts/test.sh` and `zsh Scripts/build.sh` on macOS with Swift 6.
- Backend changes: `cd Cloud && npm ci && npm run check` with Node 22+.
- Never deploy the backend as part of ordinary tests; integration tests require your own AWS account.

Keep the native app usable without AWS or paid AI. Preserve workspace compatibility and test migrations and data handling changes. Keep secrets, workspace data, endpoints for personal deployments, and generated app bundles out of commits. Run `gitleaks git --log-opts="--all" --redact` before publishing branches.

Pull requests are contributed under the MIT license. Please be respectful and keep reviews focused on the code.
