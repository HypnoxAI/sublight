# Security Policy

Sublight makes no network calls, collects nothing, and runs entirely locally —
so its security surface is small, but not zero: it loads a private Apple
framework at runtime and ships a CLI that drives keyboard hardware.

**Reporting.** Please use GitHub's private vulnerability reporting on this
repository (Security tab → "Report a vulnerability") rather than a public
issue. Reports are read by the maintainers at Hypnox Technologies.

**Scope worth reporting:** anything that lets a non-admin process abuse the
bridge beyond backlight control, injection into the build scripts, or a way the
app could be made to touch the network.

**Out of scope:** the private-API dependency itself (documented and
deliberate), and Apple breaking the API in a macOS update (expected; the app
degrades gracefully).
