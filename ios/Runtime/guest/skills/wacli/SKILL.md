---
name: wacli
description: "Use the bundled wacli CLI for user-requested WhatsApp account linking, history discovery, or a confirmed third-party message."
homepage: https://wacli.sh
metadata: { "openclaw": { "emoji": "📱", "requires": { "bins": ["wacli"] } } }
---

# wacli

Use this skill only when the user asks to link a WhatsApp account, discover WhatsApp history, or message another person on WhatsApp. This native-chat app does not automatically route WhatsApp conversations.

## Consent and sending

- Require explicit account-linking consent before running `wacli auth`.
- Require an explicit recipient and exact message text.
- Ask for a final confirmation that repeats both recipient and message immediately before `wacli send text`.
- Do not send if the recipient, group, message text, or confirmation is unclear.
- Skill instructions guide the agent; they are not an enforced security boundary.

## Verified CLI commands

These commands and flags are from the pinned wacli 0.17.1 source instructions. Do not add package installers, substitute another client, or use unverified flags.

- Check local CLI readiness: `wacli doctor`
- Link only after the consent above: `wacli auth`
- Find a recipient only after account linking: `wacli chats list --limit 20 --query "name or number"`
- Send only after the final confirmation: `wacli send text --to "+14155551212" --message "Hello! Are you free at 3pm?"`

The linked account, history sync, recipient discovery, and message delivery are not tested by this package check. This skill adds discoverable CLI instructions; it does not add automatic WhatsApp conversation routing to native chat.
