# Security Policy

Please do not open public issues for security vulnerabilities.

Report privately to **nicolas@gogrow.dev** with a description and reproduction steps.
You'll get an acknowledgment within a few days; fixes are coordinated before disclosure.

Notes for researchers: xeno's threat model is documented in the README's "Security
posture" section and `docs/runtime.md` § Authorization — tool code runs in the host
app by design (no sandbox), sessions are principal-scoped, and HTTP auth fails closed.
Reports about gaps between those documented guarantees and actual behavior are
especially valuable.
