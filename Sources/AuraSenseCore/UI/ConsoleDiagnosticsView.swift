import Foundation

/// Terminal UI and formatted output renderer for live diagnostics.
public enum ConsoleDiagnosticsView {
    public static func renderLiveHeader() -> String {
        """
        ╔══════════════════════════════════════════════════════════════════════════════╗
        ║                            AuraSense macOS Agent                             ║
        ║             BLE Discovery & Real-Time Proximity Diagnostics                  ║
        ╚══════════════════════════════════════════════════════════════════════════════╝
        """
    }

    public static func renderSnapshot(_ snapshot: DiagnosticsSnapshot) -> String {
        return snapshot.formattedReport
    }
}
