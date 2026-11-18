import SwiftUI

struct RootView: View {
    @Environment(InboxStore.self) private var store

    var body: some View {
        switch store.phase {
        case .needsFolder(let message):
            OnboardingView(problem: message)
        case .ready:
            MainTabView()
        }
    }
}

struct MainTabView: View {
    @Environment(InboxStore.self) private var store
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            ForEach(Bucket.allCases) { bucket in
                Tab(bucket.title, systemImage: bucket.symbol, value: AppTab.bucket(bucket)) {
                    BucketScreen(bucket: bucket)
                }
                .badge(bucket == .attention ? store.openCount(bucket) : 0)   // only Attention counts; Review and Scams stay quiet
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView()
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = store.toast {
                ToastView(toast: toast) { store.toast = nil }
                    .padding(.bottom, 64)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .animation(.spring(duration: 0.35), value: store.toast?.id)
        .sensoryFeedback(.success, trigger: store.toast?.id) { _, new in new != nil }
    }
}
