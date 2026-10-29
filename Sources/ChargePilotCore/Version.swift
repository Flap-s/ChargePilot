public enum ChargePilotBuild {
    /// The helper's own revision. Bump it with changes to the helper; it deliberately isn't the app version, so that
    /// app-only updates leave the helper binary identical and don't ask for the administrator password again.
    public static let helperRevision = "2"
}
