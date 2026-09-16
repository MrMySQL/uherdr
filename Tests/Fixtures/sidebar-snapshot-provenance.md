# Sidebar snapshot fixtures

- `snapshot-0.9-live.json`: actual `session.snapshot` response captured on 2026-09-16 from installed `herdr 0.9.0`, protocol 22, using a disposable local session/workspace. No user session data.
- `snapshot-0.9.json`: minimal legacy wire fixture including an agent, used for metadata-removal and identical-ID tests.
- `snapshot-0.9-title-only.json`: variant of the minimal legacy fixture with pane `title` but no pane `label` or agent `title`, exercising the older-server pane-token fallback.
- `snapshot-metadata.json`: public schema fixture using the fields verified in upstream commit `18061191fdc019498610aee81f0df93f6c2ebd31`: `src/api/schema/workspaces.rs:61-76`, `panes.rs:527-560`, `agents.rs:186-225`, `session.rs:8-23`. This is schema-derived, not a capture from a running newer binary. No such binary is available in the test environment.

`snapshot-0.9.json` and `snapshot-metadata.json` share IDs and labels intentionally. Replacing the metadata fixture with the legacy one simulates snapshot token expiry/removal; independently seeded sessions exercise device isolation.
