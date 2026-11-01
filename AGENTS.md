# Agent instructions

This repository provides a shell script for mounting removable LUKS devices from a configuration file. Treat encryption parameters, device paths, and unlock material as sensitive.

## Working and validation

- Load the `shell` skill before changing shell code; preserve existing validation and error handling.
- Use placeholders and temporary fixtures. Never test by mounting or modifying a real encrypted device.
- Run shell syntax and lint checks where available, and do not print secret-bearing configuration.
- Before changing GitHub Actions, check whether [pschmitt/ci-workflows](https://github.com/pschmitt/ci-workflows) provides a reusable workflow or action. Preserve current behavior and check coverage, and use `@main` for shared workflow or action references.
