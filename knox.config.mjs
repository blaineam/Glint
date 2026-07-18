// Knox 🦊 audit config for Glint — a ~1 MB macOS menu-bar utility that
// intercepts the Mac's brightness/volume/mute media keys and re-targets them at
// external displays over DDC/CI (I2C), plus system audio via CoreAudio.
// Resolved by `knox audit Glint`. Lives WITH the repo so the audit surface
// travels with the code.
//
// Glint has no accounts, no network code, no server, and no user data beyond a
// handful of UserDefaults toggles. Its entire security weight sits in the
// ELEVATED CAPABILITIES it needs in order to work at all:
//
//   • a global CGEventTap on keyDown/keyUp/NSSystemDefined (Accessibility
//     permission) — the same primitive a keylogger uses,
//   • private/undocumented APIs resolved at runtime with dlopen/dlsym:
//     DisplayServicesGetBrightness/SetBrightness, and IOAVService*I2C on
//     Apple Silicon (IOFramebuffer I2C on Intel),
//   • no App Sandbox at all (Glint/Resources/Glint.entitlements sets
//     com.apple.security.app-sandbox = false),
//   • SMAppService login-item registration.
//
// The audit question is therefore NOT "should it have these?" — it should, and
// that is settled below in acceptedRisks. The question is: can anything other
// than Glint's own intended feature get at them?

import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// Knox reads `contextDocs` entries against the CWD it happens to be launched
// from, not against `root` — so resolve them here and hand it absolute paths.
const HERE = dirname(fileURLToPath(import.meta.url));
const doc = (p) => join(HERE, p);

