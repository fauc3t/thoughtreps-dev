# Sync wire format v1 golden fixtures

One JSON file per message of the sync API, mirrored byte for byte from `thoughtreps-aws`
`infra/lambda/sync/fixtures/wire-v1/`. Changing one means changing both repos, together with the zod schemas
(`infra/lambda/sync/schemas.ts`) and `SyncHTTPWireV1` (`ThoughtReps/Sync/SyncHTTPWire.swift`).

`SyncHTTPWireTests` decodes every file into the wire structs, checks the values, and pins each file's SHA-256 (the same
hashes the server-side `wire-v1.test.ts` pins). The wire format is frozen once shipped.
