# Repository split (historical)

The repository facade was split into capability-focused runners during the v4.x
refactor. Current ownership, runner responsibilities and dependencies live in
[Dart layer architecture](../../doc/ARCHITECTURE.md#repository-runners).

The migration extracted shared state first, then catalog, bulk, pool,
connection, query, stream and transaction runners, and finally reduced the
facade to delegation. Public contracts were preserved during that refactor.
This is historical context, not a freeze on future public API evolution.

For new work, use the current architecture and
[test policy](../../doc/TESTING.md), and test observable repository behavior.
