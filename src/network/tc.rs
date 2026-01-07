//! Traffic Control (tc) wrapper for CAKE QoS
//!
//! Per rewrite.md: Wrapper around tc binary (Netlink-TC is too unstable).
//! Implements "Breathing CAKE" with Median + EMA smoothing for jitter-free bandwidth.

use anyhow::{Context, Result};
use log::{info, debug, warn};
use std::process::Command;
use std::collections::VecDeque;

/// Traffic Control manager with Median + EMA smoothing
/// 
/// To prevent jitter, we use a two-stage smoothing approach:
/// 1. Rolling median over N samples (removes outliers/spikes)
/// 2. EMA on top of median (smooth transitions)
/// 3. Hysteresis: Only apply if stable for M consecutive ticks
pub struct TcManager {
    /// Last applied bandwidth (Mbit)
    last_bandwidth: Option<u32>,
    /// EMA-smoothed bandwidth
    smoothed_bandwidth: f64,
    /// EMA alpha (weight for current sample)
    ema_alpha: f64,
    /// Minimum change threshold (Mbit) to trigger update
    change_threshold_mbit: u32,
    /// Minimum percentage change to trigger update
    change_threshold_pct: f64,
    /// Rolling window for median calculation
    sample_window: VecDeque<u32>,
    /// Window size for median
    window_size: usize,
    /// Consecutive ticks the target has been stable
    stable_ticks: u32,
    /// Ticks required before applying change
    hysteresis_ticks: u32,
    /// Target bandwidth (proposed but not yet applied)
    pending_bandwidth: Option<u32>,
}

impl TcManager {
    pub fn new(ema_alpha: f64, threshold_mbit: u32, threshold_pct: f64) -> Self {
        Self {
            last_bandwidth: None,
            smoothed_bandwidth: 0.0,
            ema_alpha,
            change_threshold_mbit: threshold_mbit,
            change_threshold_pct: threshold_pct,
            sample_window: VecDeque::with_capacity(10),
            window_size: 5,          // 5 samples for median (10 seconds at 2s tick)
            stable_ticks: 0,
            hysteresis_ticks: 3,     // Must be stable for 3 ticks (6 seconds) before applying
            pending_bandwidth: None,
        }
    }

    /// Calculate median of samples
    fn median(&self) -> Option<u32> {
        if self.sample_window.is_empty() {
            return None;
        }
        let mut sorted: Vec<u32> = self.sample_window.iter().copied().collect();
        sorted.sort();
        let mid = sorted.len() / 2;
        if sorted.len() % 2 == 0 && sorted.len() > 1 {
            Some((sorted[mid - 1] + sorted[mid]) / 2)
        } else {
            Some(sorted[mid])
        }
    }

