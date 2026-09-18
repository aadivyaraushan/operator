# YouTube subscriptions read (2026-09-18)

## Why
"What is the latest video on my YouTube subscriptions?" got "the YouTube
connector only supports public searches". `youtube.search` uses an API key
and cannot see the signed-in person's subscriptions. YouTube's Data API
does expose them behind the `youtube.readonly` OAuth scope, which the
existing Google sign-in can carry.

## What was built
- Google OAuth now also asks for `https://www.googleapis.com/auth/youtube.readonly`
  (`OAuthTypes.swift`). A phone with an older Google sign-in sees
  `reauthorizationRequired` and has to reconnect Google once.
- Two reads in `DirectAccountReader` (provider `.google`):
  - `youtubeSubscriptions` (limit, cursor): the channels the person follows.
    One call to `/youtube/v3/subscriptions?mine=true`. Rows: channelId,
    title, description, subscribedAt.
  - `youtubeSubscriptionFeed` (limit, channel?): the newest videos across
    up to 50 subscribed channels, last 7 days, newest first. Lists the
    subscriptions, then fetches each channel's uploads playlist
    (`UU` + channel id without `UC`, `playlistItems` maxResults=5) all at
    once; a channel that fails is dropped and the rest still answer. Rows:
    videoId, title, channelId, channelTitle, publishedAt, description, url.
    `channel` narrows it to one channel and skips the subscription list.
- Own Read switch "YouTube subscriptions" (`ConnectorID.youtubeSubscriptions`,
  operations prefixed `youtube` route there, checked before the plain
  `google` rule). No Act.
- Guidance bullet in `workspace-guidance.mjs` telling the model which read
  answers "latest on my subscriptions".

## Verified
- Tests: `YouTubeSubscriptionReadTests` (5), `DirectAccountReaderTests`,
  `ConnectionDiscoveryServiceTests`, core `ConnectorPermissionsTests` (9)
  all pass. Simulator build exit 0.
- Live, QA Simulator, 15:00: after reconnecting Google (scopeCount=5) and
  turning the switch on, "What is the latest video on my YouTube
  subscriptions?" -> log `youtube feed limit=5 channel=all`,
  `channels=50`, `resolved=50 failed=0`, `rows=5`; all 51 requests HTTP
  200; read took ~1.7 s, reply ~6 s after send. Answer named one video with
  channel, publish time and a "Watch on YouTube" link.

## Cost
Feed = 1 + N requests to YouTube, N = subscribed channels (cap 50), each
1 quota unit (search costs 100). Default daily quota is 10,000 units, so
one feed read is ~51 units.

## Quirk seen while testing
On the Permissions page the YouTube Read switch needed three taps before
the `[permissions] granted` log line appeared; the first two taps at the
knob did nothing. Not investigated; may just be simulator tap placement.
