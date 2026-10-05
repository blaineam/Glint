// soren.config.mjs — QA suites for Glint.
//
// Run locally:   node ../_shared/soren/soren.mjs run Glint
//                node ../_shared/soren/soren.mjs doctor Glint
//
// Soren (🦉, the QA counterpart to Rocket) lives in _shared/soren and is pluggable
// per project via this file. See _shared/soren/docs/config.md for every field.
//
// ── Suites ────────────────────────────────────────────────────────────────────
//   build — compile gate for the shipping app (no tests run).
//   unit  — GlintTests (XCTest, hosted in Glint.app). The hardware edges sit behind
//           seams: DDC packets/reply parsing (DDCPacket), port ordering (DDCPortSelection),
//           cache/retry policy over a fake DDCTransport + fake clock, media-key routing
//           (MediaKeyInterceptor.action), Preferences in a throwaway UserDefaults suite,
//           and DisplayManager over fake CoreAudio / display environment. AppDelegate
//           returns early under XCTest, so no event tap or Accessibility alert.
//   l10n  — node --test: Localizable.xcstrings completeness + format specifiers in all
//           8 languages, and docs/i18n dictionary parity with the pages (9 locales).
//   web   — node --check on the site's i18n runtime.
//
// Still manual (window server / hardware bound): IOKit port enumeration and real I2C,
// CGEventTap creation, SMAppService, the SwiftUI menu-bar / Settings views.
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
      description: 'Glint compiles on macOS',
    },

    unit: {
      type: 'xcodebuild-test',
      platform: 'macos',
      project: 'Glint.xcodeproj',
      scheme: 'Glint',
      destination: 'platform=macOS,arch=arm64',
      xcodegen: true,
      derivedDataPath: '/tmp/soren-dd-glint-unit',
      description: 'GlintTests: DDC protocol, port selection, cache/retry, media keys, preferences, routing',
    },

    l10n: {
      type: 'cmd',
      cmd: 'node',
      args: ['--test', 'Scripts/tests/*.test.mjs'],
      description: 'xcstrings complete in 8 languages + website i18n key parity (9 locales)',
    },

    web: {
      type: 'node-check',
      files: ['docs/i18n/'],
      description: 'website i18n runtime parses',
    },
  },

  // The only persisted state is UserDefaults; the unit suite covers defaults
  // registration and the pre-1.5 upgrade (no step keys → 6.25 %).
  migration: ['build', 'unit'],

  release: { requireGreen: ['build', 'unit', 'l10n'] },
};
