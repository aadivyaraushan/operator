# Outlook Calendar writes, and Outlook Mail / Calendar Permissions rows (2026-09-17)

Ask: "add an event today at 8pm to my outlook calendar" was refused as
unsupported. Outlook calendar had a read (`outlookCalendarEvents`) but no
write, and the Microsoft sign-in only asked for `Calendars.Read`.

## What changed
- New writes, each behind the owner's confirmation card:
  `outlookCalendarCreateEvent` (subject, startRFC3339, endRFC3339, body?) and
  `outlookCalendarUpdateEvent` (eventID plus any of subject, body, start, end;
  a time change needs both ends). Graph: POST `/v1.0/me/events` (201) and
  PATCH `/v1.0/me/events/{id}` (200). Times are sent as UTC wall-clock with
  timeZone "UTC"; Outlook shows them in the calendar's own zone.
- Microsoft scope `Calendars.Read` -> `Calendars.ReadWrite`. The owner must
  reconnect Outlook once to get the new permission.
- Permissions page: the single "Microsoft" row is now "Outlook Mail" (inbox;
  draft/send) and a new "Outlook Calendar" row (events; add/change). Grants
  saved under the old Microsoft row carry over to Outlook Mail (same id);
  Outlook Calendar starts off and must be switched on.
- Model guidance (workspace-guidance.mjs) names the new operations; runtime restaged.

## Tests
- `OutlookCalendarWriterTests` (5): scope, create body/URL/UTC times, update
  sends only given fields, bad input refused before any request, missing id
  not trusted. Written alongside the code, not watched failing first.
- Confirmation card test; ConnectorPermissions test maps the new operations.
- Full app suite: 537 run, only the Spotify loopback test fails (pre-existing).

## Not yet verified in the real app
- Reconnect Outlook, switch on Outlook Calendar > Read and Act, then ask for
  the 8pm event.
