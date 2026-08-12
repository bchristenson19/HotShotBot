import Foundation
import Testing
@testable import HotShotBotSwift

/// Verifies `CameraGridView.bestColumnCount`'s brute-force search picks the column count that
/// actually renders the biggest 16:9 tile for a given window shape and camera count — including
/// the non-obvious case where, for exactly 2 cameras, a typical widescreen (but not ultra-wide)
/// window renders bigger tiles stacked in 1 column than side by side in 2 (hand-verified via the
/// tile-height formula in the doc comment on `bestColumnCount` itself).
struct CameraGridViewTests {

    @Test func zeroCamerasReturnsZeroColumns() {
        #expect(CameraGridView.bestColumnCount(for: 0, containerWidth: 2000, containerHeight: 1300, spacing: 8) == 0)
    }

    @Test func degenerateContainerSizeReturnsZeroColumns() {
        #expect(CameraGridView.bestColumnCount(for: 2, containerWidth: 0, containerHeight: 1300, spacing: 8) == 0)
        #expect(CameraGridView.bestColumnCount(for: 2, containerWidth: 2000, containerHeight: 0, spacing: 8) == 0)
    }

    @Test func singleCameraAlwaysPicksOneColumn() {
        #expect(CameraGridView.bestColumnCount(for: 1, containerWidth: 2000, containerHeight: 1300, spacing: 8) == 1)
        #expect(CameraGridView.bestColumnCount(for: 1, containerWidth: 400, containerHeight: 4000, spacing: 8) == 1)
    }

    @Test func twoCamerasInATypicalWidescreenWindowStackRatherThanSideBySide() {
        // A 1997×1301 window (~1.53:1, an ordinary widescreen laptop shape — narrower than 16:9)
        // renders a bigger tile stacked in 1 column (each tile spans full width, height-bound)
        // than side by side in 2 (each tile half-width, badly width-bound against 16:9 content).
        #expect(CameraGridView.bestColumnCount(for: 2, containerWidth: 2000, containerHeight: 1300, spacing: 8) == 1)
    }

    @Test func twoCamerasInAnUltraWideWindowGoSideBySide() {
        // A 5:1 window is wide enough that even half-width tiles are still comfortably wider
        // than 16:9, so side by side (2 columns) beats stacking (1 column) here.
        #expect(CameraGridView.bestColumnCount(for: 2, containerWidth: 4000, containerHeight: 800, spacing: 8) == 2)
    }

    @Test func fourCamerasInASquareWindowPicksTwoByTwo() {
        #expect(CameraGridView.bestColumnCount(for: 4, containerWidth: 1000, containerHeight: 1000, spacing: 8) == 2)
    }
}
