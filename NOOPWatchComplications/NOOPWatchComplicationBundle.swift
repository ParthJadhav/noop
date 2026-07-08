import WidgetKit
import SwiftUI

/// The watchOS complication extension entry point. Bundles the Charge complication so the watch face
/// can place it in any of the supported accessory families. The watch app (the glance UI) lives in a
/// separate target; this extension only draws the face complication.
@main
struct NOOPWatchComplicationBundle: WidgetBundle {
    var body: some Widget {
        NOOPChargeComplication()
    }
}
