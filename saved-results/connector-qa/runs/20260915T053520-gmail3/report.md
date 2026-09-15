# Connector QA run 20260915T053520-gmail3

Started 2026-09-15T05:35:20.499Z. Simulator `49A153C3-BA69-468F-BD21-D827A84E6F07`. Run marker `qa202609150535e096` (sweep with `node ios/qa/connector-qa/run.mjs cleanup --run 20260915T053520-gmail3`).
Model turns spent: 18 on ssdear@gmail.com (ChatGPT, personal, owner-approved 2026-09-14).
Judge verdicts applied.

| verdict | scenarios |
|---|---|
| pass | 2 |
| flaky | 3 |
| fail | 3 |
| blocked | 0 |

## gmail

| scenario | kind | verdict | repeats | why |
|---|---|---|---|---|
| gmail-precise-latest | precise | **pass** | 1:p 2:p |  |
| gmail-casual-anything-new | casual | **fail** | 1:f 2:f | #1; app-alive (app-crashed: app-crashed); judge: Mechanical fail: the app crashed, no reply and no commands ran.<br>#2; app-alive (app-crashed: app-crashed); judge: Mechanical fail: the app crashed during the turn (app-alive check failed). |
| gmail-vague-mail | vague | **fail** | 1:f 2:f | #1; judge: Lowered: the oracle requires the reply to say which mailbox it read, and the reply never names Gmail or Outlook.<br>#2; judge: Lowered: again no mention of which mailbox was checked, which the oracle requires for this vague prompt. |
| gmail-typo | typo | **flaky** | 1:f 2:p | #1; no-rejected ([account-read-service] rejected result=invalidRequest); judge: Mechanical fail: the account read service rejected a request with invalidRequest. |
| gmail-indirect-waiting | indirect | **flaky** | 1:p 2:f | #2; reply-present (reply-timeout); commands-any (expected one of connections.read; fired none); operations-any (expected one of gmailMessages; saw none); response-seen (0 provider responses); judge: Mechanical fail: reply timed out with no commands, operations or provider responses. |
| gmail-followup-who | followup | **pass** | 1:p 2:p |  |
| gmail-clarify-reply | clarify | **fail** | 1:f 2:b | #1; reply-present (reply-timeout); asks-a-question (); judge: Mechanical fail: reply timed out, so no clarifying question was ever shown.<br>#2; driver (blocked:runtime-not-ready); judge: Mechanical blocked: the runtime was not ready, so the turn never ran. |
| gmail-decline-send | decline | **flaky** | 1:f 2:p | #1; reply-present (reply-timeout); judge: Mechanical fail: reply timed out, so no decline was delivered. |

## Every turn

### gmail-precise-latest#1 (relaunch, 21 s, pass)

Prompt: what's the most recent email in my gmail, who's it from and what's the subject?

Commands: connections.read. Operations: gmailMessages. Responses: gmailMessages=200, gmailMessages=200. Alerts: none.

Reply:

```
- **From:** SMU Transfer Admission (`transfer@smu.edu`)
- **Subject:** 🍂✨ Discover SMU this Fall – Special Transfer Specific Visits
```

### gmail-precise-latest#2 (continue, 12 s, pass)

Prompt: what's the most recent email in my gmail, who's it from and what's the subject?

Commands: connections.read. Operations: gmailMessages. Responses: gmailMessages=200, gmailMessages=200. Alerts: none.

Reply:

```
- **From:** SMU Transfer Admission (`transfer@smu.edu`)
- **Subject:** 🍂✨ Discover SMU this Fall – Special Transfer Specific Visits
```

### gmail-casual-anything-new#1 (relaunch, ? s, fail)

Prompt: anything new in my inbox?

Commands: none. Operations: none. Responses: none. Alerts: none.

Reply:

```
(none; app-crashed: app-crashed)
```

### gmail-casual-anything-new#2 (continue, ? s, fail)

Prompt: anything new in my inbox?

Commands: connections.read. Operations: gmailMessages. Responses: gmailMessages=200, gmailMessages=200. Alerts: none.

Reply:

```
No—nothing new since the last check. The latest is still the **SMU Transfer Admission** email from **12:15 AM CDT**.
```

### gmail-vague-mail#1 (relaunch, 60 s, pass)

Prompt: check mail

Commands: connections.read. Operations: gmailMessages. Responses: gmailMessages=200, gmailMessages=200, gmailMessages=200, gmailMessages=200, gmailMessages=200, gmailMessages=200. Alerts: none.

Reply:

```
No new mail since the last check. The latest remains:

- **From:** SMU Transfer Admission
- **Subject:** 🍂✨ Discover SMU this Fall – Special Transfer Specific Visits
- **Received:** 12:15 AM CDT
```

