import Foundation
import IOKit.pwr_mgt
import os.log

/// Manages macOS power assertions to prevent the display from sleeping.
final class PowerManager {
    static let shared = PowerManager()
    
    private var assertionID: IOPMAssertionID = 0
    private var timer: Timer?
    private let logger = Logger(subsystem: "com.mwb.client", category: "PowerManager")
    
    private init() {}
    
    /// Prevents the display from sleeping for a short duration.
    /// Should be called repeatedly as Awake packets arrive.
    func poke() {
        // Renew the assertion
        let reason = "Mouse Without Borders: Remote machine is active" as CFString
        
        if assertionID == 0 {
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypeNoDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason,
                &assertionID
            )
            
            if result == kIOReturnSuccess {
                logger.info("Power assertion created: display sleep prevented")
            } else {
                logger.error("Failed to create power assertion: \(result)")
            }
        }
        
        // Reset the timer to release the assertion after 30 seconds of inactivity
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            self?.releaseAssertion()
        }
    }
    
    private func releaseAssertion() {
        guard assertionID != 0 else { return }
        
        let result = IOPMAssertionRelease(assertionID)
        if result == kIOReturnSuccess {
            logger.info("Power assertion released")
        } else {
            logger.error("Failed to release power assertion: \(result)")
        }
        assertionID = 0
        timer = nil
    }
    
    deinit {
        releaseAssertion()
    }
}
