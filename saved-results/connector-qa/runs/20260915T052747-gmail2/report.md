# Connector QA run 20260915T052747-gmail2

Started 2026-09-15T05:27:47.567Z. Simulator `49A153C3-BA69-468F-BD21-D827A84E6F07`. Run marker `qa2026091505270647` (sweep with `node ios/qa/connector-qa/run.mjs cleanup --run 20260915T052747-gmail2`).
Model turns spent: 8 on ssdear@gmail.com (ChatGPT, personal, owner-approved 2026-09-14).
**Mechanical verdicts only. The judge has not run yet** (see SKILL.md step 5).

| verdict | scenarios |
|---|---|
| pass | 1 |
| flaky | 0 |
| fail | 3 |
| blocked | 0 |

## gmail

| scenario | kind | verdict | repeats | why |
|---|---|---|---|---|
| gmail-precise-latest | precise | **pass** | 1:p 2:p |  |
| gmail-casual-anything-new | casual | **fail** | 1:f 2:f | #1; reply-present (driver-missing); commands-any (expected one of connections.read; fired none); operations-any (expected one of gmailMessages; saw none); response-seen (0 provider responses)<br>#2; reply-present (driver-missing); commands-any (expected one of connections.read; fired none); operations-any (expected one of gmailMessages; saw none); response-seen (0 provider responses) |
| gmail-vague-mail | vague | **fail** | 1:f 2:f | #1; reply-present (driver-missing); commands-any (expected one of connections.read; fired none); operations-any (expected one of gmailMessages\|outlookInbox; saw none); response-seen (0 provider responses)<br>#2; reply-present (driver-missing); commands-any (expected one of connections.read; fired none); operations-any (expected one of gmailMessages\|outlookInbox; saw none); response-seen (0 provider responses) |
| gmail-typo | typo | **fail** | 1:f 2:f | #1; reply-present (driver-missing); commands-any (expected one of connections.read; fired none); operations-any (expected one of gmailMessages; saw none); response-seen (0 provider responses)<br>#2; reply-present (driver-missing); commands-any (expected one of connections.read; fired none); operations-any (expected one of gmailMessages; saw none); response-seen (0 provider responses) |

## Every turn

### gmail-precise-latest#1 (relaunch, 19 s, pass)

Prompt: what's the most recent email in my gmail, who's it from and what's the subject?

Commands: connections.read. Operations: gmailMessages. Responses: gmailMessages=200, gmailMessages=200. Alerts: none.

Reply:

```
- **From:** SMU Transfer Admission (`transfer@smu.edu`)
- **Subject:** 🍂✨ Discover SMU this Fall – Special Transfer Specific Visits
```

### gmail-precise-latest#2 (continue, 15 s, pass)

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
(none; driver-missing)
```

### gmail-casual-anything-new#2 (continue, ? s, fail)

Prompt: anything new in my inbox?

Commands: none. Operations: none. Responses: none. Alerts: none.

Reply:

```
(none; driver-missing)
```

### gmail-vague-mail#1 (relaunch, ? s, fail)

Prompt: check mail

Commands: none. Operations: none. Responses: none. Alerts: none.

Reply:

```
(none; driver-missing)
```

### gmail-vague-mail#2 (continue, ? s, fail)

Prompt: check mail

Commands: none. Operations: none. Responses: none. Alerts: none.

Reply:

```
(none; driver-missing)
```

### gmail-typo#1 (relaunch, ? s, fail)

Prompt: did anyone emial me today? gmial

Commands: none. Operations: none. Responses: none. Alerts: none.

Reply:

```
(none; driver-missing)
```

### gmail-typo#2 (continue, ? s, fail)

Prompt: did anyone emial me today? gmial

Commands: none. Operations: none. Responses: none. Alerts: none.

Reply:

```
(none; driver-missing)
```


**aborted after 6 consecutive driver errors.**
