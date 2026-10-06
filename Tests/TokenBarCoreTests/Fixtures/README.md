# Test fixtures

Sample payloads for `TokenBarCoreTests`. The test target excludes this directory (see `Package.swift`), so fixtures are read from disk with `Fixtures.url(_:)` in `Support/TestSupport.swift`.

All fixtures must be synthetic or redacted. They must never contain real tokens, emails or account ids.
