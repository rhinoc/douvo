import XCTest
@testable import Douvo

final class TextInputFocusCheckTests: XCTestCase {
    func testKnownTextInputRolesAreAcceptedWithoutCurrentTextValue() {
        XCTAssertEqual(
            TextInputFocusCheck.classification(
                role: "AXTextArea",
                hasTextValue: false,
                hasTextSelectionAttribute: false
            ),
            .textInput
        )
        XCTAssertEqual(
            TextInputFocusCheck.classification(
                role: "AXTextField",
                hasTextValue: false,
                hasTextSelectionAttribute: false
            ),
            .textInput
        )
        XCTAssertEqual(
            TextInputFocusCheck.classification(
                role: "AXComboBox",
                hasTextValue: false,
                hasTextSelectionAttribute: false
            ),
            .textInput
        )
    }

    func testTextValueOrSelectionAttributesAreAcceptedForAppSpecificTextControls() {
        XCTAssertEqual(
            TextInputFocusCheck.classification(
                role: "AXWebArea",
                hasTextValue: true,
                hasTextSelectionAttribute: false
            ),
            .textInput
        )
        XCTAssertEqual(
            TextInputFocusCheck.classification(
                role: "AXGroup",
                hasTextValue: false,
                hasTextSelectionAttribute: true
            ),
            .textInput
        )
    }

    func testEditableAttributeIsAcceptedForCustomControls() {
        XCTAssertEqual(
            TextInputFocusCheck.classification(
                role: "AXGroup",
                isEditable: true,
                hasTextValue: false,
                hasTextSelectionAttribute: false
            ),
            .textInput
        )
    }

    func testUnconfirmedCustomEditorContainersAreAllowedAsPossibleTextInput() {
        XCTAssertEqual(
            TextInputFocusCheck.classification(
                role: "AXWebArea",
                hasTextValue: false,
                hasTextSelectionAttribute: false
            ),
            .possibleTextInput(reason: "unconfirmed_editable_container")
        )
        XCTAssertEqual(
            TextInputFocusCheck.classification(
                role: "AXGroup",
                hasTextValue: false,
                hasTextSelectionAttribute: false
            ),
            .possibleTextInput(reason: "unconfirmed_editable_container")
        )
        XCTAssertEqual(
            TextInputFocusCheck.classification(
                role: "unknown",
                hasTextValue: false,
                hasTextSelectionAttribute: false
            ),
            .possibleTextInput(reason: "unconfirmed_editable_container")
        )
    }

    func testNonTextControlsAreRejected() {
        XCTAssertEqual(
            TextInputFocusCheck.classification(
                role: "AXButton",
                hasTextValue: false,
                hasTextSelectionAttribute: false
            ),
            .notTextInput
        )
    }
}
