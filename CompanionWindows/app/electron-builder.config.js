'use strict';
const fs = require('fs');
const path = require('path');

// This file is committed to the public repo and runs the same way in CI and in a local
// build. It only *decides* whether to stage the closed-source PCVR host's publish output
// alongside the public backend's — it never assumes that output exists. CI's checkout has
// no Longwave-PCVR-Host submodule content built (the submodule reference is present in
// history but nothing initializes/builds it there), so hasPcvrHost is false and the CI
// installer is exactly what it always was: hotspot + native streaming, nothing closed-source.
// A local build with the submodule checked out and published picks it up automatically.
const pcvrHostPublish = path.join(
  __dirname, '..', 'Longwave-PCVR-Host', 'bin', 'Release', 'net8.0-windows10.0.22621.0', 'publish');
const hasPcvrHost = fs.existsSync(pcvrHostPublish);

const extraResources = [
  {
    from: '../backend/bin/Release/net8.0-windows10.0.22621.0/publish',
    to: 'backend',
    filter: ['**/*'],
  },
  // The licences window reads the repository's own notices file rather than a copy kept
  // under src/. OpenPGP.js is LGPL, so this is a compliance artifact, and a second copy
  // that silently drifts from the first would make the app's claim about its own
  // dependencies false. One file, staged — see src/main.js noticesPath().
  {
    from: '../THIRD_PARTY_NOTICES.md',
    to: 'THIRD_PARTY_NOTICES.md',
  },
];

if (hasPcvrHost) {
  extraResources.push({
    from: '../Longwave-PCVR-Host/bin/Release/net8.0-windows10.0.22621.0/publish',
    to: 'pcvr-host',
    filter: ['**/*'],
  });
}

module.exports = {
  appId: 'com.illixion.LongwaveCompanion',
  productName: 'Longwave Companion',
  directories: {
    output: 'dist',
    buildResources: 'buildResources',
  },
  // node_modules/** is needed now that there's a real runtime dependency (openpgp, for
  // verifying the PCVR bundle's signature) — before this there were none, so the narrower
  // src/**/* pattern was enough.
  files: ['src/**/*', 'node_modules/**'],
  extraResources,
  win: {
    target: ['nsis'],
    requestedExecutionLevel: 'asInvoker',
  },
  nsis: {
    oneClick: false,
    perMachine: true,
    allowElevation: true,
    createDesktopShortcut: true,
    include: 'buildResources/installer.nsh',
  },
};
