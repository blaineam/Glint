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
//   ui    — GlintUITests (XCUITest) against Glint.app in its DEBUG-only -UITestMode
//           (Glint/Sources/App/UITestMode.swift): fixture DDC monitors + fake CoreAudio,
//           throwaway defaults suite, no event tap, stubbed Accessibility, recorded URLs.
//           Covers the menu-bar content, simulated media keys + OSD, Settings (window and
//           SwiftUI scene), Support window, the real status item/popover, invisible mode +
//           LaunchServices reopen, and the Accessibility alert. Debug builds use the
//           com.blainemiller.Glint.debug bundle ID, so the installed Glint is never touched.
//           Must run from a terminal with the Developer Tools privilege (Terminal.app has
//           it): otherwise Gatekeeper kills the locally built XCUITest runner at launch
//           ("Early unexpected exit … signal kill").
//   l10n  — node --test: Localizable.xcstrings completeness + format specifiers in all
//           8 languages, and docs/i18n dictionary parity with the pages (9 locales).
//   web   — node --check on the site's i18n runtime.
//
// Still manual (window server / hardware bound): IOKit port enumeration and real I2C,
// CGEventTap creation and real NX_SYSDEFINED key events, SMAppService.
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
      // The Glint scheme only has GlintTests; this keeps it that way if UI tests are
      // ever added to it.
      extraArgs: ['-only-testing:GlintTests'],
      description: 'GlintTests: DDC protocol, port selection, cache/retry, media keys, preferences, routing',
    },

    ui: {
      type: 'xcodebuild-test',
      platform: 'macos',
      project: 'Glint.xcodeproj',
      scheme: 'GlintUITests',
      destination: 'platform=macOS,arch=arm64',
      xcodegen: true,
      derivedDataPath: '/tmp/soren-dd-glint-ui',
      description: 'GlintUITests: menu-bar popover, media keys + OSD, Settings, Support, status item, invisible mode, permission alert (DEBUG -UITestMode fixtures)',
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
