# Nightshift 1.1 verification — 20 October 2026

Historical entries below use the current Nightshift branding; their original validation scope and limitations still apply.

The application and project have been renamed from AgentCoffee to **Nightshift**. The current bundle is `dist/Nightshift.app`; `dist/Nightshift.zip` packages that bundle. The original release is retained under `.build/previous-release`.

## Verified

- Native Apple Silicon application and separate lid helper compile successfully. Both executable signatures and the app bundle validate; Info.plist and shell installer syntax validate.
- **34 Swift task checks** cover concurrent sessions, independent subagents, questions/answers, approval matching, delayed events, restart serialization, owner identities, bridge reconciliation, and 1,000 simultaneous task identities.
- **21 Swift closed-lid checks** cover journal-before-mutation ordering, last-task restoration, preserving a preexisting disabled-sleep state, crash recovery, failed journal writes, rejected or unconfirmed power changes, restoration retries, power-state resets, heartbeat expiry, owner death, future timestamps, pause/quit release, reboot identity, and preserving surviving work during helper restart.
- **9 Python tests** exercise native hook ingestion/privacy, malformed payloads, hook installer preservation/idempotency/removal, legacy-name migration, native process-startup timing, read-only helper inspection, and rejection of unprivileged helper installation.
- Native hook delivery is approximately 9–10 ms per invocation including startup on this Mac. This is an observed measurement, not a fixed performance guarantee.
- The real IOKit idle-sleep assertion test successfully acquires, holds, and releases an assertion.
- Read-only helper inspection reports the actual IORegistry SleepDisabled state and whether battery level permits protection, without changing either.
- The production red/green/yellow cup drawing was rendered and inspected in the initial build. The drawing is unchanged.
- The new hook installer replaces its own previous AgentCoffee entries while preserving other hooks.

## Privileged behavior not activated here

The administrator installer was **not** run against the real system. This session cannot write `/Library/PrivilegedHelperTools`, `/Library/LaunchDaemons`, `/var/db`, or `/var/run`. No sudoers rules, system power flags, launch daemons, or global agent settings were modified. Tests of privileged power-setting behavior use an injected backend and real lease/state-machine code; they do not prove actual clamshell behavior on this hardware.

The helper, once installed by the user, runs only fixed pmset enable/restore commands. It validates the lease's file ownership, regular-file type, process UID/PID/birth time, timestamp, and request. It saves the original flag in a root-only journal before mutation, verifies readback, and retains the journal on restoration failure. Launchd restarts the helper after failure. A boot identity prevents a previous boot's runtime baseline from being reapplied. A 45-second lease and 5-second owner check limit stale protection. Power-source notifications repair resets. At 15% battery it restores the prior baseline.

The closed-lid mechanism is undocumented and global. While held it also prevents explicit Sleep, and other utilities changing that same flag can conflict. If another utility already had disabled sleep, Nightshift preserves that earlier state.

## Live checks still required

The initial GUI launch was blocked by this environment: Launch Services reported kLSNoExecutableErr, direct launch aborted inside macOS application registration before the app delegate ran, and Computer Use access was denied. Live menu interaction remains unverified. The GUI was not retried to bypass that restriction.

After opening Nightshift normally in Finder, run the bundled closed-lid installer with administrator access. Confirm the menu says **Closed lid: protected — verified by macOS** during a task. Test lid close, connecting/disconnecting power, waiting for input, last-task completion, pause, Quit, and process death. Confirm the saved flag is restored. Reboot and verify the helper remains idle until new work. Only after these checks is replacement of Amphetamine verified on this Mac.

Independent direct hooks still require one-time setup and Codex hook-trust review. Each ChatGPT, Terminal64, VS Code, and CLI runtime must actually emit the events or be covered by the existing ClaudeBar bridge. The bridge inherits ClaudeBar's detection limitations.

## Reproduce

Run `zsh scripts/build.sh` and `zsh scripts/test.sh`. Use `dist/Nightshift.app/Contents/MacOS/Nightshift --power-test` for the ordinary idle-sleep assertion, and `dist/Nightshift.app/Contents/Resources/NightshiftLidHelper --inspect` for read-only closed-lid state inspection. See README.md or the app menu's setup page for administrator installation and removal.

## Menu cleanup — 20 October 2026

The menu now keeps the current status and task counts at the top, with Tasks, Wakefulness, Integrations, and Help & Diagnostics submenus. Task details and ignore actions remain available, and the previous 25-task display limit has been removed. Bridge and closed-lid toggles show checkmarks. The unconfirmed-lid warning now explicitly says the Mac is awake; Wakefulness shows the separate idle-sleep and closed-lid states. Color behavior and wake policies are unchanged.

Rebuilt and signed `dist/Nightshift.app`, refreshed `dist/Nightshift.zip`, and passed all 34 core checks, 21 lid checks, and 9 Python tests. Deep/strict code-signature verification passed. Live menu inspection and restart could not be completed because Computer Use denied access to Nightshift (app access was not approved). Reopen the rebuilt app to load the menu changes.

## Nightshift rebrand — 20 October 2026

The application is now **Nightshift**. Build with `zsh scripts/build.sh`; the current bundle is `dist/Nightshift.app`. The earlier sections above are historical verification records.