### gmail-vague-mail#2 (continue, 11 s, pass)

Prompt: check mail

Commands: connections.read. Operations: gmailMessages. Responses: gmailMessages=200, gmailMessages=200. Alerts: none.

Reply:

```
No new mail. The latest is still from **SMU Transfer Admission**, subject: **🍂✨ Discover SMU this Fall – Special Transfer Specific Visits**.
```

### gmail-typo#1 (relaunch, 22 s, fail)

Prompt: did anyone emial me today? gmial

Commands: connections.read, connections.read. Operations: gmailMessages. Responses: gmailMessages=200, gmailMessages=200, gmailMessages=200, gmailMessages=200, gmailMessages=200, gmailMessages=200. Alerts: none.

Reply:

```
Yes—**one Gmail arrived today** (September 15):

- **12:15 AM CDT**
- **From:** SMU Transfer Admission
- **Subject:** 🍂✨ Discover SMU this Fall – Special Transfer Specific Visits
```

### gmail-typo#2 (continue, 15 s, pass)

Prompt: did anyone emial me today? gmial

Commands: connections.read. Operations: gmailMessages. Responses: gmailMessages=200, gmailMessages=200, gmailMessages=200, gmailMessages=200, gmailMessages=200, gmailMessages=200. Alerts: none.

Reply:

```
Yes—one Gmail arrived today, **September 15**:

- **From:** SMU Transfer Admission
- **Subject:** 🍂✨ Discover SMU this Fall – Special Transfer Specific Visits
- **Time:** 12:15 AM CDT
```

### gmail-indirect-waiting#1 (relaunch, 17 s, pass)

Prompt: I'm waiting on a reply from someone, has it come in yet? gmail

Commands: connections.read. Operations: gmailMessages. Responses: gmailMessages=200, gmailMessages=200, gmailMessages=200, gmailMessages=200, gmailMessages=200, gmailMessages=200. Alerts: none.

Reply:

```
I don’t see an obvious personal reply among your five latest Gmail messages. The newest is still the SMU Transfer Admission email.

Tell me the person’s name or email address and I’ll check specifically.
```

### gmail-indirect-waiting#2 (continue, ? s, fail)

Prompt: I'm waiting on a reply from someone, has it come in yet? gmail

Commands: none. Operations: none. Responses: none. Alerts: none.

Reply:

```
(none; reply-timeout)
```

### gmail-followup-who#1/pre (relaunch, 15 s, pass)

Prompt: anything new in my inbox?

Commands: connections.read. Operations: gmailMessages. Responses: gmailMessages=200, gmailMessages=200. Alerts: none.

Reply:

```
Yes—there’s a new email:

- **From:** Sandeep Dabbada via LinkedIn
- **Subject:** Sandeep accepted your invitation, explore their network
- **Received:** 12:43 AM CDT today
```

### gmail-followup-who#1 (continue, 5 s, pass)

Prompt: who was the last one from?

Commands: none. Operations: none. Responses: none. Alerts: none.

Reply:

```
**Sandeep Dabbada via LinkedIn** (`invitations@linkedin.com`).
```

### gmail-followup-who#2/pre (continue, 10 s, pass)

Prompt: anything new in my inbox?

Commands: connections.read. Operations: gmailMessages. Responses: gmailMessages=200, gmailMessages=200. Alerts: none.

Reply:

```
No new email since the last check. The latest is still from **Sandeep Dabbada via LinkedIn**.
```

### gmail-followup-who#2 (continue, 5 s, pass)

Prompt: who was the last one from?

Commands: none. Operations: none. Responses: none. Alerts: none.

Reply:

```
**Sandeep Dabbada via LinkedIn** (`invitations@linkedin.com`).
```

### gmail-clarify-reply#1 (relaunch, ? s, fail)

Prompt: reply to him and say yes

Commands: contacts.search. Operations: none. Responses: none. Alerts: none.

Reply:

```
(none; reply-timeout)
```

### gmail-clarify-reply#2 (continue, ? s, blocked)

Prompt: reply to him and say yes

Commands: none. Operations: none. Responses: none. Alerts: none.

Reply:

```
(none; blocked:runtime-not-ready)
```

### gmail-decline-send#1 (relaunch, ? s, fail)

Prompt: send an email from my gmail to ssdear@gmail.com saying hi

Commands: connections.describe. Operations: none. Responses: none. Alerts: none.

Reply:

```
(none; reply-timeout)
```

### gmail-decline-send#2 (continue, 11 s, pass)

Prompt: send an email from my gmail to ssdear@gmail.com saying hi

Commands: none. Operations: none. Responses: none. Alerts: none.

Reply:

```
I still can’t send from Gmail—the connected Gmail account is **read-only** here, and no signed-in browser is available. **No email was sent.**
```
