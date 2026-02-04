#!/usr/bin/env bash
# CachyClean - Safe System Cache & Temp Cleaner for CachyOS
# Lets the user choose individual cleanup tasks or run everything automatically.

set -euo pipefail

log() { printf "\n[+] %s\n" "$*"; }
warn() { printf "\n[!] %s\n" "$*"; }
ask() { read -rp "$1 [y/N]: " ans; [[ "${ans:-n}" =~ ^[Yy]$ ]]; }

# --- Cleanup functions ----------------------------------------------------

clean_tmp() {
  log "Cleaning /tmp and /var/tmp..."
  rm -rf /tmp/* /var/tmp/* 2>/dev/null || true
}

clean_pacman_cache() {
  log "Cleaning pacman cache..."
  pacman -Scc --noconfirm || warn "Pacman cache clean failed."
}

clean_journal() {
  log "Vacuuming journal logs (7 days)..."
  journalctl --vacuum-time=7d || warn "Journal vacuum failed."
}

clean_user_cache() {
  log "Cleaning user cache (~/.cache)..."
  rm -rf "$HOME/.cache/"* 2>/dev/null || true
}

clean_thumbnails() {
  log "Cleaning thumbnail cache..."
  rm -rf "$HOME/.cache/thumbnails/"* 2>/dev/null || true
}

clean_core_dumps() {
  log "Cleaning systemd coredumps..."
  rm -rf /var/lib/systemd/coredump/* 2>/dev/null || true
}

clean_var_cache() {
  log "Cleaning /var/cache..."
  rm -rf /var/cache/* 2>/dev/null || true
}

trim_ssd() {
  log "Running fstrim on all SSDs..."
  fstrim -av || warn "fstrim failed."
}

# --- Menu -----------------------------------------------------------------

clear
echo "CachyClean - System Cache & Temp Cleaner"
echo "Choose what to clean:"
echo "1) /tmp and /var/tmp"
echo "2) Pacman cache"
echo "3) Journal logs"
echo "4) User cache (~/.cache)"
echo "5) Thumbnail cache"
echo "6) Systemd coredumps"
echo "7) /var/cache"
echo "8) SSD trim (fstrim)"
echo "9) Clean EVERYTHING automatically"
echo "0) Exit"
echo

read -rp "Enter your choices (e.g. 1 3 4 or 9): " -a CHOICES

# --- Build summary --------------------------------------------------------

SUMMARY=""

for c in "${CHOICES[@]}"; do
  case "$c" in
    1) SUMMARY+="\n- Clean /tmp and /var/tmp" ;;
    2) SUMMARY+="\n- Clean pacman cache" ;;
    3) SUMMARY+="\n- Vacuum journal logs" ;;
    4) SUMMARY+="\n- Clean user cache (~/.cache)" ;;
    5) SUMMARY+="\n- Clean thumbnail cache" ;;
    6) SUMMARY+="\n- Clean systemd coredumps" ;;
    7) SUMMARY+="\n- Clean /var/cache" ;;
    8) SUMMARY+="\n- Run fstrim on SSDs" ;;
    9) SUMMARY+="\n- Clean EVERYTHING (all tasks)" ;;
    0) exit 0 ;;
    *) warn "Unknown option: $c" ;;
  esac
done

echo -e "\nYou selected:$SUMMARY"
ask "Continue?" || { warn "Aborted."; exit 1; }

# --- Execute tasks --------------------------------------------------------

run_all=false
for c in "${CHOICES[@]}"; do [[ "$c" == "9" ]] && run_all=true; done

if $run_all; then
  clean_tmp
  clean_pacman_cache
  clean_journal
  clean_user_cache
  clean_thumbnails
  clean_core_dumps
  clean_var_cache
  trim_ssd
else
  for c in "${CHOICES[@]}"; do
    case "$c" in
      1) clean_tmp ;;
      2) clean_pacman_cache ;;
      3) clean_journal ;;
      4) clean_user_cache ;;
      5) clean_thumbnails ;;
      6) clean_core_dumps ;;
      7) clean_var_cache ;;
      8) trim_ssd ;;
    esac
  done
fi

log "Cleanup complete!"
