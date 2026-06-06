#!/bin/bash
# =============================================================================
# battery_monitor.sh — 双电池状态记录脚本
# 路径建议: ~/scripts/battery_monitor.sh
# =============================================================================

set -euo pipefail

# ── 配置区 ────────────────────────────────────────────────────────────────────
LOG_DIR="${BATTERY_LOG_DIR:-$HOME/.local/share/battery_monitor}"
LOG_FILE="$LOG_DIR/history.csv"
MAX_LINES="${BATTERY_LOG_MAX_LINES:-10000}"   # 超出后保留最新的 N 行
POWER_SUPPLY_DIR="/sys/class/power_supply"
# ─────────────────────────────────────────────────────────────────────────────

# ── 工具函数 ──────────────────────────────────────────────────────────────────

log_warn() { echo "[WARN] $*" >&2; }
log_err()  { echo "[ERROR] $*" >&2; }

# 安全读取 sysfs 文件，文件不存在或不可读时返回默认值 $3
read_sysfs() {
    local bat="$1" field="$2" default="${3:-0}"
    local path="$POWER_SUPPLY_DIR/$bat/$field"
    if [[ -r "$path" ]]; then
        cat "$path"
    else
        log_warn "无法读取 $path，使用默认值 $default"
        echo "$default"
    fi
}

# 检查电池是否物理存在
bat_exists() {
    [[ -d "$POWER_SUPPLY_DIR/$1" ]]
}

# ── 数据采集 ──────────────────────────────────────────────────────────────────

collect_battery_data() {
    local total_now=0
    local total_full=0
    local found_bats=()
    local global_status="Unknown"

    # 自动发现所有 BAT* 设备，不硬编码数量
    local bat
    for bat in "$POWER_SUPPLY_DIR"/BAT*; do
        [[ -d "$bat" ]] || continue
        local bat_name
        bat_name=$(basename "$bat")

        local now full
        now=$(read_sysfs "$bat_name" "energy_now" 0)
        full=$(read_sysfs "$bat_name" "energy_full" 0)

        # 跳过 full=0 的电池，避免除零且通常表示传感器故障
        if [[ "$full" -le 0 ]]; then
            log_warn "$bat_name energy_full=$full，跳过此电池"
            continue
        fi

        total_now=$((total_now + now))
        total_full=$((total_full + full))
        found_bats+=("$bat_name")
    done

    # 没有找到任何有效电池
    if [[ ${#found_bats[@]} -eq 0 ]]; then
        log_err "未找到任何有效电池，退出"
        exit 1
    fi

    # ── 计算总百分比 ────────────────────────────────────────────────────────
    local percent
    if [[ "$total_full" -le 0 ]]; then
        log_warn "total_full=$total_full，无法计算百分比，记录为 0.00"
        percent="0.00"
    else
        percent=$(echo "scale=2; ($total_now * 100) / $total_full" | bc)
    fi

    # ── 合并状态：优先级 Charging > Discharging > Full > Unknown ────────────
    # 只要有一块在充电，整体就算充电；全部满电才算满；其余算放电
    local has_charging=0 has_discharging=0 has_full=0
    for bat_name in "${found_bats[@]}"; do
        local s
        s=$(read_sysfs "$bat_name" "status" "Unknown")
        case "$s" in
            Charging)    has_charging=1 ;;
            Discharging) has_discharging=1 ;;
            Full)        has_full=1 ;;
        esac
    done

    if   [[ $has_charging    -eq 1 ]]; then global_status="Charging"
    elif [[ $has_discharging -eq 1 ]]; then global_status="Discharging"
    elif [[ $has_full        -eq 1 ]]; then global_status="Full"
    fi

    # 输出供调用方使用的变量（通过 nameref 或直接 echo 均可）
    # 这里选择 echo 分隔字段，由主函数解析
    echo "$percent|$global_status|${found_bats[*]}|$total_now|$total_full"
}

# ── 日志轮转 ──────────────────────────────────────────────────────────────────

rotate_log_if_needed() {
    [[ -f "$LOG_FILE" ]] || return 0
    local lines
    lines=$(wc -l < "$LOG_FILE")
    if [[ "$lines" -gt "$MAX_LINES" ]]; then
        local tmp="${LOG_FILE}.tmp"
        # 保留 CSV 头 + 最新 MAX_LINES 行数据
        head -n 1 "$LOG_FILE" > "$tmp"
        tail -n "$MAX_LINES" "$LOG_FILE" >> "$tmp"
        mv "$tmp" "$LOG_FILE"
        log_warn "日志超过 $MAX_LINES 行，已截断旧记录"
    fi
}

# ── 初始化日志文件 ────────────────────────────────────────────────────────────

init_log() {
    mkdir -p "$LOG_DIR"
    if [[ ! -f "$LOG_FILE" ]]; then
        echo "timestamp,percent,status,batteries,energy_now_mwh,energy_full_mwh" > "$LOG_FILE"
    fi
}

# ── 主流程 ────────────────────────────────────────────────────────────────────

main() {
    init_log
    rotate_log_if_needed

    local result
    result=$(collect_battery_data)

    local percent status bats total_now total_full
    IFS='|' read -r percent status bats total_now total_full <<< "$result"

    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # energy_now / energy_full 单位是 µWh，转 mWh 方便阅读
    local now_mwh full_mwh
    now_mwh=$(echo "scale=1; $total_now / 1000" | bc)
    full_mwh=$(echo "scale=1; $total_full / 1000" | bc)

    echo "$timestamp,$percent,$status,\"$bats\",$now_mwh,$full_mwh" >> "$LOG_FILE"

    # 同时输出到 stdout 方便手动调试
    echo "[$timestamp] $percent% | $status | bats: $bats | ${now_mwh}/${full_mwh} mWh"
}

main "$@"