    /// Update the smoothed bandwidth with a new sample
    /// Returns true if CAKE should be updated
    pub fn update_bandwidth(&mut self, current_speed_mbit: u32) -> bool {
        if current_speed_mbit == 0 {
            return false;
        }

        // Stage 1: Add to rolling window
        self.sample_window.push_back(current_speed_mbit);
        if self.sample_window.len() > self.window_size {
            self.sample_window.pop_front();
        }

        // Need at least 3 samples before making decisions
        if self.sample_window.len() < 3 {
            debug!("CAKE: Warming up ({}/{} samples)", self.sample_window.len(), self.window_size);
            return false;
        }

        // Stage 2: Get median (removes outliers)
        let median_mbit = match self.median() {
            Some(m) => m,
            None => return false,
        };

        // Stage 3: Apply EMA on top of median for smooth transitions
        if self.smoothed_bandwidth == 0.0 {
            self.smoothed_bandwidth = median_mbit as f64;
        } else {
            self.smoothed_bandwidth = (median_mbit as f64 * self.ema_alpha) + 
                                      (self.smoothed_bandwidth * (1.0 - self.ema_alpha));
        }

        let target_mbit = self.smoothed_bandwidth.round() as u32;
        
        // Stage 4: Check if significant change
        let should_consider = if let Some(last) = self.last_bandwidth {
            let abs_diff = (target_mbit as i32 - last as i32).unsigned_abs();
            let pct_diff = abs_diff as f64 / last as f64;
            
            abs_diff >= self.change_threshold_mbit || pct_diff >= self.change_threshold_pct
        } else {
            true // First application
        };

        if !should_consider {
            // Reset hysteresis if not considering a change
            self.stable_ticks = 0;
            self.pending_bandwidth = None;
            return false;
        }

        // Stage 5: Hysteresis - must be consistently moving in same direction
        // We allow some EMA drift but reset if direction reverses significantly
        let direction_change = if let Some(pending) = self.pending_bandwidth {
            let pending_vs_last = pending as i32 - self.last_bandwidth.unwrap_or(0) as i32;
            let target_vs_last = target_mbit as i32 - self.last_bandwidth.unwrap_or(0) as i32;
            // Reset if direction reversed (one wants up, other wants down)
            (pending_vs_last > 0 && target_vs_last < 0) || 
            (pending_vs_last < 0 && target_vs_last > 0)
        } else {
            false
        };

        if direction_change {
            // Direction reversed, reset hysteresis (prevents flapping)
            self.pending_bandwidth = Some(target_mbit);
            self.stable_ticks = 1;
        } else if self.pending_bandwidth.is_some() {
            // Same direction, keep counting
            self.stable_ticks += 1;
            self.pending_bandwidth = Some(target_mbit);
        } else {
            // First consideration
            self.pending_bandwidth = Some(target_mbit);
            self.stable_ticks = 1;
        }

        if self.stable_ticks >= self.hysteresis_ticks {
            debug!("CAKE: Bandwidth change approved after {} stable ticks: {} -> {}Mbit",
                   self.stable_ticks, self.last_bandwidth.unwrap_or(0), target_mbit);
            self.stable_ticks = 0;
            self.pending_bandwidth = None;
            true
        } else {
            debug!("CAKE: Waiting for stability ({}/{} ticks at {}Mbit)",
                   self.stable_ticks, self.hysteresis_ticks, target_mbit);
            false
        }
    }

    /// Apply CAKE qdisc to interface
    /// Per rewrite.md: tc qdisc replace dev <iface> root cake bandwidth <X>mbit besteffort nat
    pub fn apply_cake(&mut self, interface: &str, _bandwidth_kbit: u32) -> Result<()> {
        let bandwidth_mbit = self.smoothed_bandwidth.round().max(1.0) as u32;
        
        info!("Applying CAKE on {} with {}mbit bandwidth", interface, bandwidth_mbit);
        
        let output = Command::new("tc")
            .args([
                "qdisc", "replace", "dev", interface, "root", "cake",
                "bandwidth", &format!("{}mbit", bandwidth_mbit),
                "diffserv4",      // Differentiated services
                "dual-dsthost",   // Fair queuing per destination
                "nat",            // NAT awareness
                "wash",           // Clear DSCP on ingress
                "ack-filter",     // ACK filtering
            ])
            .output()
            .context("Failed to execute tc command")?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            warn!("tc failed: {}", stderr);
            
            // Fallback to simpler CAKE config
            let output = Command::new("tc")
                .args([
                    "qdisc", "replace", "dev", interface, "root", "cake",
                    "bandwidth", &format!("{}mbit", bandwidth_mbit),
                    "besteffort", "nat",
                ])
                .output()?;
            
            if !output.status.success() {
                anyhow::bail!("Failed to apply CAKE qdisc");
            }
        }

        self.last_bandwidth = Some(bandwidth_mbit);
        info!("CAKE applied successfully: {}mbit on {}", bandwidth_mbit, interface);
        
        Ok(())
    }

    /// Remove CAKE qdisc from interface
    pub fn remove_cake(&self, interface: &str) -> Result<()> {
        let output = Command::new("tc")
            .args(["qdisc", "del", "dev", interface, "root"])
            .output();
        
        // Ignore errors (may not have qdisc)
        if let Ok(o) = output {
            if o.status.success() {
                info!("Removed CAKE from {}", interface);
            }
        }
        
        Ok(())
    }

    #[cfg(test)]
    pub fn get_smoothed_mbit(&self) -> u32 {
        self.smoothed_bandwidth.round() as u32
    }

    #[cfg(test)]
    pub fn set_last_applied(&mut self, mbit: u32) {
        self.last_bandwidth = Some(mbit);
    }
}

