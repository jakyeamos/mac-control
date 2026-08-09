import XCTest
@testable import MacCtlCore

final class IdealStateTests: XCTestCase {
    func testApplicableManifestRequiresAllIdealStateFields() {
        let task = MacControlIdealStateTask(
            taskID: "open-settings",
            stableTargetID: "fixture.settings",
            hierarchy: "Window > Settings",
            semanticAction: "press settings button",
            observablePostcondition: "Settings is visible",
            observableStates: ["enabled", "focused", "selected", "expanded", "visible", "loading", "completed"],
            navigationStrategy: "semantic target lookup",
            eligibleRoutes: ["accessibility", "keyboard"],
            selectedRoute: "accessibility",
            changeStates: ["loading", "modal", "disabled", "permission_unavailable"],
            accessibility: AccessibilityAuditControl(
                identifier: "fixture.settings",
                role: "AXButton",
                requiredActions: ["AXPress"]
            )
        )
        let manifest = MacControlIdealStateManifest(
            schema: "mac-control-task-manifest/v1",
            repositoryID: "repo-fixture",
            repositoryName: "fixture",
            applicability: "applicable",
            applicabilityReason: "The fixture exposes a supported task.",
            app: MacControlIdealStateApplication(name: "Fixture App"),
            criteria: Dictionary(uniqueKeysWithValues: MacControlIdealStateManifestValidator.criteria.map { ($0, true) }),
            tasks: [task]
        )

        let validation = MacControlIdealStateManifestValidator.validate(manifest)

        XCTAssertTrue(validation.valid)
        XCTAssertEqual(validation.taskIDs, ["open-settings"])
        XCTAssertEqual(validation.producer, "mac-control")
    }

    func testValidatorRejectsSequentialTabbingAndMissingState() {
        let manifest = MacControlIdealStateManifest(
            schema: "mac-control-task-manifest/v1",
            repositoryID: "repo-fixture",
            repositoryName: "fixture",
            applicability: "applicable",
            applicabilityReason: "The fixture exposes a supported task.",
            app: MacControlIdealStateApplication(name: "Fixture App"),
            criteria: Dictionary(uniqueKeysWithValues: MacControlIdealStateManifestValidator.criteria.map { ($0, true) }),
            tasks: [MacControlIdealStateTask(
                taskID: "open-settings",
                stableTargetID: "fixture.settings",
                hierarchy: "Window > Settings",
                semanticAction: "press settings button",
                observablePostcondition: "Settings is visible",
                observableStates: ["enabled"],
                navigationStrategy: "sequential_tabbing",
                eligibleRoutes: ["accessibility"],
                selectedRoute: "accessibility",
                changeStates: ["loading", "modal", "disabled", "permission_unavailable"]
            )]
        )

        let validation = MacControlIdealStateManifestValidator.validate(manifest)

        XCTAssertFalse(validation.valid)
        XCTAssertTrue(validation.errors.contains { $0.contains("sequential tabbing") })
        XCTAssertTrue(validation.errors.contains { $0.contains("observable_states is missing completed") })
    }

    func testSearchShortcutManifestRequiresKeyboardAndStructuralSearchField() {
        let criteria = Dictionary(
            uniqueKeysWithValues: MacControlIdealStateManifestValidator.criteria.map { ($0, true) }
        )
        let searchTask = MacControlIdealStateTask(
            taskID: "search-items",
            stableTargetID: "fixture.search",
            hierarchy: "Window > Search field > Repeated list",
            semanticAction: "search",
            observablePostcondition: "search_field_focused",
            observableStates: ["enabled", "focused", "selected", "expanded", "visible", "loading", "completed"],
            navigationStrategy: "search_shortcut",
            eligibleRoutes: ["keyboard"],
            selectedRoute: "keyboard",
            changeStates: ["loading", "modal", "disabled", "permission_unavailable"],
            accessibility: AccessibilityAuditControl(
                identifier: "fixture.search",
                role: "AXTextField",
                subrole: "AXSearchField"
            )
        )
        let base = MacControlIdealStateManifest(
            schema: "mac-control-task-manifest/v1",
            repositoryID: "repo-fixture",
            repositoryName: "fixture",
            applicability: "applicable",
            applicabilityReason: "The fixture exposes a supported search task.",
            app: MacControlIdealStateApplication(name: "Fixture App"),
            criteria: criteria,
            tasks: [searchTask]
        )

        XCTAssertTrue(MacControlIdealStateManifestValidator.validate(base).valid)

        let missingKeyboard = MacControlIdealStateTask(
            taskID: searchTask.taskID,
            stableTargetID: searchTask.stableTargetID,
            hierarchy: searchTask.hierarchy,
            semanticAction: searchTask.semanticAction,
            observablePostcondition: searchTask.observablePostcondition,
            observableStates: searchTask.observableStates,
            navigationStrategy: searchTask.navigationStrategy,
            eligibleRoutes: ["accessibility"],
            selectedRoute: "accessibility",
            changeStates: searchTask.changeStates,
            accessibility: searchTask.accessibility
        )
        let missingTarget = MacControlIdealStateTask(
            taskID: "search-without-target",
            stableTargetID: searchTask.stableTargetID,
            hierarchy: searchTask.hierarchy,
            semanticAction: searchTask.semanticAction,
            observablePostcondition: searchTask.observablePostcondition,
            observableStates: searchTask.observableStates,
            navigationStrategy: searchTask.navigationStrategy,
            eligibleRoutes: searchTask.eligibleRoutes,
            selectedRoute: searchTask.selectedRoute,
            changeStates: searchTask.changeStates
        )

        let invalid = MacControlIdealStateManifest(
            schema: base.schema,
            repositoryID: base.repositoryID,
            repositoryName: base.repositoryName,
            applicability: base.applicability,
            applicabilityReason: base.applicabilityReason,
            app: base.app,
            criteria: criteria,
            tasks: [missingKeyboard, missingTarget]
        )
        let validation = MacControlIdealStateManifestValidator.validate(invalid)

        XCTAssertFalse(validation.valid)
        XCTAssertTrue(validation.errors.contains { $0.contains("requires keyboard in eligible_routes") })
        XCTAssertTrue(validation.errors.contains { $0.contains("requires selected_route keyboard") })
        XCTAssertTrue(validation.errors.contains { $0.contains("requires Accessibility metadata") })
    }

    func testAccessibilityAuditControlPreservesSearchSubrole() throws {
        let control = AccessibilityAuditControl(
            identifier: "fixture.search",
            role: "AXTextField",
            subrole: "AXSearchField"
        )

        let roundTripped = try JSONCodec.decode(
            AccessibilityAuditControl.self,
            from: JSONCodec.encode(control)
        )

        XCTAssertEqual(roundTripped, control)
    }

    func testManifestUsesRepositoryContractSnakeCaseKeys() throws {
        let data = Data(
            "{\"schema\":\"mac-control-task-manifest/v1\",\"repository_id\":\"repo\",\"repository_name\":\"fixture\",\"applicability\":\"not_applicable\",\"applicability_reason\":\"No supported Mac app\",\"criteria\":{},\"tasks\":[]}".utf8
        )

        let manifest = try JSONCodec.decode(MacControlIdealStateManifest.self, from: data)

        XCTAssertEqual(manifest.repositoryID, "repo")
        XCTAssertEqual(manifest.applicability, "not_applicable")
        XCTAssertTrue(MacControlIdealStateManifestValidator.validate(manifest).valid)
    }
}
