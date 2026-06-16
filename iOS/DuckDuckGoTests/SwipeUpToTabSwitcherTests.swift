//
//  SwipeUpToTabSwitcherTests.swift
//  DuckDuckGo
//
//  Copyright © 2026 DuckDuckGo. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import XCTest
import UIKit
@testable import DuckDuckGo

final class SwipeUpToTabSwitcherTests: XCTestCase {

    // MARK: - progress(translationY:referenceDistance:)

    func testProgressMapsUpwardDragToFraction() {
        XCTAssertEqual(SwipeUpToTabSwitcher.progress(translationY: -100, referenceDistance: 200), 0.5, accuracy: 0.0001)
    }

    func testProgressClampsDownwardDragToZero() {
        XCTAssertEqual(SwipeUpToTabSwitcher.progress(translationY: 80, referenceDistance: 200), 0)
    }

    func testProgressClampsBeyondReferenceToOne() {
        XCTAssertEqual(SwipeUpToTabSwitcher.progress(translationY: -300, referenceDistance: 200), 1)
    }

    func testProgressIsZeroForNonPositiveReference() {
        XCTAssertEqual(SwipeUpToTabSwitcher.progress(translationY: -100, referenceDistance: 0), 0)
        XCTAssertEqual(SwipeUpToTabSwitcher.progress(translationY: -100, referenceDistance: -50), 0)
    }

    // MARK: - shouldCommit(progress:verticalVelocity:)

    func testCommitsOnUpwardFlickEvenAtLowProgress() {
        XCTAssertTrue(SwipeUpToTabSwitcher.shouldCommit(progress: 0.05,
                                                        verticalVelocity: -(SwipeUpToTabSwitcher.flickVelocity + 1)))
    }

    func testDoesNotCommitBelowThresholdWithoutFlick() {
        XCTAssertFalse(SwipeUpToTabSwitcher.shouldCommit(progress: 0.1, verticalVelocity: -100))
    }

    func testCommitsPastProgressThresholdWithoutFlick() {
        XCTAssertTrue(SwipeUpToTabSwitcher.shouldCommit(progress: 0.5, verticalVelocity: -100))
    }

    func testCommitsExactlyAtProgressThreshold() {
        XCTAssertTrue(SwipeUpToTabSwitcher.shouldCommit(progress: SwipeUpToTabSwitcher.commitProgress, verticalVelocity: 0))
    }

    func testDownwardVelocityStillCommitsWhenDraggedPastThreshold() {
        XCTAssertTrue(SwipeUpToTabSwitcher.shouldCommit(progress: 0.6, verticalVelocity: 500))
    }

    func testFlickThresholdIsExclusive() {
        // Exactly -flickVelocity is not a flick; just past it is.
        XCTAssertFalse(SwipeUpToTabSwitcher.shouldCommit(progress: 0, verticalVelocity: -SwipeUpToTabSwitcher.flickVelocity))
        XCTAssertTrue(SwipeUpToTabSwitcher.shouldCommit(progress: 0, verticalVelocity: -SwipeUpToTabSwitcher.flickVelocity - 0.5))
    }
}
