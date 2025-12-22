hifi-wifi v1.1.0

Major update focusing on persistence, stability, and user control.

New Features:
* **SteamOS Persistence**: hifi-wifi now survives SteamOS system updates! A new restore service automatically reinstalls the tool and dependencies if the system partition is wiped.
* **Force Performance Mode**: Added `--force-performance` flag to permanently disable Wi-Fi power saving, regardless of battery state.
* **Smart Updates**: The installer now safely handles updates by backing up NetworkManager profiles, reverting old patches, and restoring settings automatically.
* **Backend Switching**: Improved reliability when switching to the `iwd` backend, including automatic package caching for offline restoration.

Improvements:
* **Installer**: Added robust handling for SteamOS read-only filesystem (steamos-readonly disable/enable).
* **UX**: Changed default reboot prompt to "Yes" for smoother installation flow.
* **Fixes**: Resolved issues with missing `enable_iwd` command and systemd service typos.

Installation:
git clone https://github.com/doughty247/hifi-wifi.git
cd hifi-wifi
sudo ./install.sh

---

hifi-wifi v1.0.0

Initial release of the hifi-wifi network optimization utility.

This tool addresses Wi-Fi latency and stability issues on Linux handhelds (Steam Deck, Bazzite) by enforcing CAKE queue disciplines and context-aware power management.

Key Features:
* Bufferbloat Mitigation: Configures sch_cake with adaptive bandwidth overhead (85% for Wi-Fi).
* Power Management: Automates transition between performance (AC) and power-saving (Battery) states to prevent jitter.
* Driver Tuning: Applies specific parameters for Realtek and Intel wireless adapters.
* Diagnostics: Integrated self-test suite for signal health and latency analysis.

Installation:
git clone https://github.com/doughty247/hifi-wifi.git
cd hifi-wifi
sudo ./install.sh
