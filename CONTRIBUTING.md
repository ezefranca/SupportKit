# Contributing

Thanks for improving SupportKit. Small, focused pull requests with tests and clear privacy impact are easiest to review.

## Development setup

Install Xcode 26 or newer, SwiftFormat, SwiftLint, Node.js 22 or newer, and a duplicate-code detector compatible with
`jscpd`. Then run:

```sh
swift build
swift test
swiftformat --lint Sources Tests Package.swift
swiftlint lint --strict
./scripts/check-secrets.sh

cd Gateway
npm ci
npm run check
```

Run `swiftformat Sources Tests Package.swift` before committing Swift changes. Do not weaken a quality or security rule
to hide a new finding; fix the cause or explain a narrowly scoped suppression.

## Pull requests

- Add Swift Testing or server-adapter tests for behavior changes.
- Preserve Swift 6 strict-concurrency correctness and actor isolation.
- Document every new public API with `///` comments and update relevant guides.
- Describe new data collection, retention, logging, permissions, network destinations, or secret requirements.
- Keep GitHub credentials and real support payloads out of tests and fixtures.
- Update `CHANGELOG.md` under **Unreleased** for user-visible changes.

By participating, you agree to follow `CODE_OF_CONDUCT.md`. Contributions are accepted under the MIT License.
