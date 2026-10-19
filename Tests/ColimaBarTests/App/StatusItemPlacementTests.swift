import CoreGraphics
import Testing

@testable import ColimaBar

@Suite struct StatusItemPlacementTests {
    private let screen = ScreenGeometry(frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
    private let second = ScreenGeometry(frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080))
    /// A screen with a camera housing between x 660 and 852.
    private let notched = ScreenGeometry(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        topLeft: CGRect(x: 0, y: 950, width: 660, height: 32),
        topRight: CGRect(x: 852, y: 950, width: 660, height: 32))

    private func item(x: CGFloat, width: CGFloat = 40) -> CGRect {
        CGRect(x: x, y: 958, width: width, height: 24)
    }

    // MARK: - canAnchor

    @Test func anItemOnAScreenAnchors() {
        #expect(StatusItemPlacement.canAnchor(item: item(x: 1000), screens: [screen]))
    }

    @Test func anEmptyFrameDoesNotAnchor() {
        #expect(!StatusItemPlacement.canAnchor(item: .zero, screens: [screen]))
        #expect(!StatusItemPlacement.canAnchor(item: CGRect(x: 100, y: 958, width: 0, height: 24), screens: [screen]))
    }

    @Test func anItemOffAllScreensDoesNotAnchor() {
        #expect(!StatusItemPlacement.canAnchor(item: item(x: 5000), screens: [screen]))
        #expect(!StatusItemPlacement.canAnchor(item: item(x: -4000), screens: [screen]))
        #expect(!StatusItemPlacement.canAnchor(item: item(x: 1000), screens: []))
    }

    @Test func anItemPastTheScreenEdgeDoesNotAnchor() {
        #expect(!StatusItemPlacement.canAnchor(item: item(x: 1500), screens: [screen]))
    }

    @Test func anItemOnTheSecondScreenAnchors() {
        #expect(StatusItemPlacement.canAnchor(item: item(x: 2000), screens: [screen, second]))
    }

    @Test func theRightAreaOfANotchedScreenAnchors() {
        #expect(StatusItemPlacement.canAnchor(item: item(x: 1000), screens: [notched]))
    }

    @Test func theLeftAreaOfANotchedScreenAnchors() {
        #expect(StatusItemPlacement.canAnchor(item: item(x: 300), screens: [notched]))
    }

    @Test func anItemUnderTheCameraHousingDoesNotAnchor() {
        #expect(!StatusItemPlacement.canAnchor(item: item(x: 700), screens: [notched]))
    }

    @Test func anItemOnTheEdgeOfTheHousingDoesNotAnchor() {
        #expect(!StatusItemPlacement.canAnchor(item: item(x: 640), screens: [notched]))  // 640 to 680
        #expect(!StatusItemPlacement.canAnchor(item: item(x: 830), screens: [notched]))  // 830 to 870
    }

    @Test func theToleranceIsOnePoint() {
        // 852 - 1 = 851 is the first x that the right area takes.
        #expect(StatusItemPlacement.canAnchor(item: item(x: 851), screens: [notched]))
        #expect(!StatusItemPlacement.canAnchor(item: item(x: 850.5 - 0.6), screens: [notched]))
        // The left area ends at 660 + 1.
        #expect(StatusItemPlacement.canAnchor(item: item(x: 621), screens: [notched]))
        #expect(!StatusItemPlacement.canAnchor(item: item(x: 622), screens: [notched]))
    }

    @Test func aScreenWithoutAHousingNeedsNoFreeArea() {
        #expect(StatusItemPlacement.canAnchor(item: item(x: 700), screens: [screen]))
    }

    // MARK: - isOnScreen

    @Test func aWindowOnAScreenIsOnScreen() {
        #expect(StatusItemPlacement.isOnScreen(CGRect(x: 100, y: 100, width: 480, height: 640), screens: [screen]))
    }

    @Test func aWindowOffAllScreensIsNot() {
        #expect(!StatusItemPlacement.isOnScreen(CGRect(x: 3000, y: 100, width: 480, height: 640), screens: [screen]))
        #expect(!StatusItemPlacement.isOnScreen(CGRect(x: 100, y: 100, width: 480, height: 640), screens: []))
    }

