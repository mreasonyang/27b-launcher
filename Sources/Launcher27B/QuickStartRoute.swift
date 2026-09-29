enum QuickStartRoute: Equatable {
    case setup, deferred, dashboard

    static func resolve(installation: InstallationStatus, presented: Bool, deferred: Bool,
                        completed: Bool) -> Self {
        if presented { return .setup }
        if installation == .ready { return completed ? .dashboard : .setup }
        return deferred ? .deferred : .setup
    }
}
