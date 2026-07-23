import Foundation

/// Centralized process-memory measurement utility.
/// All phys_footprint queries route through this single source of truth.
enum MemoryMonitor {

    /// Returns the phys_footprint (private dirty memory) of this process in bytes,
    /// or 0 if the Mach call fails.
    ///
    /// phys_footprint is the metric iOS Jetsam uses to enforce the 48 MB
    /// keyboard-extension memory cap. Prefer this over `resident_size`,
    /// which includes shared/clean pages that don't count toward the cap.
    static func currentFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return info.phys_footprint
    }
}
