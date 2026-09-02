<!-- Thanks for contributing! Please keep PRs focused. -->

## What & why

Briefly, what does this change and why?

## Checklist

- [ ] `swift test` passes (the full suite)
- [ ] Code is formatted (`swift format --in-place --recursive MacerodactylKit/Sources MacerodactylKit/Tests`)
- [ ] Added/updated tests for the behavior I changed
- [ ] If I touched the security model (scoping, path confinement, identity, the
      web frontend's DOM building), I kept its properties intact and its tests green
- [ ] Docker access still goes through the CLI with array arguments (no shell interpolation)
- [ ] No new dependency (or I opened an issue to discuss one first)

## Notes for reviewers

Anything worth calling out — trade-offs, follow-ups, things you're unsure about.