- Added the generated navy, ivory, and amber owl mascot at `Resources/NightshiftIcon.png`, embedded it in README.md, and packaged a multi-resolution `Resources/Nightshift.icns` for the app bundle.
- Updated the bundle identity, executable, setup page, menu labels, power-assertion description, build scripts, and documented commands. Replaced the menu bar coffee cup with a native color-coded owl; rendered and visually inspected all three status colors.
- Legacy data, environment aliases, and hook markers are recognized for migration. See the latest verification entry for the current helper identifiers.
- Rebuilt successfully. Passed all 34 Swift core checks, 21 Swift lid checks, and 9 Python tests, including hook migration for both former names. Strict/deep code-signature verification passed. Plist, shell syntax, README local links, and the ICNS container validated; macOS successfully decoded the ICNS into PNG.
- Live menu interaction, privileged installation, and actual lid-close behavior were not retested during the rebrand. Existing live-verification limitations still apply. Hook configuration in the real home directory was not changed.

## Nightshift 1.2 — standalone agent detection

Nightshift's primary integration now runs inside the app and does not require ClaudeBar. The README and bundled setup guide lead with keeping macOS awake while agents work, followed by a single detection setup for Claude Code and Codex across compatible hosts. Other runtimes can use the documented native lifecycle-event adapter.

- Added first-launch and menu-driven setup using the bundled hook installer. Configuration backups and unrelated hooks, including ClaudeBar hooks, are preserved. New configurations default the optional ClaudeBar feed to off; existing explicit settings are preserved.
- Added bounded, incremental JSONL transcript recovery for explicit Claude Code completion/interruption and Codex completion/abort events. Hook events carry only a transcript path, never transcript content. File identity, truncation, partial lines, oversized records, and symlinks are handled explicitly. Recovery is fenced by hook timestamps, turn IDs, and a current snapshot so old records cannot finish newer work. Subagent hooks cannot attach their parent's transcript.
- Existing process-identity checks and independent task/subagent tracking remain in effect. No UI-open or process-open heuristic claims an idle agent is working.
- Passed 34 core Swift checks, 25 new detection/recovery checks, 21 lid Swift checks, and 11 Python tests. Native boundary tests install both providers into an isolated home and deliver events for simulated terminal, editor, and desktop hosts plus a custom provider, without ClaudeBar. Coexistence tests preserve ClaudeBar hooks during setup/removal.
- Rebuilt and ad-hoc signed version 1.2. Strict/deep signature verification, plist and shell checks, README local links, and bundled setup-resource equality passed.

The simulated-host tests validate the local event interface, not live coverage in every third-party host/version. GUI onboarding, real agent hook trust, and lid-close behavior still require live verification. Tests did not modify real agent configuration or install the privileged helper. Runtimes that do not emit compatible events need an adapter; transcript recovery needs a supplied supported path and cannot infer missing starts.

## Dropdown cleanup — 20 October 2026

Removed disabled informational rows from the main menu and its submenus. The dropdown now contains actions and submenu navigation. Status, detection health, power/lid messages, and warnings are available through the actionable “Status & details…” dialog. Per-task metadata is available through “View task details…”. The Tasks submenu appears only when tasks exist. The owl status colors and tooltip remain available.

The app rebuilt successfully and passed strict/deep code-signature verification. This menu-only change did not alter the detection or wakefulness policy. Live menu interaction was not verified in this environment.

## Optional additional detector and fallback — 20 October 2026

The Agent Detection menu exposes “Use ClaudeBar detection (optional)”. Built-in hooks and transcript recovery always remain active, independently of that setting. A missing or unreachable optional detector now immediately reports built-in fallback in Status & details, including a setup reminder when needed. Fresh saved feeds can supplement detection; stale saved files are not newly ingested. Previously reported active work is retained until confirmed finished, its owner exits, or it is dismissed.

Live optional state takes precedence over its saved snapshot, while direct Nightshift events still take precedence for matching sessions. Generation checks prevent callbacks from a previous toggle state from applying after the optional source is changed. Existing optional-detector settings are preserved; new installations default to built-in detection.

Passed 38 core checks, 25 detection/recovery checks, 21 lid checks, and 11 Python tests. Added coverage for supplemental sessions, missing optional sessions, feed return after native completion, and native operation without a feed. The final app rebuilt and passed strict/deep signature verification. Live GUI interaction and external detector connectivity were not exercised. README naming exclusions remain intact.

## Complete Nightshift naming — 20 October 2026

- Renamed the active helper service, runtime directory, and recovery journal to `local.nightshift.lid-helper`, `/var/run/nightshift-lid-<uid>`, and `/var/db/local.nightshift-lid`. The administrator installer restores the previous helper's state before retiring it. Privileged migration was reviewed and syntax checked, but was not run on the system.
- Migrated the local data directory to `dist/Nightshift Data`. Default-data migration preserves existing current data; dry-run setup does not migrate files. Previous names remain only in migration support and its tests.
- Updated cache, temporary-file, backup, and documentation names. Removed obsolete icon resources and moved obsolete generated app, ZIP, and iconset artifacts outside the project into a temporary archive. Rebuilt and signed `dist/Nightshift.app`, and refreshed `dist/Nightshift.zip`.
- Passed 38 core, 25 detection, and 21 closed-lid Swift checks, plus 12 Python tests. The Python tests also passed against the rebuilt executable. Deep/strict signature verification, bundle plist validation, shell syntax checks, ZIP integrity, and diff whitespace checks passed.
- The workspace directory remains `/Users/troynguyen/Caffeine` because renaming it requires write access to its parent outside this session's writable roots. Global hooks, Login Items, and installed privileged services were not modified.
