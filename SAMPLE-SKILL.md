---
name: ibmi-react-vite
description: >
  Use when the user wants to scaffold, build, or run a React + Vite application
  in the IBM i PASE IFS environment. Covers creating the project, installing
  Carbon Design System (@carbon/react), patching esbuild for os400 ppc64 BE,
  configuring SCSS themes, and producing a clean production build. Activate
  whenever the user mentions "React on IBM i", "Vite on IBM i", "PASE frontend",
  "Carbon React on IBM i", or hits esbuild platform errors on os400.
---

# React + Vite on IBM i PASE

This skill guides every step of building a React 18 + Vite 4 single-page application
inside PASE on IBM i (os400, ppc64 BE). Follow the steps in order; each section calls
out the exact command, the reason it is needed, and the gotchas that will otherwise
silently break the build or hang the PASE execution channel.

---

## 0 — Gather requirements first

Before writing any files use `ask_followup_question` to confirm:

1. **Screen / page name** — becomes the project directory and Vite `<screen-name>`.
   Must be lowercase-kebab (e.g. `create-order`, `flight-list`).
2. **Target IFS path** — default is `$HOME/flight400-frontend-apps/<screen-name>/`.
   Confirm the parent directory exists or create it with `mkdir -p`.
3. **Carbon version wanted** — default `@carbon/react ^1.x` (v1 = Carbon 11).
4. **Theme** — default `g100` (dark). Other options: `white`, `g10`, `g90`.
5. **Dev-server port** — default `3000`; choose one that is not already in use on the IBM i.

---

## 1 — Check the environment

IBM i PASE does **not** add `/QOpenSys/pkgs/bin` to PATH automatically. Always use
fully-qualified paths and never assume `node`, `npm`, or `npx` are on PATH.

```bash
# /QOpenSys/pkgs/bin/node and /QOpenSys/pkgs/bin/npm are version-agnostic symlinks
# created automatically when any versioned package is installed
# (nodejs18, nodejs20, nodejs22, nodejs24 …).
/QOpenSys/pkgs/bin/node --version   # must be >= 18
/QOpenSys/pkgs/bin/npm  --version   # must be >= 9
```

Run this with `execute_pase_command`. If `/QOpenSys/pkgs/bin/node` is missing, Node
is not installed. Ask the user to install a versioned package — `yum install` does
**not** have a generic `nodejs` meta-package on IBM i; they must pick a specific
version (e.g. `yum install nodejs22.ppc64`). Available versions can be listed with:

```bash
yum search nodejs
```

Choose the highest available version that is >= 18 (nodejs18, nodejs20, nodejs22,
nodejs24 …). Installing any of these creates the `/QOpenSys/pkgs/bin/node` and
`/QOpenSys/pkgs/bin/npm` symlinks automatically.

> **Symptom: `node: No such file or directory`** — This means PATH inheritance is
> broken, not that Node is missing. Fix PATH once in every wrapper script rather than
> modifying installed package files.

---

## 2 — Scaffold with Vite (Non-Interactive)

> **CRITICAL Gotcha — Interactive prompt hangs PASE execution:**
> If the target folder exists or contains files, `npm create vite@4` stops and asks
> `Target directory is not empty. Remove existing files and continue? (y/N)`. Because PASE
> tool execution has no TTY interactive input, this **freezes the agent indefinitely**.
> Always ensure the directory is clear or supply non-interactive arguments:

```bash
cd <parent-dir>
rm -rf <screen-name>
npm create vite@4 <screen-name> -- --template react
```

Accept the defaults — do **not** install yet.

---

## 3 — Write `package.json` (all deps in one shot)

Overwrite the generated `package.json` with the full dependency list before installing,
so a single `npm install` fetches everything:

```json
{
  "name": "<screen-name>",
  "private": true,
  "version": "1.0.0",
  "description": "<description>",
  "type": "module",
  "scripts": {
    "dev":     "ESBUILD_BINARY_PATH=$(node -e \"process.stdout.write(require.resolve('esbuild-wasm/bin/esbuild'))\") vite --host 0.0.0.0 --port <port>",
    "build":   "ESBUILD_BINARY_PATH=$(node -e \"process.stdout.write(require.resolve('esbuild-wasm/bin/esbuild'))\") vite build",
    "preview": "vite preview --host 0.0.0.0 --port 4173"
  },
  "dependencies": {
    "@carbon/icons-react": "^11.0.0",
    "@carbon/react": "^1.0.0",
    "react": "^18.2.0",
    "react-dom": "^18.2.0",
    "sass": "^1.63.6"
  },
  "devDependencies": {
    "@types/react": "^18.2.15",
    "@types/react-dom": "^18.2.7",
    "@vitejs/plugin-react": "^4.0.3",
    "esbuild-wasm": "^0.18.20",
    "vite": "^4.4.5"
  }
}
```

Key points:
- `esbuild-wasm` **must** be a devDependency — it is the WASM-based fallback for
  the native esbuild binary that does not exist on os400 ppc64 BE.
- Use `process.stdout.write(...)` **without** `xargs` in scripts — `xargs` can
  introduce unexpected whitespace or cause the command substitution to freeze in PASE.
- `sass` is required for Carbon SCSS compilation.
- The `dev` and `build` scripts set `ESBUILD_BINARY_PATH` via command substitution.
  This covers the Vite *transform* pipeline, but **not** Vite's internal
  config-bundling step — see Step 5 for the patch that fixes the remaining gap.

---

## 4 — Install dependencies

```bash
cd <project-dir>
npm install --ignore-scripts
```

Always pass `--ignore-scripts`. Without it, esbuild's own `postinstall` tries to
download a native ppc64 BE binary, which either fails or hangs indefinitely on os400.

---

## 5 — Patch esbuild for os400 (CRITICAL — never skip)

This is the single most important step. Vite 4 uses esbuild internally to **bundle
its own `vite.config.js`** before the `ESBUILD_BINARY_PATH` env var is evaluated.
Without this patch every build fails with:

```
Error: Unsupported platform: os400 ppc64 BE
```

### Why the env var alone is not enough

`esbuild/lib/main.js` reads `ESBUILD_BINARY_PATH` at module-load time:

```js
var ESBUILD_BINARY_PATH = process.env.ESBUILD_BINARY_PATH || ESBUILD_BINARY_PATH;
```

The right-hand `ESBUILD_BINARY_PATH` is a **compile-time constant** that esbuild
injects into its own bundle. For the npm package it resolves to `undefined`. When
Vite loads esbuild to bundle the config file, the env var set in the shell does
not survive into the Node.js module scope, so `ESBUILD_BINARY_PATH` stays
`undefined`, esbuild falls through to the platform lookup, and throws for `os400`.

### The fix — write and run `patch-esbuild.cjs`

Write this file to the project root with `write_stream_file`, then run it once:

```js
// patch-esbuild.cjs  — re-run after every npm install
'use strict';
const fs = require('fs');
const wasmPath = require.resolve('esbuild-wasm/bin/esbuild');
const mainPath = require.resolve('esbuild/lib/main.js');
let src = fs.readFileSync(mainPath, 'utf8');
const OLD = 'var ESBUILD_BINARY_PATH = process.env.ESBUILD_BINARY_PATH || ESBUILD_BINARY_PATH;';
const NEW =
  `var ESBUILD_BINARY_PATH = process.env.ESBUILD_BINARY_PATH || ` +
  `(require('os').platform() === 'os400' ? '${wasmPath}' : ESBUILD_BINARY_PATH);`;
if (src.includes(OLD)) {
  fs.writeFileSync(mainPath, src.replace(OLD, NEW));
  console.log('esbuild patched for os400 ->', wasmPath);
} else {
  console.log('pattern not found — already patched or esbuild version changed');
}
```

Run it:

```bash
node patch-esbuild.cjs
```

Verify the patch applied cleanly:

```bash
node -e "require('./node_modules/esbuild/lib/main.js'); console.log('esbuild OK')"
```

