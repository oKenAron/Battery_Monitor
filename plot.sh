#!/bin/bash
# plot.sh — 终端可视化工具
# 用法: ./plot.sh [选项]
#   -n N     显示最近 N 条记录（默认 48，约 2.4 小时）
#   -m       使用 gnuplot 模式（需要安装 gnuplot）
#   -t       使用 termgraph 模式（需要安装 python-termgraph）
#   -h       显示帮助
set -euo pipefail

LOG_FILE="${BATTERY_LOG_DIR:-$HOME/.local/share/battery_monitor}/history.csv"
N=48
MODE="auto"

usage() {
    sed -n '2,8p' "$0" | sed 's/^# //'
    exit 0
}

while getopts "n:mth" opt; do
    case $opt in
        n) N="$OPTARG" ;;
        m) MODE="gnuplot" ;;
        t) MODE="termgraph" ;;
        h) usage ;;
        *) usage ;;
    esac
done

[[ -f "$LOG_FILE" ]] || { echo "日志文件不存在: $LOG_FILE"; exit 1; }

# 自动选择可用工具
if [[ "$MODE" == "auto" ]]; then
    if command -v gnuplot &>/dev/null; then
        MODE="gnuplot"
    elif command -v termgraph &>/dev/null; then
        MODE="termgraph"
    else
        MODE="ascii"
    fi
fi

# 提取最近 N 行数据（跳过 CSV 头）
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
tail -n "$N" <(tail -n +2 "$LOG_FILE") > "$TMP"

# ── gnuplot 模式 ──────────────────────────────────────────────────────────────
if [[ "$MODE" == "gnuplot" ]]; then
    gnuplot <<EOF
set terminal dumb size 100,25 ansi
set title "Battery History (last $N records)"
set xlabel "Time"
set ylabel "Charge %"
set yrange [0:105]
set datafile separator ","
set xdata time
set timefmt "%Y-%m-%d %H:%M:%S"
set format x "%H:%M"
set xtics rotate by -30
plot "$TMP" using 1:2 with linespoints pt 7 ps 0.5 lc rgb "green" title "Charge %"
EOF

# ── termgraph 模式 ────────────────────────────────────────────────────────────
elif [[ "$MODE" == "termgraph" ]]; then
    # termgraph 需要 "label\tvalue" 格式，每隔几条取一个点避免太密
    step=$(( N / 20 + 1 ))
    awk -F',' -v step="$step" 'NR % step == 0 {
        # 取时间的 HH:MM 部分作为标签
        split($1, t, " "); label=t[2]
        printf "%s\t%s\n", label, $2
    }' "$TMP" | termgraph --title "Battery History" --color green

# ── 纯 ASCII 降级模式 ─────────────────────────────────────────────────────────
else
    echo "⚠️  未找到 gnuplot 或 termgraph，使用内置 ASCII 图表"
    echo "   安装建议: pacman -S gnuplot  或  pip install termgraph"
    echo ""

    # 读取数据，画一个简单的纵向 ASCII 折线图
    # 图宽 60 列，图高 20 行
    WIDTH=60
    HEIGHT=20

    mapfile -t percents < <(awk -F',' '{print int($2 + 0.5)}' "$TMP")
    total=${#percents[@]}

    if [[ $total -eq 0 ]]; then echo "无数据"; exit 1; fi

    # 找最大最小值
    min=100 max=0
    for p in "${percents[@]}"; do
        (( p < min )) && min=$p
        (( p > max )) && max=$p
    done
    range=$(( max - min ))
    (( range == 0 )) && range=1

    # 降采样到 WIDTH 个点
    declare -a pts
    for (( x=0; x<WIDTH; x++ )); do
        idx=$(( x * total / WIDTH ))
        pts[$x]=${percents[$idx]}
    done

    # 逐行打印
    for (( row=HEIGHT; row>=0; row-- )); do
        threshold=$(( min + row * range / HEIGHT ))
        # Y 轴刻度
        if (( row % 5 == 0 )); then
            printf "%3d%% |" $threshold
        else
            printf "     |"
        fi
        for (( x=0; x<WIDTH; x++ )); do
            v=${pts[$x]}
            next_threshold=$(( min + (row+1) * range / HEIGHT ))
            if (( v >= threshold && v < next_threshold )); then
                echo -n "•"
            elif (( v >= next_threshold )); then
                echo -n " "
            else
                echo -n " "
            fi
        done
        echo ""
    done

    # X 轴
    printf "     +"
    printf '%0.s-' $(seq 1 $WIDTH)
    echo ""

    # 首尾时间标签
    first_time=$(head -1 "$TMP" | cut -d',' -f1 | cut -d' ' -f2 | cut -c1-5)
    last_time=$(tail -1  "$TMP" | cut -d',' -f1 | cut -d' ' -f2 | cut -c1-5)
    printf "      %-${WIDTH}s\n" "$first_time → $last_time"

    # 最后一行状态
    last_line=$(tail -1 "$TMP")
    last_pct=$(echo "$last_line" | cut -d',' -f2)
    last_sts=$(echo "$last_line" | cut -d',' -f3)
    echo ""
    echo "  当前: ${last_pct}% | 状态: ${last_sts}"
fi
