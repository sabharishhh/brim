# Security policy

Brim removes files and can run a process with administrator rights for a
removal you approve, so security problems matter more here than in most
apps.

## Supported versions

Only the latest release receives fixes.

## Reporting a vulnerability

Please do not open a public issue. Use **Report a vulnerability** on the
repository's [Security tab](https://github.com/sabharishhh/brim/security),
which sends a private report to the maintainer.

Include what you did, what happened, Brim's version and your macOS version.
If you can, include the smallest steps that reproduce it.

You can expect a reply within a week. Once a fix is released, the report is
published as a security advisory, with credit to you if you want it.

## What counts

Anything that lets Brim be made to:

- remove, move or change a file the person did not approve;
- approve a plan without the person approving it in Brim's window;
- run the administrator process for anything other than Brim, or run code
  other than Brim's own helper as root;
- send data anywhere other than the places the README lists.
