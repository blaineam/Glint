// soren.config.mjs — QA suites for Glint.
//
// Run locally:   node ../_shared/soren/soren.mjs run Glint
//                node ../_shared/soren/soren.mjs doctor Glint
//
// Soren (🦉, the QA counterpart to Rocket) lives in _shared/soren and is pluggable
// per project via this file. See _shared/soren/docs/config.md for every field.
//
// ── Why there is exactly ONE build-only suite here ────────────────────────────
// `xcodebuild -list -project Glint.xcodeproj` reports a single target and a
// single scheme, both named `Glint`, and project.yml declares no test target.
// Glint HAS NO XCTest bundle. Rather than list a test suite that would run
// nothing and report green — which is worse than no gate, because a release
// would be gated on a suite that can't fail — the honest gate is that the app
// still compiles cleanly on the macOS destination. This is the same pattern
// Haven uses for its HavenMac scheme.
//
// Glint is also close to untestable in XCTest as it stands: its whole job is
// side effects on hardware and on the window server — a CGEventTap on media
// keys (needs Accessibility permission), I2C DDC/CI writes to a physically
// attached monitor, and private DisplayServices brightness calls resolved at
// runtime via dlopen/dlsym. A real suite would need DDCService and the
// DisplayServices shim factored behind injectable protocols first; until that
// refactor lands, do not add a suite here that only asserts on a mock of code
// that does not exist yet.
//
// `root` defaults to this file's directory (the Glint repo).
export default {
  name: 'Glint',
  suites: {
    // ── Compile gate. Warnings are not errors in this project, so this catches
    //    hard breakage only — chiefly the dlsym/IOKit/CoreAudio call sites and
    //    the Swift-concurrency annotations around the event-tap C callback.
    //
    //    NOTE: Glint is DELIBERATELY unsandboxed (Glint/Resources/Glint.entitlements
    //    sets com.apple.security.app-sandbox = false) and is distributed as a
    //    notarized direct download, NOT via the Mac App Store. This suite must
    //    never be "fixed" by forcing sandboxing on — that would break the app's
    //    core function. The runner passes CODE_SIGNING_ALLOWED=NO, which leaves
    //    the project's own signing and entitlement setup untouched.
    build: {
      type: 'xcodebuild-test',
      action: 'build',
      platform: 'macos',
      project: 'Glint.xcodeproj',
      scheme: 'Glint',
      destination: 'platform=macOS',
      description: 'Glint compiles on macOS (no test target exists — see the note above)',
    },
  },

  // No data model, no persistence format to migrate, and no test bundle: the
  // compile gate is all `soren migrate Glint` can honestly assert.
  migration: ['build'],

  release: { requireGreen: ['build'] },
};