/// Ethtool wrapper for hardware offload settings
pub struct EthtoolManager;

impl EthtoolManager {
    /// Enable interrupt coalescing (for high CPU scenarios)
    /// Per rewrite.md: ethtool -C adaptive-rx on
    pub fn enable_coalescing(interface: &str) -> Result<()> {
        debug!("Enabling interrupt coalescing on {}", interface);
        
        let _ = Command::new("ethtool")
            .args(["-C", interface, "adaptive-rx", "on"])
            .output();

        Ok(())
    }

    /// Disable interrupt coalescing (for low latency)
    pub fn disable_coalescing(interface: &str) -> Result<()> {
        debug!("Disabling interrupt coalescing on {}", interface);
        
        let _ = Command::new("ethtool")
            .args(["-C", interface, "adaptive-rx", "off"])
            .output();

        Ok(())
    }
}

impl Default for TcManager {
    fn default() -> Self {
        // Conservative defaults to prevent jitter
        Self::new(0.1, 25, 0.20)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_median_smoothing() {
        // Use faster alpha for testing (0.5 = 50% weight to new samples)
        let mut tc = TcManager::new(0.5, 25, 0.20);
        
        // First 2 samples: warming up (need 3 samples minimum)
        assert!(!tc.update_bandwidth(100)); // Sample 1 - warming
        assert!(!tc.update_bandwidth(100)); // Sample 2 - warming
        
        // Sample 3+: Now have enough data, hysteresis starts
        // First application (no last_bandwidth) triggers "should_consider = true"
        // Hysteresis needs 3 stable ticks
        assert!(!tc.update_bandwidth(100)); // Sample 3, tick 1
        assert!(!tc.update_bandwidth(100)); // Sample 4, tick 2  
        assert!(tc.update_bandwidth(100));  // Sample 5, tick 3 - TRIGGERS
        
        // Simulate "Applied"
        tc.set_last_applied(100);
        
        // Small changes should NOT trigger (< 25 Mbit and < 20%)
        // After applying, these won't pass the threshold check
        assert!(!tc.update_bandwidth(110)); // Only 10 Mbit diff
        assert!(!tc.update_bandwidth(115)); // 15 Mbit diff, 15%
        
        // Large sustained change should eventually trigger
        // Need to feed enough 50s to overcome EMA and pass hysteresis
        // With alpha 0.5, smoothed moves faster toward new value
        for _ in 0..5 {
            tc.update_bandwidth(50); // Feed multiple samples to move EMA
        }
        // After several 50s, smoothed should be around 50-60, well below threshold
        // This exceeds 20% change from 100
        
        // Now check that it eventually triggers (may need more ticks for hysteresis)
        let mut triggered = false;
        for _ in 0..5 {
            if tc.update_bandwidth(50) {
                triggered = true;
                break;
            }
        }
        assert!(triggered, "Large change should eventually trigger");
    }

    #[test]
    fn test_median_filters_outliers() {
        let mut tc = TcManager::new(0.1, 25, 0.20);
        
        // Fill with stable values
        tc.update_bandwidth(100);
        tc.update_bandwidth(100);
        tc.update_bandwidth(100);
        tc.update_bandwidth(100);
        tc.update_bandwidth(100);
        
        // One outlier spike should be filtered by median
        tc.update_bandwidth(500); // Outlier
        
        // Median of [100, 100, 100, 100, 500] = 100
        // So smoothed bandwidth should still be ~100
        assert!(tc.get_smoothed_mbit() < 150); // Not heavily affected by outlier
    }
    
    #[test]
    fn test_hysteresis_prevents_flapping() {
        let mut tc = TcManager::new(0.5, 25, 0.20);
        
        // Warm up with 100
        for _ in 0..5 { tc.update_bandwidth(100); }
        tc.set_last_applied(100);
        
        // Alternating values should NOT trigger (flapping)
        // Because target keeps changing, hysteresis counter resets
        assert!(!tc.update_bandwidth(50));  // Big drop
        assert!(!tc.update_bandwidth(150)); // Big jump - resets counter!
        assert!(!tc.update_bandwidth(50));  // Drop again - resets!
        assert!(!tc.update_bandwidth(150)); // Jump - resets!
        
        // No changes should have been applied due to instability
    }
}
