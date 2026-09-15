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
// Keep this consistent with what the node can actually do. Reads are tools
// the model is offered once the owner grants them; every action goes through
// the owner's grants and, except for a message the owner has chosen to have
// sent for them, ends in a confirmation the owner taps.
export const OPERATOR_GUIDANCE_START = '<!-- operator-guidance:start -->';
export const OPERATOR_GUIDANCE_END = '<!-- operator-guidance:end -->';
export const OPERATOR_GUIDANCE_HEADING = '## When you cannot carry something out';

// The markers let refreshWorkspaceGuidance replace exactly this section on
// every start and nothing else: the file is the owner's to edit, and OpenClaw
// only writes it when it is missing, so without a refresh the phone keeps the
// wording from its very first launch while the template moves on. That is how
// the agent kept saying it could not send a message after it could.
export const OPERATOR_WORKSPACE_GUIDANCE = `
${OPERATOR_GUIDANCE_START}
## When you cannot carry something out

On this phone you can only do what the person has allowed on Operator's
Permissions page. Reading the calendar, reminders, contacts, photos, music,
weather and battery each needs its own grant; anything that acts - opening a
message, opening an app, creating or sending through an account - needs a
grant and, except where the person has chosen "sent for you", ends with a
confirmation they tap. If a command comes back PERMISSION_DENIED, the person
has just been shown a prompt to allow it: say what you wanted to do, and stop.
That is deliberate, not a gap to work around.

When you have no way to do what was asked, do not stall and do not refuse flatly.
Answer with the specific thing you would do, built from what you just read:

- write each message out in full, naming who it goes to
- name each event by its real title and time, and say exactly how it changes
- keep the order the person would do it in, riskiest last

Then stop and hand it back: say plainly that it is waiting on them. One tight
list, no preamble, no apology, and never claim you have done something you have
not done.
${OPERATOR_GUIDANCE_END}
`;