    @Test func halfOnAScreenCounts() {
        #expect(StatusItemPlacement.isOnScreen(CGRect(x: 1272, y: 100, width: 480, height: 640), screens: [screen]))
    }

    @Test func lessThanHalfOnAScreenDoesNotCount() {
        #expect(!StatusItemPlacement.isOnScreen(CGRect(x: 1300, y: 100, width: 480, height: 640), screens: [screen]))
    }

    @Test func anEmptyWindowIsNotOnScreen() {
        #expect(!StatusItemPlacement.isOnScreen(.zero, screens: [screen]))
    }

    @Test func halfOnOneScreenIsEnoughWhenItSpansTwo() {
        let frame = CGRect(x: 1272, y: 100, width: 480, height: 640)
        #expect(StatusItemPlacement.isOnScreen(frame, screens: [screen, second]))
    }

    // MARK: - Notch screens away from the origin

    /// The areas of a notched screen at x 1512, in global coordinates.
    private let notchedRight = ScreenGeometry(
        frame: CGRect(x: 1512, y: 0, width: 1512, height: 982),
        topLeft: CGRect(x: 1512, y: 950, width: 660, height: 32),
        topRight: CGRect(x: 2364, y: 950, width: 660, height: 32))
    /// The same screen, with areas that start at the screen origin.
    private let notchedRightRelative = ScreenGeometry(
        frame: CGRect(x: 1512, y: 0, width: 1512, height: 982),
        topLeft: CGRect(x: 0, y: 950, width: 660, height: 32),
        topRight: CGRect(x: 852, y: 950, width: 660, height: 32))
    /// A notched screen left of an external main display.
    private let notchedLeft = ScreenGeometry(
        frame: CGRect(x: -1512, y: 0, width: 1512, height: 982),
        topLeft: CGRect(x: 0, y: 950, width: 660, height: 32),
        topRight: CGRect(x: 852, y: 950, width: 660, height: 32))
    private let externalMain = ScreenGeometry(frame: CGRect(x: 0, y: 0, width: 1512, height: 1440))

    @Test func areasInGlobalAndInScreenCoordinatesGiveTheSameResult() {
        for s in [notchedRight, notchedRightRelative] {
            #expect(StatusItemPlacement.canAnchor(item: item(x: 2500), screens: [s]))  // right area
            #expect(StatusItemPlacement.canAnchor(item: item(x: 1800), screens: [s]))  // left area
            #expect(!StatusItemPlacement.canAnchor(item: item(x: 2250), screens: [s]))  // under the housing
        }
        #expect(notchedRight == notchedRightRelative)
    }

    @Test func aNotchedScreenLeftOfTheMainDisplayUsesItsOwnOrigin() {
        let screens = [externalMain, notchedLeft]
        #expect(StatusItemPlacement.canAnchor(item: item(x: -500), screens: screens))
        #expect(!StatusItemPlacement.canAnchor(item: item(x: -1512 + 700), screens: screens))
        #expect(StatusItemPlacement.canAnchor(item: item(x: 1000), screens: screens))
    }

    @Test func anExternalMainDisplayWithANotchedLaptopScreenKeepsBothRules() {
        let screens = [externalMain, notchedRight]
        #expect(StatusItemPlacement.canAnchor(item: item(x: 1000), screens: screens))  // external display
        #expect(!StatusItemPlacement.canAnchor(item: item(x: 2250), screens: screens))  // under the housing
    }

    @Test func anEmptyAreaMeansNoHousing() {
        // NSScreen gives an empty rect, not nil, for a screen without a housing.
        let plain = ScreenGeometry(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), topLeft: .zero, topRight: .zero)
        #expect(plain.topLeft == nil)
        #expect(plain.topRight == nil)
        #expect(StatusItemPlacement.canAnchor(item: item(x: 700), screens: [plain]))
    }

    @Test func aScreenWithOnlyOneFreeAreaNeedsNoFreeArea() {
        let oneSided = ScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            topLeft: CGRect(x: 0, y: 950, width: 660, height: 32), topRight: .zero)
        #expect(oneSided.topRight == nil)
        #expect(StatusItemPlacement.canAnchor(item: item(x: 700), screens: [oneSided]))
    }
}
