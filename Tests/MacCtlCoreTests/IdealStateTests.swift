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

    func testV2SeparatesTaskSurfaceFromRuntimeRouteSelection() throws {
        let task = MacControlIdealStateTask(
            taskID: "open-settings",
            stableTargetID: "fixture.settings",
            hierarchy: "Window > Settings",
            semanticAction: "open settings",
            observablePostcondition: "Settings is visible",
            observableStates: ["enabled", "visible", "completed"],
            navigationStrategy: "sequential_tabbing",
            changeStates: ["loading", "disabled"],
            accessibility: AccessibilityAuditControl(
                identifier: "fixture.settings",
                role: "AXButton"
            ),
            stateExemptions: [
                "focused": "Opening the panel does not retain focus on the trigger.",
                "selected": "The trigger is not a selectable control.",
                "expanded": "The panel is not represented as an expandable control.",
                "loading": "The task completes synchronously."
            ],
            changeStateExemptions: [
                "modal": "The task never presents a modal.",
                "permission_unavailable": "The task does not require a protected permission."
            ],
            focusPolicy: "foreground",
            foregroundPostcondition: "target_foreground",
            fallbackPolicy: "fresh_state_handoff",
            verificationOracle: MacControlIdealStateVerificationOracle(
                oracleID: "fixture.settings.visible",
                kind: "window_state",
                expectedState: "settings_visible",
                independentReadback: true
            ),
            routeCandidates: [
                MacControlIdealStateRouteCandidate(
                    id: "native-accessibility",
                    provider: "mac_control",
                    method: "accessibility",
                    interactionMode: "semantic"
                ),
                MacControlIdealStateRouteCandidate(
                    id: "computer-use-pointer",
                    provider: "computer_use",
                    method: "pointer",
                    interactionMode: "pointer"
                )
            ]
        )
        let manifest = MacControlIdealStateManifest(
            schema: "mac-control-task-manifest/v2",
            repositoryID: "repo-fixture",
            repositoryName: "fixture",
            applicability: "applicable",
            applicabilityReason: "The fixture exposes a supported task.",
            app: MacControlIdealStateApplication(name: "Fixture App"),
            criteria: Dictionary(uniqueKeysWithValues: MacControlIdealStateManifestValidator.criteria.map { ($0, true) }),
            tasks: [task]
        )

        let validation = MacControlIdealStateManifestValidator.validate(manifest)
        let encoded = String(decoding: try JSONCodec.encode(manifest), as: UTF8.self)

        XCTAssertTrue(validation.valid, validation.errors.joined(separator: "\n"))
        XCTAssertNil(task.selectedRoute)
        XCTAssertTrue(encoded.contains("\"route_candidates\""))
        XCTAssertFalse(encoded.contains("\"selected_route\""))
    }

    func testV2RejectsStaticRouteSelectionAndUnaccountedState() {
        let task = MacControlIdealStateTask(
            taskID: "open-settings",
            stableTargetID: "fixture.settings",
            hierarchy: "Window > Settings",
            semanticAction: "open settings",
            observablePostcondition: "Settings is visible",
            observableStates: ["enabled"],
            navigationStrategy: "semantic target lookup",
            eligibleRoutes: ["accessibility"],
            selectedRoute: "accessibility",
            changeStates: [],
            focusPolicy: "foreground",
            foregroundPostcondition: "target_foreground",
            fallbackPolicy: "none",
            verificationOracle: MacControlIdealStateVerificationOracle(
                oracleID: "fixture.settings.visible",
                kind: "window_state",
                expectedState: "settings_visible",
                independentReadback: true
            ),
            routeCandidates: [MacControlIdealStateRouteCandidate(
                id: "native-accessibility",
                provider: "mac_control",
                method: "accessibility",
                interactionMode: "semantic"
            )]
        )
        let manifest = MacControlIdealStateManifest(
            schema: "mac-control-task-manifest/v2",
            repositoryID: "repo-fixture",
            repositoryName: "fixture",
            applicability: "applicable",
            applicabilityReason: "The fixture exposes a supported task.",
            app: MacControlIdealStateApplication(name: "Fixture App"),
            criteria: Dictionary(uniqueKeysWithValues: MacControlIdealStateManifestValidator.criteria.map { ($0, true) }),
            tasks: [task]
        )

        let validation = MacControlIdealStateManifestValidator.validate(manifest)

        XCTAssertFalse(validation.valid)
        XCTAssertTrue(validation.errors.contains { $0.contains("selected_route is runtime evidence") })
        XCTAssertTrue(validation.errors.contains { $0.contains("route_candidates instead of eligible_routes") })
        XCTAssertTrue(validation.errors.contains { $0.contains("must declare or exempt completed") })
        XCTAssertTrue(validation.errors.contains { $0.contains("must declare or exempt permission_unavailable") })
    }

    func testV3AcceptsBuiltInAndCustomizableShortcutAcceleration() {
        let builtIn = v3Manifest(shortcut: MacControlIdealStateShortcutAcceleration(
            disposition: "built_in_verified",
            commandID: "fixture.open-settings",
            chord: "cmd+,",
            conflictPolicy: "app_managed",
            contextualAvailability: true
        ), includeShortcutRoute: true)
        let customizable = v3Manifest(shortcut: MacControlIdealStateShortcutAcceleration(
            disposition: "customizable_verified",
            commandID: "fixture.open-settings",
            menuPath: ["Fixture", "Open Settings"],
            customizationSurface: "macos_app_shortcut",
            conflictPolicy: "detect_before_assignment",
            contextualAvailability: true,
            reversibleAssignment: true
        ))

        XCTAssertTrue(
            MacControlIdealStateManifestValidator.validate(builtIn).valid,
            MacControlIdealStateManifestValidator.validate(builtIn).errors.joined(separator: "\n")
        )
        XCTAssertTrue(
            MacControlIdealStateManifestValidator.validate(customizable).valid,
            MacControlIdealStateManifestValidator.validate(customizable).errors.joined(separator: "\n")
        )
    }

    func testV3RejectsUnverifiableOrAmbiguousShortcutAcceleration() {
        let invalidCustom = v3Manifest(shortcut: MacControlIdealStateShortcutAcceleration(
            disposition: "customizable_verified",
            commandID: "fixture.open-settings",
            customizationSurface: "macos_app_shortcut",
            conflictPolicy: "detect_before_assignment",
            contextualAvailability: false,
            reversibleAssignment: false
        ))
        let unexplainedExemption = v3Manifest(shortcut: MacControlIdealStateShortcutAcceleration(
            disposition: "not_applicable"
        ))

        let customValidation = MacControlIdealStateManifestValidator.validate(invalidCustom)
        let exemptionValidation = MacControlIdealStateManifestValidator.validate(unexplainedExemption)

        XCTAssertFalse(customValidation.valid)
        XCTAssertTrue(customValidation.errors.contains { $0.contains("contextual_availability true") })
        XCTAssertTrue(customValidation.errors.contains { $0.contains("exact menu_path") })
        XCTAssertTrue(customValidation.errors.contains { $0.contains("reversible_assignment true") })
        XCTAssertFalse(exemptionValidation.valid)
        XCTAssertTrue(exemptionValidation.errors.contains { $0.contains("not_applicable requires reason") })
    }

    func testV4DerivesSemanticDimensionsFromTypedSourceEvidence() {
        let valid = v4Manifest()
        let validResult = MacControlIdealStateManifestValidator.validate(valid)

        XCTAssertTrue(validResult.valid, validResult.errors.joined(separator: "\n"))
        XCTAssertTrue(valid.criteria.isEmpty)

        let selfAttested = MacControlIdealStateManifest(
            schema: valid.schema,
            repositoryID: valid.repositoryID,
            repositoryName: valid.repositoryName,
            applicability: valid.applicability,
            applicabilityReason: valid.applicabilityReason,
            app: valid.app,
            criteria: Dictionary(
                uniqueKeysWithValues: MacControlIdealStateManifestValidator.criteria.map { ($0, true) }
            ),
            tasks: valid.tasks
        )
        let selfAttestedResult = MacControlIdealStateManifestValidator.validate(selfAttested)

        XCTAssertFalse(selfAttestedResult.valid)
        XCTAssertTrue(selfAttestedResult.errors.contains { $0.contains("v4 criteria must be empty") })
    }

    func testV4RejectsSurfaceMismatchGenericOracleAndClonedEvidence() {
        let invalid = v4Manifest(
            surfaceKind: "web_content",
            expectedState: "visible",
            cloneEvidence: true
        )
        let validation = MacControlIdealStateManifestValidator.validate(invalid)

        XCTAssertFalse(validation.valid)
        XCTAssertTrue(validation.errors.contains { $0.contains("web_content requires a browser_connector") })
        XCTAssertTrue(validation.errors.contains { $0.contains("must not claim a native Mac Control route") })
        XCTAssertTrue(validation.errors.contains { $0.contains("machine-checkable value") })
        XCTAssertTrue(validation.errors.contains { $0.contains("criterion-specific, not cloned") })
    }

    func testV4RejectsCrossFieldSpoofingAndNonImplementationSources() {
        let invalid = v4Manifest(
            navigationStrategy: "shortcut",
            claimExpectedState: "different_state",
            readbackProvider: "caller",
            secondaryProvider: "mac_control",
            failureBehavior: "ignore_and_continue",
            sourcePath: "docs/mac-control.md"
        )
        let validation = MacControlIdealStateManifestValidator.validate(invalid)

        XCTAssertFalse(validation.valid)
        XCTAssertTrue(validation.errors.contains { $0.contains("strategy must match task navigation_strategy") })
        XCTAssertTrue(validation.errors.contains { $0.contains("expected must match verification_oracle.expected_state") })
        XCTAssertTrue(validation.errors.contains { $0.contains("readback_provider must match a route candidate") })
        XCTAssertTrue(validation.errors.contains { $0.contains("secondary_provider must differ") })
        XCTAssertTrue(validation.errors.contains { $0.contains("failure_behavior is unsupported") })
        XCTAssertTrue(validation.errors.contains { $0.contains("must reference implementation source") })
        XCTAssertTrue(validation.errors.contains { $0.contains("implementation-source extension") })
    }

    private func v3Manifest(
        shortcut: MacControlIdealStateShortcutAcceleration,
        includeShortcutRoute: Bool = false
    ) -> MacControlIdealStateManifest {
        var candidates = [MacControlIdealStateRouteCandidate(
            id: "native-accessibility",
            provider: "mac_control",
            method: "accessibility",
            interactionMode: "semantic"
        )]
        if includeShortcutRoute {
            candidates.append(MacControlIdealStateRouteCandidate(
                id: "verified-shortcut",
                provider: "mac_control",
                method: "shortcut",
                interactionMode: "keyboard"
            ))
        }
        return MacControlIdealStateManifest(
            schema: "mac-control-task-manifest/v3",
            repositoryID: "repo-fixture",
            repositoryName: "fixture",
            applicability: "applicable",
            applicabilityReason: "The fixture exposes a supported task.",
            app: MacControlIdealStateApplication(name: "Fixture App"),
            criteria: Dictionary(
                uniqueKeysWithValues: MacControlIdealStateManifestValidator.criteria.map { ($0, true) }
            ),
            tasks: [MacControlIdealStateTask(
                taskID: "open-settings",
                stableTargetID: "fixture.settings",
                hierarchy: "Window > Settings",
                semanticAction: "open settings",
                observablePostcondition: "Settings is visible",
                observableStates: ["enabled", "visible", "completed"],
                navigationStrategy: "semantic target lookup",
                changeStates: ["loading", "disabled"],
                stateExemptions: [
                    "focused": "The trigger does not retain focus.",
                    "selected": "The trigger is not selectable.",
                    "expanded": "The target is not expandable.",
                    "loading": "The task completes synchronously."
                ],
                changeStateExemptions: [
                    "modal": "The task does not present a modal.",
                    "permission_unavailable": "The task requires no protected permission."
                ],
                focusPolicy: "foreground",
                foregroundPostcondition: "target_foreground",
                fallbackPolicy: "none",
                verificationOracle: MacControlIdealStateVerificationOracle(
                    oracleID: "fixture.settings.visible",
                    kind: "window_state",
                    expectedState: "settings_visible",
                    independentReadback: true
                ),
                routeCandidates: candidates,
                shortcutAcceleration: shortcut
            )]
        )
    }

    private func v4Manifest(
        surfaceKind: String = "native_app_ui",
        expectedState: String = "settings_visible",
        cloneEvidence: Bool = false,
        navigationStrategy: String = "direct_semantic",
        claimExpectedState: String? = nil,
        readbackProvider: String = "mac_control",
        secondaryProvider: String = "computer_use",
        failureBehavior: String = "fail_closed",
        sourcePath: String = "Sources/Fixture/SettingsView.swift"
    ) -> MacControlIdealStateManifest {
        func evidence(
            _ criterion: String,
            claims: [String: String],
            tokens: [String]
        ) -> MacControlIdealStateSemanticEvidence {
            MacControlIdealStateSemanticEvidence(
                level: "source_grounded",
                claims: claims,
                sourceReferences: [MacControlIdealStateSourceReference(
                    path: sourcePath,
                    anchor: criterion,
                    evidenceTokens: tokens
                )]
            )
        }

        let stable = evidence(
            "stable_identity",
            claims: [
                "selector_kind": "ax_identifier",
                "selector_value": "fixture.settings",
                "scope": "FixtureWindow",
                "uniqueness": "exactly_one"
            ],
            tokens: ["fixture.settings", "AXIdentifier"]
        )
        var semanticEvidence: [String: MacControlIdealStateSemanticEvidence] = [
            "stable_identity": stable,
            "correct_semantics": evidence(
                "correct_semantics",
                claims: ["role": "AXButton", "accessible_name": "Settings", "action": "AXPress"],
                tokens: ["AXButton", "Settings", "AXPress"]
            ),
            "observable_state": evidence(
                "observable_state",
                claims: ["property": "AXEnabled", "unavailable_behavior": "permission_unavailable"],
                tokens: ["AXEnabled", "permission_unavailable"]
            ),
            "useful_hierarchy": evidence(
                "useful_hierarchy",
                claims: [
                    "container": "FixtureWindow",
                    "relationship": "SettingsPanel",
                    "uniqueness": "exactly_one"
                ],
                tokens: ["FixtureWindow", "SettingsPanel"]
            ),
            "efficient_navigation": evidence(
                "efficient_navigation",
                claims: ["strategy": "direct_semantic", "entry_point": "fixture.settings"],
                tokens: ["direct_semantic", "fixture.settings"]
            ),
            "verifiable_outcomes": evidence(
                "verifiable_outcomes",
                claims: [
                    "readback_provider": readbackProvider,
                    "property": "settings_state",
                    "operator": "equals",
                    "expected": claimExpectedState ?? expectedState
                ],
                tokens: ["settings_state", "equals", expectedState]
            ),
            "route_flexibility": evidence(
                "route_flexibility",
                claims: [
                    "primary_provider": "mac_control",
                    "secondary_provider": secondaryProvider,
                    "fallback_policy": "fresh_state_handoff"
                ],
                tokens: ["mac_control", "fresh_state_handoff", "computer_use"]
            ),
            "stable_change_behavior": evidence(
                "stable_change_behavior",
                claims: [
                    "scenarios": "loading,modal,disabled,permission_unavailable",
                    "failure_behavior": failureBehavior
                ],
                tokens: ["loading", "modal", "disabled", "permission_unavailable", "fail_closed"]
            )
        ]
        if cloneEvidence {
            semanticEvidence["correct_semantics"] = stable
        }
        return MacControlIdealStateManifest(
            schema: "mac-control-task-manifest/v4",
            repositoryID: "repo-fixture",
            repositoryName: "fixture",
            applicability: "applicable",
            applicabilityReason: "The fixture exposes a supported task.",
            app: MacControlIdealStateApplication(name: "Fixture App"),
            tasks: [MacControlIdealStateTask(
                taskID: "open-settings",
                surfaceKind: surfaceKind,
                stableTargetID: "fixture.settings",
                hierarchy: "Window > Settings",
                semanticAction: "open settings",
                observablePostcondition: "settings_state equals settings_visible",
                observableStates: ["enabled", "visible", "completed"],
                navigationStrategy: navigationStrategy,
                changeStates: ["loading", "disabled"],
                accessibility: AccessibilityAuditControl(
                    identifier: "fixture.settings",
                    role: "AXButton"
                ),
                stateExemptions: [
                    "focused": "The trigger does not retain focus.",
                    "selected": "The trigger is not selectable.",
                    "expanded": "The target is not expandable.",
                    "loading": "The task completes synchronously."
                ],
                changeStateExemptions: [
                    "modal": "The task does not present a modal.",
                    "permission_unavailable": "The task requires no protected permission."
                ],
                focusPolicy: "foreground",
                foregroundPostcondition: "target_foreground",
                fallbackPolicy: "fresh_state_handoff",
                verificationOracle: MacControlIdealStateVerificationOracle(
                    oracleID: "fixture.settings.state",
                    kind: "window_state",
                    expectedState: expectedState,
                    independentReadback: true
                ),
                routeCandidates: [
                    MacControlIdealStateRouteCandidate(
                        id: "native-accessibility",
                        provider: "mac_control",
                        method: "accessibility",
                        interactionMode: "semantic"
                    ),
                    MacControlIdealStateRouteCandidate(
                        id: "computer-use-pointer",
                        provider: "computer_use",
                        method: "pointer",
                        interactionMode: "pointer"
                    )
                ],
                shortcutAcceleration: MacControlIdealStateShortcutAcceleration(
                    disposition: "not_applicable",
                    reason: "No stable default shortcut exists."
                ),
                semanticEvidence: semanticEvidence
            )]
        )
    }
}
