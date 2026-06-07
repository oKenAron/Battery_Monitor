#!/bin/bash
# =============================================================================
# battery_monitor.sh — 双电池状态记录脚本
# 路径建议: ~/scripts/battery_monitor.sh
# =============================================================================

set -euo pipefail

# ── 配置区 ────────────────────────────────────────────────────────────────────
LOG_DIR="${BATTERY_LOG_DIR:-$HOME/.local/share/battery_monitor}"
LOG_FILE="$LOG_DIR/history.csv"
MAX_LINES="${BATTERY_LOG_MAX_LINES:-10000}"
POWER_SUPPLY_DIR="/sys/class/power_supply"
# ─────────────────────────────────────────────────────────────────────────────

log_warn() { echo "[WARN] $*" >&2; }
log_err()  { echo "[ERROR] $*" >&2; }

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

# ── 数据采集 ──────────────────────────────────────────────────────────────────

collect_battery_data() {
    local total_now=0
    local total_full=0
    local global_status="Unknown"
    local has_charging=0 has_discharging=0 has_full=0

    # 每块电池的数据存入关联数组
    declare -A bat_now bat_full bat_percent bat_status
    local found_bats=()

    local bat
    for bat in "$POWER_SUPPLY_DIR"/BAT*; do
        [[ -d "$bat" ]] || continue
        local bat_name
        bat_name=$(basename "$bat")

        local now full status pct
        now=$(read_sysfs "$bat_name" "energy_now" 0)
        full=$(read_sysfs "$bat_name" "energy_full" 0)
        status=$(read_sysfs "$bat_name" "status" "Unknown")

        if [[ "$full" -le 0 ]]; then
            log_warn "$bat_name energy_full=$full，跳过此电池"
            continue
        fi

        # 各电池独立百分比
        pct=$(echo "scale=2; ($now * 100) / $full" | bc)
        # 补全前导零：.79 → 0.79
        [[ "$pct" == .* ]] && pct="0$pct"

        bat_now["$bat_name"]=$now
        bat_full["$bat_name"]=$full
        bat_percent["$bat_name"]=$pct
        bat_status["$bat_name"]=$status

        total_now=$((total_now + now))
        total_full=$((total_full + full))
        found_bats+=("$bat_name")

        case "$status" in
            Charging)    has_charging=1 ;;
            Discharging) has_discharging=1 ;;
            Full)        has_full=1 ;;
        esac
    done

    if [[ ${#found_bats[@]} -eq 0 ]]; then
        log_err "未找到任何有效电池，退出"
        exit 1
    fi

    # 合并总百分比
    local total_percent
    if [[ "$total_full" -le 0 ]]; then
        log_warn "total_full=0，记录为 0.00"
        total_percent="0.00"
    else
        total_percent=$(echo "scale=2; ($total_now * 100) / $total_full" | bc)
    fi

    # 合并状态
    if   [[ $has_charging    -eq 1 ]]; then global_status="Charging"
    elif [[ $has_discharging -eq 1 ]]; then global_status="Discharging"
    elif [[ $has_full        -eq 1 ]]; then global_status="Full"
    fi

    # ── 输出：用 | 分隔各段，per-battery 数据用 ; 分隔多个电池 ──────────────
    # 格式: total_percent|global_status|bat_name:now:full:pct:status;bat_name:...
    local per_bat_str=""
    for b in "${found_bats[@]}"; do
        [[ -n "$per_bat_str" ]] && per_bat_str+=";"
        per_bat_str+="${b}:${bat_now[$b]}:${bat_full[$b]}:${bat_percent[$b]}:${bat_status[$b]}"
    done

    echo "$total_percent|$global_status|$total_now|$total_full|$per_bat_str"
}

# ── 日志表头（动态，根据实际电池生成）────────────────────────────────────────

build_header() {
    # $@: 电池名列表，如 BAT0 BAT1
    local header="timestamp,total_percent,status,total_now_mwh,total_full_mwh"
    for b in "$@"; do
        header+=",${b}_percent,${b}_now_mwh,${b}_full_mwh,${b}_status"
    done
    echo "$header"
}

# ── 日志轮转 ──────────────────────────────────────────────────────────────────

rotate_log_if_needed() {
    [[ -f "$LOG_FILE" ]] || return 0
    local lines
    lines=$(wc -l < "$LOG_FILE")
    if [[ "$lines" -gt "$MAX_LINES" ]]; then
        local tmp="${LOG_FILE}.tmp"
        head -n 1 "$LOG_FILE" > "$tmp"
        tail -n "$MAX_LINES" "$LOG_FILE" >> "$tmp"
        mv "$tmp" "$LOG_FILE"
        log_warn "日志超过 $MAX_LINES 行，已截断旧记录"
    fi
}

# ── 主流程 ────────────────────────────────────────────────────────────────────

main() {
    mkdir -p "$LOG_DIR"
    rotate_log_if_needed

    local result
    result=$(collect_battery_data)

    local total_percent global_status total_now total_full per_bat_str
    IFS='|' read -r total_percent global_status total_now total_full per_bat_str <<< "$result"

    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # 解析 per-battery 数据
    declare -A p_now p_full p_pct p_status
    local bat_names=()
    local entry
    IFS=';' read -ra entries <<< "$per_bat_str"
    for entry in "${entries[@]}"; do
        IFS=':' read -r bname bnow bfull bpct bstatus <<< "$entry"
        bat_names+=("$bname")
        p_now["$bname"]=$bnow
        p_full["$bname"]=$bfull
        p_pct["$bname"]=$bpct
        p_status["$bname"]=$bstatus
    done

    # 写表头（仅当文件不存在时）
    if [[ ! -f "$LOG_FILE" ]]; then
        build_header "${bat_names[@]}" > "$LOG_FILE"
    fi

    # 构造 CSV 行
    local total_now_mwh total_full_mwh
    total_now_mwh=$(echo "scale=1; $total_now / 1000" | bc)
    total_full_mwh=$(echo "scale=1; $total_full / 1000" | bc)

    local row="$timestamp,$total_percent,$global_status,$total_now_mwh,$total_full_mwh"
    local stdout_per=""
    for b in "${bat_names[@]}"; do
        local now_mwh full_mwh
        now_mwh=$(echo "scale=1; ${p_now[$b]} / 1000" | bc)
        full_mwh=$(echo "scale=1; ${p_full[$b]} / 1000" | bc)
        row+=",$( echo "${p_pct[$b]}" ),$now_mwh,$full_mwh,${p_status[$b]}"
        stdout_per+=" | $b: ${p_pct[$b]}% ${p_status[$b]} ${now_mwh}/${full_mwh}mWh"
    done

    echo "$row" >> "$LOG_FILE"

    # stdout 调试输出
    echo "[$timestamp] total: $total_percent% $global_status$stdout_per"
}

main "$@"
