# Agent notes

- Connector QA for the iPhone app: follow `ios/qa/connector-qa/SKILL.md`
  (also exposed to Claude Code as the `connector-qa` skill). It spends real
  ChatGPT turns on the owner's account; read its cost section first.
  Claude Code: `.claude/` is gitignored, so expose the skill locally with
  `mkdir -p .claude/skills && ln -s ../../ios/qa/connector-qa .claude/skills/connector-qa`.