export default {
  project: 'Glint',
  root: '.',

  scope: [
    // ── The event tap. Glint sees EVERY keyDown/keyUp the tap is installed for,
    //    not just media keys. What it does with the non-media ones — and
    //    whether any of them can reach a log, disk, or another process — is the
    //    single most important thing in this repo.
    'Glint/Sources/Services/MediaKeyInterceptor.swift',

    // ── Raw I2C writes to whatever monitor is plugged in, via a private IOKit
    //    interface, with hand-rolled DDC/CI framing and checksums.
    'Glint/Sources/Services/DDCService.swift',

    // ── Private DisplayServices resolution + CoreAudio device manipulation.
    'Glint/Sources/Services/DisplayManager.swift',

    // ── Where anything observed could end up on disk.
    'Glint/Sources/Services/DebugLogger.swift',

    // ── Login-item registration and the settings that gate interception.
    'Glint/Sources/Services/Preferences.swift',
    'Glint/Sources/App/GlintApp.swift',
    'Glint/Sources/Views/SettingsView.swift',
    'Glint/Sources/Views/MenuBarView.swift',
    'Glint/Sources/Services/OSDOverlay.swift',

    // ── The posture itself, so the audit reads it rather than assumes it.
    'Glint/Resources/Glint.entitlements',
  ],

  focusAreas: [
    'privacy',          // an event tap is a keystroke firehose
    'platform',         // entitlements, hardened runtime, TCC/Accessibility, login items
    'memory-safety',    // dlsym'd C function pointers + raw I2C buffers
    'input-validation', // DDC replies are attacker-influenced bytes from a monitor
    'authz',            // who can turn interception on, and what a login item runs
    'business-logic',
  ],

  threatModel: `
    What Glint is: a local, network-less, single-user menu-bar utility. There is
    no server, no account, no credential, and no remote attacker. The realistic
    threats are all about Glint's elevated LOCAL capabilities leaking, being
    logged, or being borrowed.

    Attacker capabilities:
      - THE MACHINE'S OWN OTHER SOFTWARE, running as the same user. It cannot
        get Accessibility permission on its own, but Glint HAS it. Anything
        Glint writes down (a debug log), exposes (a file, a UserDefaults key, a
        notification, an IPC endpoint), or executes on someone else's behalf is
        a way to borrow that permission indirectly. Glint is unsandboxed, so
        anything it reads or writes is unconstrained by the sandbox.
      - SOMEONE WITH THE USER'S DISK, or with a copy of a diagnostic log the
        user was asked to send in a bug report. If key events — or anything
        derived from them, like modifier state or key codes — reach
        DebugLogger's on-disk file, a shoulder-surfing-grade capture becomes a
        durable artifact.
      - THE ATTACHED MONITOR. DDC/CI is a two-way I2C bus. A monitor (or a
        hostile dock/KVM/adapter in the middle) returns bytes Glint parses:
        reply framing, length fields, and checksums it did not choose. Those
        bytes are untrusted input into a hand-rolled parser sitting behind raw
        pointers.
      - AN ATTACKER WHO CAN WRITE THE APP'S PREFERENCES or its login-item
        registration. SMAppService.mainApp.register() makes Glint run at every
        login; the audit should confirm nothing but Glint's own code path can
        alter what that registration points at, and that no preference can be
        set to a value that widens interception beyond media keys.
      - A FUTURE macOS in which a dlsym'd private symbol is missing, renamed, or
        returns a differently-shaped result. Glint resolves DisplayServices* and
        IOAVService* symbols at runtime and casts them to @convention(c) types;
        a wrong signature is a memory-safety bug, not a graceful degradation.

    Trust boundaries:
      - Window server ⇄ Glint: the CGEventTap callback runs on every matching
        event system-wide. The boundary is what the callback DOES with an event
        it does not care about — it must pass it through unmodified and retain
        nothing. Events it does claim (media keys) it swallows.
      - Glint ⇄ private frameworks: dlopen/dlsym into DisplayServices and
        IOAVService. Every call is an unchecked C boundary; the code's own
        fallbacks (IOKit brightness, IOFramebuffer I2C) must be exercised, not
        just declared.
      - Glint ⇄ the I2C bus: writes go to physical hardware. Malformed or
        out-of-range VCP writes are a hardware-behaviour risk, and reads come
        back from a device Glint does not control.
      - Glint ⇄ launchd: SMAppService login-item registration.

    Crown jewels:
      - The user's KEYSTROKES. Non-media events must be passed through
        untouched, never inspected beyond what dispatch requires, never
        persisted, never logged, and never leave the process. Anything that
        weakens this is the highest-severity finding available in this repo.
      - The integrity of the Accessibility grant: Glint must not become a way
        for another process to get keyboard events, synthesize them, or have
        code run inside Glint (no plug-ins, no loadable bundles, no eval-shaped
        input, no unexpected IPC endpoint).
      - Memory safety across every dlsym'd call and every raw I2C buffer —
        pointer casts, fixed-size buffers, and length fields taken from a
        DDC reply.
      - What the login item runs, and that it cannot be repointed.
  `,

  acceptedRisks: [
    {
      id: 'accepted.no-sandbox',
      note: 'Glint is INTENTIONALLY not sandboxed (com.apple.security.app-sandbox = false) and is INTENTIONALLY not on the Mac App Store — it is distributed as a notarized direct download. A sandboxed process cannot install a CGEventTap, cannot reach IOAVService/IOFramebuffer for I2C, and cannot call DisplayServices; the App Store would reject the app for the private APIs regardless. This is a settled product decision. Do NOT report "the app is not sandboxed", "consider App Sandbox", or "this cannot ship on the MAS" as findings — they are noise on every run. DO report anything that lets a THIRD PARTY reach these capabilities through Glint.',
    },
    {
      id: 'accepted.private-apis',
      note: 'Use of private/undocumented APIs — DisplayServicesGetBrightness / DisplayServicesSetBrightness and IOAVServiceCreate / IOAVServiceWriteI2C / IOAVServiceReadI2C — is deliberate and is the ONLY way to do hardware DDC brightness and volume on macOS. They are resolved defensively at runtime via dlopen/dlsym with documented IOKit fallbacks precisely so an OS change degrades instead of crashing. Do NOT report "uses private API", "may break on future macOS", or "may be rejected by App Review". DO report unsafe consequences of that style: a wrong @convention(c) signature, an unchecked nil handle, a missing return-code check, or a fallback path that is unreachable or itself unsafe.',
    },
    {
      id: 'accepted.accessibility-event-tap',
      note: 'Requiring Accessibility permission for a global CGEventTap is inherent to the product — intercepting media keys is what Glint IS. Do not report the existence of the tap, or the breadth of the requested event mask, as a vulnerability in itself. DO report how the tap behaves: any inspection, retention, copying, logging, or forwarding of non-media events; any failure to pass through events Glint does not claim; and any way the tap can be enabled or its handler influenced from outside the app.',
    },
    {
      id: 'accepted.disable-library-validation-absent',
      note: 'Glint deliberately loads NO third-party plug-ins and does not disable library validation. If the audit finds a code path that would load external code into this unsandboxed, Accessibility-privileged process, that is a HIGH-severity finding, not an accepted risk.',
    },
    {
      id: 'accepted.userdefaults-prefs',
      note: 'Glint stores only non-sensitive UI toggles (step sizes, which keys to intercept, menu-bar visibility, launch-at-login, debug-logging flag) in UserDefaults.standard. Plain UserDefaults is appropriate for these; there are no secrets to protect. Do not recommend Keychain for them. DO flag any preference whose value changes what code runs or widens interception.',
    },
    {
      id: 'accepted.maker-holds-no-keys',
      note: 'Per the Kith security mandate governing all of these apps, the maker must never be a bypass target. Glint has no backend and no telemetry; anything that introduces a maker-reachable channel into a user machine — an update path that executes code, a remote log sink, a beacon — is IN scope, not accepted.',
    },
  ],

  // README.md documents the intended behaviour (which keys are claimed, when
  // interception is active, the DDC/CoreAudio split) — audit the code against it.
  contextDocs: [doc('README.md')],
};