> **Re-run `node patch-esbuild.cjs` after every `npm install` or `npm ci`**
> that regenerates `node_modules`, and after any esbuild version bump.
> Do NOT add it to `postinstall` in `package.json` — `--ignore-scripts` would
> prevent it from running and the failure would be silent.

---

## 6 — Write `vite.config.js`

```js
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export default defineConfig({
  plugins: [react()],

  server:  { host: '0.0.0.0', port: <port> },
  preview: { host: '0.0.0.0', port: 4173 },

  css: {
    preprocessorOptions: {
      scss: {
        // Let Sass resolve bare @use '@carbon/*' paths from node_modules
        loadPaths: [path.resolve(__dirname, 'node_modules')],
        // Suppress Sass 1.x deprecation noise from Carbon internals
        quietDeps: true,
        silenceDeprecations: [
          'color-functions',
          'global-builtin',
          'import',
          'legacy-js-api',
        ],
      },
    },
  },

  build: {
    target: 'es2020',
    sourcemap: true,
    rollupOptions: {
      output: {
        // Split Carbon into its own chunks for better browser cache utilisation
        manualChunks: {
          carbon: ['@carbon/react'],
          icons:  ['@carbon/icons-react'],
        },
      },
    },
  },
});
```

Key points:
- `host: '0.0.0.0'` is required so the dev server is reachable from outside the
  IBM i partition (e.g. a developer's browser on the LAN).
- `loadPaths` lets the SCSS compiler find `@carbon/*` without needing `~` tildes.
- Do **not** include `'mixed-decls'` in `silenceDeprecations` — it was removed from
  Sass and listing it produces its own warning.

---

## 7 — Carbon Theme Configuration & Dark Mode Gotchas

### A. SCSS Theme Entry (`src/styles/theme.scss`)

```scss
// ── 1. Set theme BEFORE importing component styles (order is mandatory) ──────
@use '@carbon/react/scss/themes' as themes;
@use '@carbon/react/scss/theme' with (
  $theme: themes.$g100   // swap for $white / $g10 / $g90 as needed
);

// ── 2. All Carbon component styles ───────────────────────────────────────────
@use '@carbon/react/scss/components';

// ── 3. Carbon grid / layout utilities ────────────────────────────────────────
@use '@carbon/react/scss/grid';

// ── App-level resets & Dark theme background enforcement ─────────────────────
*, *::before, *::after { box-sizing: border-box; }

:root {
  color-scheme: dark;
}

html, body, #root {
  height: 100%;
  min-height: 100vh;
  margin: 0;
  background-color: #161616 !important;
  color: #f4f4f4 !important;
  font-family: 'IBM Plex Sans', 'Helvetica Neue', Arial, sans-serif;
}

.cds--content {
  background-color: #161616 !important;
  color: #f4f4f4 !important;
}

.cds--header {
  background-color: #161616 !important;
  border-bottom: 1px solid #393939 !important;
}

.cds--tile {
  background-color: #262626 !important;
}
```

**Critical ordering rule:** `@use '@carbon/react/scss/theme' with ($theme: ...)` must
appear **before** `@use '@carbon/react/scss/components'`. Reversing the order silently
falls back to the white theme regardless of the `$theme` value.

> **Dark mode note:** For `g100` / `g90` themes, adding explicit hex overrides for
> `background-color` and `color` (with `!important`) prevents browser-default white
> backgrounds from bleeding through during initial paint or when Carbon's CSS variables
> are not yet resolved. `color-scheme: dark` also signals the browser to render native
> controls (scrollbars, form inputs) in dark style.

Then import this file as the **first** import in `src/main.jsx`:

```jsx
import './styles/theme.scss';  // MUST be first
import React from 'react';
import ReactDOM from 'react-dom/client';
import App from './App.jsx';
// ...
```

### B. Wrap App in Carbon `<Theme>` (`src/App.jsx`)

SCSS compilation sets Carbon variable defaults, but UI components require React Context
to inherit tokens cleanly. Always wrap the root component in `<Theme>`:

```jsx
import React from 'react';
import { Theme } from '@carbon/react';
import ScreenName from './ScreenName.jsx';

export default function App() {
  return (
    <Theme theme="g100">
      <ScreenName />
    </Theme>
  );
}
```

This ensures Carbon components receive the correct design tokens via React context,
not just CSS variable inheritance.

---

## 8 — Carbon Component and Icon Gotchas

Carbon exports are case-sensitive. A wrong name causes a hard Rollup build error.

### Non-existent component exports

| What you might write | Correct alternative |
|---|---|
| `<Divider />` from `@carbon/react` | Does **not** exist in Carbon 11 — use `<hr className="cds--divider" />` or a CSS border utility |

### Non-existent icon exports

| What you might guess | Correct export name |
|---|---|
| `Airplane`  | `Plane`              |
| `Refresh`   | `Renew`              |
| `Users`     | `UserMultiple` or `UserAvatar` |
| `Check`     | `Checkmark` or `CheckmarkFilled` |
| `Airport`   | `AirlineManageGates` |

Run this snippet to discover correct icon names before writing any import:

```bash
node -e "
const icons = require('./node_modules/@carbon/icons-react/es/index.js');
const names = Object.keys(icons);
['plane','air','user','refresh','renew','check','location','flight'].forEach(term =>
  console.log(term + ':', names.filter(n => n.toLowerCase().includes(term)).slice(0,6).join(', '))
);
"
```

Always verify before writing the import statement.

---

## 9 — Clean up Vite boilerplate

Remove generated files that conflict with the Carbon-based layout:

```bash
rm -f src/index.css src/App.css src/assets/react.svg public/vite.svg
```

Update `index.html`: change `<title>` to match the screen name and remove the
`public/vite.svg` favicon reference.

---

## 10 — Run the build

```bash
npm run build
```

A successful build looks like:

```
✓ 937 modules transformed.
dist/index.html                   0.81 kB │ gzip:   0.44 kB
dist/assets/index-2a7de2f0.css  804.15 kB │ gzip:  86.66 kB
dist/assets/index-ec2d7c0d.js    13.33 kB │ gzip:   4.94 kB
dist/assets/icons-08a3885d.js    18.44 kB │ gzip:   4.08 kB
dist/assets/carbon-ccf7f292.js  413.64 kB │ gzip: 131.92 kB
✓ built in ~24s
```

---

## 11 — Start the dev server in the background (Non-Blocking)

> **CRITICAL — Do NOT use `nohup npm run dev < /dev/null &` on IBM i PASE.**
>
> Although this pattern works on Linux, it **silently fails or causes tool cancellation**
> on IBM i PASE. The root cause: `npm run dev` spawns a subshell to evaluate the
> `ESBUILD_BINARY_PATH=$(node -e "...")` command substitution inside `package.json`.
> That subshell is **not** a child of the `nohup` process and does not inherit the
> `< /dev/null` stdin redirect — its stdin stays tied to the PASE SSH pipe,
> keeping the execution channel open. Bob's tool runner detects the hanging pipe
> and cancels the call.

### The correct pattern: `start-dev.sh`

Always create a `start-dev.sh` launcher script in the project root. It resolves
`ESBUILD_BINARY_PATH` **before** forking, then calls `node_modules/.bin/vite`
directly — bypassing `npm run` and its subshell entirely.

Write these three files with `write_stream_file`.

**`build.sh`** — one-shot production build:

```sh
#!/bin/sh
# build.sh — Production build wrapper for IBM i PASE
export PATH=/QOpenSys/pkgs/bin:/QOpenSys/usr/bin:/usr/bin:/bin
cd /home/<USER>/flight400-frontend-apps/<screen-name>
export ESBUILD_BINARY_PATH=$(/QOpenSys/pkgs/bin/node \
  -e "process.stdout.write(require.resolve('esbuild-wasm/bin/esbuild'))")
/QOpenSys/pkgs/bin/node ./node_modules/.bin/vite build
```

**`dev.sh`** — foreground dev server (used with `nohup … &` by the caller):

```sh
#!/bin/sh
# dev.sh — Vite dev server for IBM i PASE (run via: nohup bash dev.sh > /tmp/vite-dev.log 2>&1 &)
export PATH=/QOpenSys/pkgs/bin:/QOpenSys/usr/bin:/usr/bin:/bin
cd /home/<USER>/flight400-frontend-apps/<screen-name>
export ESBUILD_BINARY_PATH=$(/QOpenSys/pkgs/bin/node \
  -e "process.stdout.write(require.resolve('esbuild-wasm/bin/esbuild'))")
exec ./node_modules/.bin/vite --host 0.0.0.0 --port <port>
```

**`start-dev.sh`** — non-blocking launcher (Bob uses this to start the server as an agent action):

```sh
#!/bin/sh
# start-dev.sh — Non-blocking Vite dev server launcher for IBM i PASE
# Re-run this script any time you need to restart the dev server.
export PATH=/QOpenSys/pkgs/bin:/QOpenSys/usr/bin:/usr/bin:/bin
cd /home/<USER>/flight400-frontend-apps/<screen-name>
export ESBUILD_BINARY_PATH=$(/QOpenSys/pkgs/bin/node \
  -e "process.stdout.write(require.resolve('esbuild-wasm/bin/esbuild'))")
nohup ./node_modules/.bin/vite --host 0.0.0.0 --port <port> \
  > /tmp/vite-<screen-name>.log 2>&1 &
echo $! > /tmp/vite-<screen-name>.pid
echo "Started PID=$(cat /tmp/vite-<screen-name>.pid)"
```

Make all scripts executable:

```bash
chmod +x build.sh dev.sh start-dev.sh
```

**To build:** run `build.sh` directly or via Bob:

```bash
/QOpenSys/pkgs/bin/bash build.sh
```

**To start dev server** (background, non-blocking):

```bash
nohup /QOpenSys/pkgs/bin/bash dev.sh > /tmp/vite-dev.log 2>&1 &
```

Or ask Bob to run `start-dev.sh` — it handles the `nohup` internally.

Check the server came up:

```bash
sleep 4 && cat /tmp/vite-<screen-name>.log
```

A successful start looks like:

```
  VITE v4.5.x  ready in 2999 ms

  ➜  Local:   http://localhost:3000/
  ➜  Network: http://10.3.4.2:3000/
```

> **Port conflict:** If ports 3000–3002 are already in use, Vite auto-increments
> (3001, 3002, 3003 …). Always check the log for the actual bound port and use
> that in the final URL you report to the user.

### Why this works where `npm run dev < /dev/null &` does not

| Approach | Stdin behaviour | Safe? |
|---|---|---|
| `nohup npm run dev < /dev/null &` | `npm` gets `/dev/null`, but its **subshell** for `$(node -e ...)` inherits the original PASE pipe | ❌ Hangs / cancelled |
| `start-dev.sh` with pre-resolved `ESBUILD_BINARY_PATH` + direct `./node_modules/.bin/vite` | No subshell at fork time; `nohup` fully detaches | ✅ Reliable |

### Managing the running server

```bash
# Check if still running
kill -0 $(cat /tmp/vite-<screen-name>.pid) 2>/dev/null && echo "running" || echo "stopped"

# Tail live logs
tail -f /tmp/vite-<screen-name>.log

# Stop the server
kill $(cat /tmp/vite-<screen-name>.pid)
```

---

## PASE Execution Best Practices Quick-Reference

| Problem / Trap | Root Cause | Solution |
|---|---|---|
| **PASE command hangs on `npm create`** | Interactive prompt when directory exists | Always run `rm -rf <dir>` before `npm create` |
| **`nohup npm run dev &` gets cancelled** | `npm run` subshell keeps PASE pipe open | Use `start-dev.sh` — resolve env vars first, call `./node_modules/.bin/vite` directly |
| **Command substitution freeze** | `xargs` buffering in PASE subshells | Use `process.stdout.write(...)` without `xargs` |
| **Script parsing syntax errors** | Inlining multiline bash with JSX quotes via `node -e` | Use `write_stream_file` or `apply_diff` to create the script file first |
| **Port conflict on startup** | Previous Vite instance still listening | Check `/tmp/vite-<screen-name>.log` for the actual bound port |
| **`vite: not found` in shell script** | Shell scripts don't inherit npm PATH | Always use `./node_modules/.bin/vite`, never bare `vite` |

---

## Troubleshooting quick-reference

| Symptom | Root cause | Fix |
|---|---|---|
| `Error: Unsupported platform: os400 ppc64 BE` | esbuild native binary missing | Re-run `node patch-esbuild.cjs` (Step 5) |
| `Cannot find module 'esbuild-wasm/bin/esbuild'` | `esbuild-wasm` not installed | `npm install --ignore-scripts esbuild-wasm@0.18.20` then re-patch |
| `"<Icon>" is not exported by ...@carbon/icons-react` | Wrong icon name | Use Step 8 snippet to find the correct export |
| `Divider` is not exported by `@carbon/react` | `Divider` does not exist in Carbon | Replace with `<hr className="cds--divider" />` |
| SCSS `@use` resolution error for `@carbon/*` | `loadPaths` missing | Add `loadPaths: [path.resolve(__dirname, 'node_modules')]` |
| Carbon renders in **white** despite `$g100` | Theme `@use` is after components or `<Theme>` context is missing | Move theme `@use` **before** `@use components` in `theme.scss` AND wrap in `<Theme theme="g100">` in `App.jsx` |
| `DEPRECATION WARNING [mixed-decls] is obsolete` | Listed in `silenceDeprecations` but removed from Sass | Remove `'mixed-decls'` from the list |
| `DEPRECATION WARNING [legacy-js-api]` floods output | Vite 4 uses Sass legacy JS API | Add `'legacy-js-api'` to `silenceDeprecations` |
| Dev server unreachable from browser | `host` defaults to `localhost` | Set `server: { host: '0.0.0.0' }` in vite config |
| `npm install` hangs or download fails | esbuild/other postinstall scripts run | Always pass `--ignore-scripts` |
| `nohup npm run dev` tool call cancelled by Bob | PASE pipe kept open by npm subshell | Use `start-dev.sh` pattern (Step 11) |
| `node: No such file or directory` in any script | PATH not inherited in PASE shell | Export full PATH at top of every wrapper script (see Step 1) |

---

## Project file checklist

```
<screen-name>/
├── index.html                  ← updated <title>, no vite.svg favicon
├── package.json                ← esbuild-wasm + @carbon/react + sass in deps
├── patch-esbuild.cjs           ← re-runnable os400 esbuild patch script
├── build.sh                    ← production build wrapper (chmod +x, exports PATH)
├── dev.sh                      ← foreground dev server wrapper (chmod +x, exports PATH)
├── start-dev.sh                ← NON-BLOCKING server launcher for Bob (chmod +x)
├── vite.config.js              ← loadPaths + silenceDeprecations + manualChunks
├── node_modules/               ← installed with --ignore-scripts
└── src/
    ├── main.jsx                ← theme.scss imported FIRST
    ├── App.jsx                 ← Wrapped in <Theme theme="g100">
    ├── <ScreenName>.jsx        ← page component using Carbon components
    └── styles/
        └── theme.scss          ← theme @use BEFORE components @use + dark resets
```

## IBM i Node.js Runtime Requirements

These rules apply before any `npm`, `node`, `npx`, or `vite` command:

| Rule | Detail |
|---|---|
| **Never assume PATH** | PASE shells do not inherit `/QOpenSys/pkgs/bin` automatically |
| **Version-agnostic Node binary** | `/QOpenSys/pkgs/bin/node` — symlink maintained by `yum`, works for nodejs18/20/22/… |
| **Version-agnostic npm** | `/QOpenSys/pkgs/bin/npm` |
| **Every wrapper script must export** | `PATH=/QOpenSys/pkgs/bin:/QOpenSys/usr/bin:/usr/bin:/bin` |
| **Diagnosis** | `node: No such file or directory` → PATH broken, not package missing — fix PATH first |
