# Scenario banks

One JSON file per connector. Every scenario is a prompt a real person might
type, plus what must be true afterwards. The runner turns each scenario into
`repeats` steps and checks the log and the persisted reply, so the fields here
are the whole contract.

```json
{
  "connector": "gmail",
  "provider": "google",
  "scenarios": [
    {
      "id": "gmail-casual-latest",
      "kind": "casual",
      "prompt": "anything new in my inbox?",
      "expect": {
        "outcome": "answer",
        "commands_any": ["connections.read"],
        "operations_any": ["gmailMessages"],
        "commands_none": ["connections.write"],
        "approval": "none"
      }
    }
  ]
}
```

## Fields

- `connector`: bank name, used by `--connector`.
- `provider`: `google | microsoft | slack | spotify | notion | whatsapp | discord | canvas | device | public`.
  `device` and `public` need no sign-in. The others are reported `blocked`, not
  `fail`, when the log shows the account is not connected.
- `id`: unique across all banks.
- `kind`: one of `precise casual vague typo indirect followup clarify decline write handoff`.
  A bank needs every kind except `write` and `handoff`, which apply only where
  the connector has a write or opens another app.
- `prompt`: what gets typed. `{marker}` is replaced by the run marker so writes
  can be swept afterwards. Write prompts must target the owner only.
- `after`: id of the scenario to send first, in the same session, before this
  one. Used by `followup` scenarios. The predecessor's own checks still run.
- `launch`: `alternate` (default: cold, warm, cold, …), `relaunch`, or `continue`.
- `cleanup`: set to `none` on a write whose effect leaves nothing behind (starting
  playback); such prompts may omit `{marker}`.
- `approve`: what the driver does with approval alerts: `allow` (default),
  `deny`, `none`. Operator's own grant banner ("Operator wants to read X") is
  allowed under both `allow` and `deny` - the deny is for the per-action
  approval that follows - and left alone under `none`. Those taps are recorded
  with source `permission` and never count as approval alerts.

## `expect`

- `outcome`:
  - `answer`: the connector fired and the reply reports real data.
  - `clarify`: the reply asks a question and no write fired.
  - `decline`: the reply says plainly it cannot or will not, no write fired,
    and it does not claim success.
  - `handoff`: something was opened; the reply must not claim the action
    completed.
- `commands_any`: at least one of these node commands must appear as
  `handling command=…` in the app log during the step. Names are the wire
  names: `connections.read`, `connections.write`, `notion.call`,
  `whatsapp.messages`, `maps.search`, `reminders.list`, and so on.
- `operations_any`: for `connections.read` / `connections.write`, at least one
  of these operations must appear in `[account-read]` / `[account-write]` lines.
- `commands_none`: none of these may fire. Reads never fire writes.
- `approval` (`none`, `required`, or `any` when an alert may or may not appear): `none` or `required`. `required` means an approval alert must be
  seen and acted on.
- `reply_must_contain_any`, `reply_must_not_contain`: case-insensitive
  substrings. The default failure-phrase list is applied to every `answer`
  scenario on top of these.
- `oracle`: optional note for the judge on how to check the reply against
  reality (for example "compare with the newest subject in the owner's inbox").
