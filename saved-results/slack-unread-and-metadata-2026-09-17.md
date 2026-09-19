# Slack reads: unread state, sender names, more fields (2026-09-17)

## Why
"Can you read my unread slack messages" got "Slack doesn't expose
read/unread status". Our reader only called `conversations.list` and
`conversations.history`, neither of which carries read state. Slack does
have it: `conversations.info` (user token) returns the channel's `last_read`
and `unread_count`. Existing scopes (`channels:read`, `groups:read`,
`users:read`) cover the extra calls; no re-sign-in.

## What the reads return now (`DirectAccountReader`)
- `slackChannels`: every row also has `last_read`, `unread_count`,
  `unread_count_display` (one `conversations.info` per channel, all at once),
  plus `is_member`, `is_im`, `is_mpim`, `num_members`, `created`, `updated`.
- `slackHistory`: each message has `unread` (its `ts` newer than the
  channel's `last_read`), `channel_last_read`, `channel_unread_count`,
  `user_name` (from `users.info`, one call per distinct sender), and the
  extra fields `bot_id`, `username`, `subtype`, `reply_count`,
  `reply_users_count`, `latest_reply`, `reactions`, `edited`, `pinned_to`,
  `files` (dropped by the existing size cap when Slack's file objects are
  large).
- If an extra lookup fails the row goes out without those fields; the read
  itself still succeeds. Nothing is ever marked read by reading.
- Guidance (`workspace-guidance.mjs`): read channels, then history of each
  channel with `unread_count` > 0, report rows marked unread.

## Verified
- Tests: `SlackReadMetadataTests` (3), `DirectAccountReaderTests` (28),
  `ConnectionDiscoveryServiceTests` all pass.
- Live, QA Simulator, 22:53: "Which Slack channels have unread messages" ->
  logs `slack channel state channels=4 resolved=4`, `slack history state
  hasLastRead=true ... named=2`; answer named the one channel with an unread
  item (a join notice) and said the other three had none.

## Cost
Each channel list costs 1 + N requests, each history read 2 + distinct
senders. Slack's rate limit for these is about 50/min per token; a
20-channel list is 21 calls, fine for one read, but reading history of many
channels in one turn could approach it (429 is surfaced as `rateLimited`).
