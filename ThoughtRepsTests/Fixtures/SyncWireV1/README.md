# Sync wire format v1 golden fixtures

One JSON file per message of the sync API, mirrored byte for byte from `thoughtreps-aws`
`infra/lambda/sync/fixtures/wire-v1/`. Changing one means changing both repos, together with the zod schemas
(`infra/lambda/sync/schemas.ts`) and `SyncHTTPWireV1` (`ThoughtReps/Sync/SyncHTTPWire.swift`).

`SyncHTTPWireTests` decodes every file into the wire structs, checks the values, and pins each file's SHA-256 (the same
hashes the server-side `wire-v1.test.ts` pins). The wire format is frozen once shipped.

Blob and pointer fixtures (phase 3, added after the rest; the existing files are unchanged): `blob-upload-urls-*`,
`blob-download-urls-*`, `push-pointer-request` (a `TRP1` payload) and `push-pointer-missing-blob` (409 `blob_missing`).
The URLs are examples; clients treat them as opaque.

Garbage collection and quota fixtures (phase 3c, added after the rest; the existing files are unchanged):
`garbage-collection-live-list-url-*`, `garbage-collection-start-*`, and the refusals `garbage-collection-stale` (409),
`garbage-collection-live-list-missing` (409), `garbage-collection-rate-limited` (429) and `blob-quota-exceeded` (413, from
`blobs/upload-urls`). The live list itself is not JSON: one 43-character blob name per line, every line ending in `\n`, so
its size is a multiple of 44.

Account, device and session fixtures (phase 4a, copied for the app in 4c-1; the 4b ones are below):
`device-challenge-response`, `device-register-*`, `sign-in-with-apple-*`, `session-*`, `vault-create-*` (`POST /vaults`, bearer
session) and the refusals `error-vault-exists`, `error-assertion-invalid`, `error-challenge-invalid`,
`error-attestation-invalid`, `error-identity-token-invalid`, `error-forbidden` and `error-device-in-vault`. Signed requests
(`sign-in-with-apple`, `session`) also carry the `x-tr-key-id` and `x-tr-assertion` headers, which no fixture covers.
`sign-in-with-apple-response` has `vaultId: null` and a vaultless session; `session-response` and `vault-create-response` have
a vault. Their structs are in `SyncHTTPWireV1` and are separate from the export-link API's (`AppAttestClient`).

Pairing, device, erase and account-deletion fixtures (phase 4b, copied for the app in 4c-2; the existing files are unchanged):
`pair-invite-request` and `pair-k-auth-request` (the two proofs for `POST /pair`; signed like sign-in, so the `x-tr-key-id` and
`x-tr-assertion` headers are not covered), `pair-response` (the sign-in response shape, always with a vault), `invite-create-*`
(`POST /vaults/{id}/invites`), `vault-create-named-request` (`POST /vaults` with the optional `nameSealed`),
`devices-list-response`, `device-rename-*`, `device-remove-response`, `vault-erase-*` (a stale epoch answers with
`push-epoch-changed`), `account-delete-response`, and the refusals `error-pairing-failed` (403), `error-device-limit` and
`error-too-many-invites` (409) and `error-reauthentication-required` (403). `nameSealed` is opaque base64 of at most 256 bytes
(the app seals it as `TRSN`, see `SyncCrypto.sealDeviceName`). `pairingSecret` is 16 to 64 bytes and an invite's `secretHash` is
the base64 SHA-256 of those decoded bytes. In a `/vaults/{id}/devices/{keyId}` path the `keyId` is base64url without padding;
in a JSON body it stays standard base64. The device, erase and account-deletion routes have wire structs and fixture tests but no
client yet (round 4c-3).
