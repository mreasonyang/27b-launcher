import SwiftUI

struct StudioDashboardView: View {
    @Bindable var controller: ServiceController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LauncherTheme.sectionSpacing) {
                StudioHeroCockpit(controller: controller)
                StudioTelemetryGrid(controller: controller)
                StudioControlModules(controller: controller)
            }
            .padding(LauncherTheme.pagePadding)
            .frame(maxWidth: LauncherTheme.contentMaximumWidth)
            .frame(maxWidth: .infinity, alignment: .top)
            .reportingDashboardContentHeight()
        }
        .fittingWindowToContent()
    }
}
