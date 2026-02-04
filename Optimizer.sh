#!/usr/bin/env bash
# CachyOS System Optimization Script
# Pure OS-level tweaks only. Two modes: Balanced & Aggressive.
# Safe, reversible, hardware-agnostic.

set -euo pipefail

log() { printf "\n[+] %s\n" "$*"; }
warn() { printf "\n[!] %s\n" "$*"; }
ask() { read -rp "$1 [y/N]: " ans; [[ "${ans:-n}" =~ ^[Yy]$ ]]; }
backup() { [[ -f "$1" ]] && cp -n "$1" "$1.bak.$(date +%s)" && log "Backup: $1"; }
write() { backup "$1"; printf "%s\n" "$2" > "$1"; }
append_once() { grep -qxF "$1" "$2" 2>/dev/null || echo "$1" >> "$2"; }

# --- Rollback ------------------------------------------------------------

if [[ "${1:-}" == "--rollback" ]]; then
  log "Restoring backups..."
  for f in /etc/**/*.bak.*; do
    orig="${f%.bak.*}"
    cp "$f" "$orig"
    log "Restored $orig"
  done
  exit 0
fi

# --- Root check ----------------------------------------------------------

[[ $EUID -ne 0 ]] && { warn "Run as root: sudo bash $0"; exit 1; }

# --- Mode selection ------------------------------------------------------

clear
echo "Choose optimization mode:"
echo "1) Balanced & Safe"
echo "2) Aggressive (Maximum OS Performance)"
read -rp "Enter 1 or 2: " MODE

case "$MODE" in
  1)
    MODE_NAME="Balanced & Safe"
    SUMMARY="
- BORE kernel
- CPU driver auto-optimization
- ZRAM (ram/2, zstd)
- TCP BBR
- I/O scheduler tuning
- HugePages (RAM-aware)
- Transparent HugePages tuning
- vm.max_map_count
- systemd latency tweaks
- sysctl latency tuning"
    ;;
  2)
    MODE_NAME="Aggressive OS Optimization"
    SUMMARY="
- Everything in Balanced mode, plus:
- Disable NUMA balancing
- Disable kernel watchdog
- Disable kernel debug
- IRQ split
- Scheduler granularity tuning
- VFS cache pressure tuning
- Network queue tuning
- Lower swappiness
- Kernel boot flags:
    nohz_full=all
    transparent_hugepage=never"
    ;;
  *)
    warn "Invalid selection."
    exit 1
    ;;
esac

echo -e "\nYou selected: $MODE_NAME"
echo -e "\nThis mode will apply:$SUMMARY"
ask "Continue?" || { warn "Aborted."; exit 1; }

# --- 1. Install BORE kernel ----------------------------------------------

log "Installing BORE kernel..."
pacman -S --needed --noconfirm linux-cachyos-bore linux-cachyos-bore-headers || warn "Kernel install skipped."

# --- 2. CPU driver auto-detection ----------------------------------------

CPU_DRIVER=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || echo "unknown")
log "CPU driver: $CPU_DRIVER"

case "$CPU_DRIVER" in
  amd-pstate|amd-pstate-epp)
    log "Optimizing amd-pstate..."
    for f in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
      echo performance > "$f" 2>/dev/null || true
    done
    ;;
  intel_pstate)
    log "Optimizing intel_pstate..."
    echo performance > /sys/devices/system/cpu/intel_pstate/min_perf_pct 2>/dev/null || true
    echo performance > /sys/devices/system/cpu/intel_pstate/max_perf_pct 2>/dev/null || true
    ;;
  *)
    log "Using cpupower fallback..."
    pacman -S --needed --noconfirm cpupower
    systemctl enable --now cpupower || warn "cpupower failed."
    sed -i "s/^governor=.*/governor='performance'/" /etc/default/cpupower 2>/dev/null || true
    ;;
esac

# --- 3. ZRAM --------------------------------------------------------------

log "Configuring ZRAM..."
write /etc/systemd/zram-generator.conf \
"[zram0]
zram-size = ram / 2
compression-algorithm = zstd"

systemctl daemon-reload

# --- 4. TCP BBR -----------------------------------------------------------

log "Enabling TCP BBR..."
write /etc/sysctl.d/99-bbr.conf "net.ipv4.tcp_congestion_control = bbr"

# --- 5. I/O scheduler -----------------------------------------------------

log "Setting I/O scheduler..."
write /etc/udev/rules.d/60-io-scheduler.rules \
'ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/scheduler}="none"'

udevadm control --reload-rules
udevadm trigger || warn "udevadm issues."

# --- 6. HugePages (RAM-aware) --------------------------------------------

RAM_GB=$(($(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 / 1024))
HP=$(( RAM_GB >= 32 ? 2048 : 0 ))
log "Setting HugePages = $HP"
write /etc/sysctl.d/hugepages.conf "vm.nr_hugepages = $HP"

# --- 7. Transparent HugePages --------------------------------------------

log "Tuning THP..."
write /etc/sysctl.d/99-thp.conf \
"vm.transparent_hugepage.enabled = madvise
vm.transparent_hugepage.defrag = never"

# --- 8. vm.max_map_count --------------------------------------------------

log "Raising vm.max_map_count..."
write /etc/sysctl.d/99-map.conf "vm.max_map_count = 1048576"

# --- 9. Systemd latency tweaks --------------------------------------------

log "Applying systemd latency tweaks..."
append_once "RuntimeWatchdogSec=0" /etc/systemd/system.conf
append_once "ShutdownWatchdogSec=0" /etc/systemd/system.conf

mkdir -p /etc/systemd/system/user-.slice.d
write /etc/systemd/system/user-.slice.d/io.conf \
"[Slice]
IOWeight=1000"

# --- 10. Sysctl latency tuning --------------------------------------------

log "Applying sysctl latency tuning..."
write /etc/sysctl.d/99-latency.conf \
"kernel.sched_autogroup_enabled = 0
kernel.sched_migration_cost_ns = 5000000
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5"

# --- 11. Aggressive mode extras ------------------------------------------

if [[ "$MODE" == "2" ]]; then
  log "Applying aggressive OS optimizations..."

  write /etc/sysctl.d/99-numa.conf "kernel.numa_balancing = 0"
  write /etc/sysctl.d/99-kdebug.conf "kernel.kptr_restrict = 0"
  write /etc/sysctl.d/99-irq.conf "kernel.irqchip.split = 1"
  write /etc/sysctl.d/99-vfs.conf "vm.vfs_cache_pressure = 50"
  write /etc/sysctl.d/99-netq.conf \
"net.core.rps_sock_flow_entries = 32768
net.core.netdev_max_backlog = 16384"
  write /etc/sysctl.d/99-swap.conf "vm.swappiness = 10"
  write /etc/sysctl.d/99-sched.conf \
"kernel.sched_min_granularity_ns = 10000000
kernel.sched_wakeup_granularity_ns = 15000000"

  # Kernel boot flags
  append_once 'GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT nohz_full=all transparent_hugepage=never"' /etc/default/grub
  grub-mkconfig -o /boot/grub/grub.cfg
fi

# --- 12. Reload sysctl ----------------------------------------------------

sysctl --system >/dev/null 2>&1 || warn "sysctl reload issues."

# --- Summary --------------------------------------------------------------

log "Done. Applied: $MODE_NAME"
warn "Reboot recommended."
