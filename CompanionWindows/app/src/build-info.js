'use strict';
const file = require('./build-info.json');

/**
 * Which release this build believes it is, and which repo to ask about it.
 *
 * `build-info.json` is rewritten by CI to the exact tag it is about to publish (see
 * .github/workflows/build.yml). A local build leaves it at the committed `"dev"`, which
 * disables both the updater and the PCVR bundle download — correct, because a dev build has no
 * release of its own and nothing sensible to compare against.
 *
 * Correct, and untestable: every interesting path in updater.js and pcvr-installer.js is behind
 * that check, so on a dev machine they are all dead code. Hence the overrides — point a local
 * build at a real tag and the whole flow runs for real (a real GitHub lookup, a real download,
 * a real signature check against the pinned signers), which is the only way to exercise it
 * short of cutting a release per change:
 *
 *   set LONGWAVE_BUILD_VERSION=0.1.0-abc12345    # pretend to be that release
 *   set LONGWAVE_BUILD_REPO=illixion/Longwave    # or a fork, to test against your own releases
 *
 * Read from the environment rather than by editing the JSON, so testing this cannot end with an
 * uncommitted version string being built into a real installer. They are also deliberately
 * *only* an identity: nothing here can disable a signature check or trust a different key.
 */
module.exports = {
  version: process.env.LONGWAVE_BUILD_VERSION || file.version,
  repo: process.env.LONGWAVE_BUILD_REPO || file.repo,
  /** True when this build has no release identity of its own — a local, unreleased build. */
  isDev: (process.env.LONGWAVE_BUILD_VERSION || file.version) === 'dev',
};
