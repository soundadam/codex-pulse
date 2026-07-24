import CoreGraphics
import Testing

@testable import CodexPulseUI

struct InspectorPanelLayoutTests {
    @Test
    func usesPreferredSizeWhenTheScreenHasRoom() {
        let size = InspectorPanelLayout.contentSize(
            for: CGRect(x: 120, y: 40, width: 1_440, height: 900)
        )

        #expect(size == CGSize(width: 780, height: 560))
    }

    @Test
    func staysInsideAConstrainedVisibleFrame() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 700, height: 500)
        let size = InspectorPanelLayout.contentSize(for: visibleFrame)

        #expect(size == CGSize(width: 668, height: 452))
        #expect(size.width < visibleFrame.width)
        #expect(size.height < visibleFrame.height)
    }
}
