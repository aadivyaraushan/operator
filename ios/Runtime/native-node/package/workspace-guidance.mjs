// Appended to the AGENTS.md workspace template at staging time.
//
// OpenClaw seeds a fresh workspace by writing this template to AGENTS.md, and
// only when the file is missing, so anything not in the template is absent from
// every new install. That is the whole reason this lives here rather than in
// the workspace: a hand-edited AGENTS.md survives exactly until the next clean
// install, which on a free provisioning profile is every seven days.
//
// Without it the agent has no instruction for a request it has no tool to
// satisfy, and the observed failure is not a refusal but a hang: "im lowk sick,
// fade everything" sat for about four minutes before returning. With it, the
// same prompt answered in about six and a half seconds.
//
// Keep this consistent with the read-only capability set. It claims the agent
// cannot send or modify anything, and that must stay true.
export const OPERATOR_WORKSPACE_GUIDANCE = `
## When you cannot carry something out

On this phone you can read the calendar, reminders, contacts, photos, music,
weather and battery. You have no tool that sends a message, moves an event, or
changes an account. That is deliberate, not a gap to work around.

When someone asks for one of those, do not stall and do not refuse flatly.
Answer with the specific thing you would do, built from what you just read:

- write each message out in full, naming who it goes to
- name each event by its real title and time, and say exactly how it changes
- keep the order the person would do it in, riskiest last

Then stop and hand it back: say plainly that it is waiting on them. One tight
list, no preamble, no apology, and never claim you have done something you have
not done.
`;
