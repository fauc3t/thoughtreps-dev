import Testing
import SwiftUI
import UIKit
@testable import ThoughtReps

struct AccessoryMetricsTests {
    @Test func regularWidthGetsTheLargeBar() {
        let metrics = AccessoryMetrics(UIUserInterfaceSizeClass.regular)
        #expect(metrics.pillHeight == 56)
        #expect(metrics.tapSize == 52)
        #expect(metrics.maxWidth == 640)
        #expect(metrics.barHeight == 72)
    }

    @Test func compactAndUnknownWidthGetThePhoneBar() {
        for metrics in [AccessoryMetrics(UIUserInterfaceSizeClass.compact), AccessoryMetrics(UIUserInterfaceSizeClass.unspecified), AccessoryMetrics(nil)] {
            #expect(metrics.pillHeight == 48)
            #expect(metrics.tapSize == 44)
            #expect(metrics.maxWidth == .infinity)
            #expect(metrics.barHeight == 64)
        }
    }

    @Test func swiftUIAndUIKitSizeClassesAgree() {
        #expect(AccessoryMetrics(UserInterfaceSizeClass.regular) == AccessoryMetrics(UIUserInterfaceSizeClass.regular))
        #expect(AccessoryMetrics(UserInterfaceSizeClass.compact) == AccessoryMetrics(UIUserInterfaceSizeClass.compact))
    }

    @MainActor @Test func settingMetricsResizesTheBar() {
        let bar = AccessoryBar(rootView: AnyView(EmptyView()), metrics: AccessoryMetrics(isRegular: false))
        #expect(bar.heightConstraint?.constant == 64)
        #expect(bar.setMetrics(AccessoryMetrics(isRegular: true)))
        #expect(bar.heightConstraint?.constant == 72)
        #expect(!bar.setMetrics(AccessoryMetrics(isRegular: true)))
        #expect(bar.setMetrics(AccessoryMetrics(isRegular: false)))
        #expect(bar.heightConstraint?.constant == 64)
    }
}
