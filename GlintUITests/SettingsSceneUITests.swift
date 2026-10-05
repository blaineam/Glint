import XCTest

/// The SwiftUI `Settings` scene (GlintApp). Glint is an LSUIElement app, so its app menu is
/// never on screen, but its Settings… key equivalent (⌘,) still reaches the scene while a
/// Glint window is key.
final class SettingsSceneUITests: GlintUITestCase {
    func testAppMenuSettingsOpensSettingsScene() {
        launch()
        harness.click()
        harness.typeKey(",", modifierFlags: .command)
        let toggle = element("glint.settings.interceptBrightness")
        XCTAssertTrue(toggle.appears(timeout: Self.timeout))
        waitForToggle(toggle, on: true)
        waitForText(element("glint.settings.aboutTitle"), "Glint")
    }
}
