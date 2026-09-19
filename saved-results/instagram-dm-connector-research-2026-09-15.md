# Instagram DMs on a private account: can Operator read and write them?

**Date:** 2026-09-15
**For:** Whether an Instagram connector can read and write the owner's DMs
when the account is a private personal account, under the standing rule that
no connector may put a real account at risk of a ban.
**Sources checked:** Meta developer docs (Instagram API with Instagram Login:
overview, messaging, conversations, get-started, refresh_access_token),
Instagram Help Center (professional account setup 502981923235522, Terms of
Use 581066165581870, scraping restriction 740480200552298), mautrix docs and
July 2026 release notes, instagrapi issue tracker via postzen.dev, the repo's
own Browserbase spike (saved-results/browserbase-instagram-dm-spike.md).

## Bottom line

**No.** There is no sanctioned way to read or send DMs on a private Instagram
account. The only official DM API requires a professional account, and a
professional account cannot be private. Every route that works on a private
account is an unofficial client, which is exactly what Instagram's own
restriction page names as grounds for restricting the account. The Discord
precedent (second account, acknowledged risk) does not carry over: a second
account cannot see the owner's DMs.

## The official route, and what it costs

Meta's "Instagram API with Instagram Login" has a Messaging API and a
Conversations API. Facts, each from the Meta docs:

| Fact | Consequence for Operator |
| --- | --- |
| "Your app users must have an Instagram professional account." Personal accounts are not served. | The owner must switch to Business or Creator first. |
| Help Center: "If your personal account is private, switching to a professional account will make it public. All pending follow requests will be automatically accepted when you go public." | The account stops being private, permanently for as long as the API is in use. Pending requests are accepted with no undo. |
| Standard Access "is all your app needs" when the app "only serves your Instagram professional account". No App Review, no Business Verification. | Same shape as Google Testing mode: works for the owner's own account without review. |
| "Access tokens from the App Dashboard are long-lived and are valid for 60 days." Refreshable with `GET graph.instagram.com/refresh_access_token?grant_type=ig_refresh_token` once older than 24 h, no client secret needed. | The owner pastes a dashboard token into Operator, as with the Discord token. No OAuth redirect on the phone, no app secret on the phone. |
| No Facebook Page required. | One Meta developer account and one Business-type app is the whole registration. |
| Instagram app setting: Settings > Messages and story replies > Message controls > Connected tools > "Allow access to messages" must be on. | One more toggle in setup instructions. |
| Conversations API: "you can only get details about the 20 most recent messages in the conversation"; older ones "you will see an error that the message has been deleted". Requests-folder conversations inactive for 30 days are not returned. 2 calls/s per account. | Read is "recent DMs", not history. |
| "Only after an Instagram user has sent your app user's Instagram professional account a message can your app send a message." "Your app has 24 hours to respond." | Write is reply-only, inside 24 h of their last message. Operator cannot start a conversation. |
| `human_agent` tag extends the reply window to 7 days, but it is a reviewed feature ("apply for the Human Agent permission"; review "required to use the human_agent message tag in production"). | Assume 24 h only. Not verified whether the tag works under Standard Access. |
| "Group messaging is not supported." | 1:1 threads only. |
| Ban risk | None beyond ordinary API policy; this is the route Meta built. |

So the official connector is: recent 1:1 DMs, reply within 24 h, on an
account that has been made public. Whether that trade is worth it is the
owner's call, not a technical one.

## The unofficial routes, and why the rule excludes them

Every route that reads a *private* account's DMs is an unofficial client:

- **instagrapi / instagram-private-api**: emulate the Android app, sign
  requests with a fake device. Full read/write. Issue tracker in 2026 still
  shows `challenge_required` on login (#2718, July 2026) and accounts
  suspended after trivial reads (#1806, #1559).
- **mautrix-instagram (Beeper's bridge)**: Instagram changed its DM protocol
  in mid-2026; the bridge was rewritten and logs in with cookies
  (`sessionid`, `csrftoken`, `mid`, `ig_did`, `ds_user_id`) pasted from a
  browser. Its own docs: "Meta may decide your account has suspicious
  activity and block you until you do some tasks like completing a captcha,
  adding a phone number or resetting your password."
- **Browser automation**: the repo already proved this on a throwaway
  (Browserbase, 2026-08-02): login needed an email OTP, cloud egress IPs
  showed as a foreign login, and a send only worked after a mutual follow.
  Doing the same in an on-phone WKWebView removes the foreign-IP tell but
  is still automated access of a logged-in session.

Instagram's own words on what gets an account restricted (help page
740480200552298): "Your account is automating access to, or collecting
information in an automated way without our permission", "You may have
provided your username and password to a third-party app or website", "You
used an app or service to interact with Instagram in unauthorized ways."
The Terms of Use: "You can't attempt to create accounts or access or collect
information in unauthorized ways. This includes ... accessing or collecting
information in an automated way without our express permission, regardless of
whether such automated access or collection is undertaken while logged-in to
an Instagram account." Sanction: "terminating or disabling your access to
the Meta Products".

Why the Discord acceptance does not transfer: Discord's read was of public
server channels, so a second account sees the same content and the main
account is never exposed. DMs exist only on the account that received them.
Any unofficial read of the owner's DMs is a login on the real account, which
is the one thing the standing rule forbids.

## What a private account can have

1. **Hand-off** (the Android Wave 1 ceiling, not yet on iOS): draft the
   message, copy it, open Instagram to the inbox. No login, no read, no
   claim of delivery. Ceiling `hands_off`.
2. **Batch history, manual**: Accounts Center > Download your information
   includes messages as JSON. Sanctioned, works on private accounts, takes
   hours to days, and the owner has to fetch the archive themselves. Useful
   for "what did X say last month", useless for "anything new".

## Decision needed from the owner

- Keep the account private: build hand-off only, or nothing.
- Go public (Creator): the official connector above is buildable in the
  Discord shape (pasted token, Keychain, polled reads, reply within 24 h),
  with no ban acknowledgement needed because the route is sanctioned.

The plan's exclusion "no Instagram messaging bridge" stands either way.
