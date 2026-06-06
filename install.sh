#!/bin/bash
# install.sh — 一键部署 battery_monitor
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$HOME/scripts"
SYSTEMD_DIR="$HOME/.config/systemd/user"

echo "==> 创建目录..."
mkdir -p "$SCRIPTS_DIR" "$SYSTEMD_DIR"

echo "==> 安装主脚本..."
cp "$SCRIPT_DIR/battery_monitor.sh" "$SCRIPTS_DIR/battery_monitor.sh"
chmod +x "$SCRIPTS_DIR/battery_monitor.sh"

echo "==> 安装 systemd 单元..."
cp "$SCRIPT_DIR/systemd/battery-monitor.service" "$SYSTEMD_DIR/"
cp "$SCRIPT_DIR/systemd/battery-monitor.timer"   "$SYSTEMD_DIR/"

echo "==> 检查依赖..."
for cmd in bc awk; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "[WARN] 未找到 $cmd，请先安装（pacman -S bc gawk）"
    fi
done

echo "==> 重载 systemd 并启动 timer..."
systemctl --user daemon-reload
systemctl --user enable --now battery-monitor.timer

echo ""
echo "✅ 安装完成！"
echo ""
echo "常用命令："
echo "  查看 timer 状态   : systemctl --user status battery-monitor.timer"
echo "  手动触发一次      : systemctl --user start battery-monitor.service"
echo "  查看最近日志      : journalctl --user -u battery-monitor.service -n 20"
echo "  查看采集数据      : tail -f ~/.local/share/battery_monitor/history.csv"
