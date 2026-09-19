# Google Tasks: writes and its own Permissions row (2026-09-17)

Why it was read-only: the Google sign-in only asked for `tasks.readonly`, and
no write operation for Tasks existed.

## What changed
- Sign-in now asks for `https://www.googleapis.com/auth/tasks` (read + write).
  **Google must be disconnected and connected again** for this to take effect.
- New writes through `connections.write`, each behind the approval card:
  `googleTasksCreateTask` (title, notes?, due? as YYYY-MM-DD, list?) and
  `googleTasksUpdateTask` (taskID, any of title/notes/due/completed, list?).
  completed true ticks a task off, false reopens it. No delete.
- New "Google Tasks" row on the Permissions page with its own Read and Act
  switches (`ConnectorID.googleTasks`). Operations starting `googleTasks`
  need this row, not the Google row. The old Google grant does NOT carry
  over: turn Google Tasks > Read (and Act) on once.

## Verified
- 501 app tests, 117 core tests, 21 runtime tests pass
  (new: `GoogleTasksWriterTests`, a task card test, permission mapping).
- NOT verified in the real app: needs the owner to reconnect Google first.
