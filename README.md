# battery_monitor

双电池（及多电池）状态记录与终端可视化工具。  
适用于 Arch Linux / systemd 环境，无第三方依赖即可运行核心功能。

---

## 文件结构

```
battery_monitor/
├── battery_monitor.sh        # 主采集脚本
├── plot.sh                   # 终端可视化脚本
├── install.sh                # 一键安装脚本
├── systemd/
│   ├── battery-monitor.service
│   └── battery-monitor.timer
└── README.md
```

---

## 快速开始

```bash
git clone <repo> battery_monitor
cd battery_monitor
bash install.sh
```

安装完成后每 3 分钟自动记录一次，数据写入：

```
~/.local/share/battery_monitor/history.csv
```

---

## 核心设计决策

### 为什么用 `energy_now / energy_full` 而不是 `capacity`？

`capacity`（直接百分比）由内核计算，精度为整数，且双电池各自独立报告。  
把两个百分比直接平均会在电池容量不对称时产生误差。

正确做法是把两块电池当作一个大电池：

```
percent = (BAT0_now + BAT1_now) / (BAT0_full + BAT1_full) × 100
```

这样 BAT0（大容量）和 BAT1（小容量）各自的贡献按物理量加权，结果准确。

### 自动发现电池，不硬编码数量

脚本遍历 `/sys/class/power_supply/BAT*`，支持单电池、双电池、三电池等任意情况，插拔扩展坞电池不会导致脚本崩溃。

### 状态合并优先级

| 场景 | 合并状态 |
|---|---|
| 任意一块在充电 | `Charging` |
| 无充电但有放电 | `Discharging` |
| 全部满电 | `Full` |
| 其他 | `Unknown` |

### `energy_full` 为零时的处理

传感器故障或热插拔瞬间可能导致 `energy_full = 0`。  
脚本检测到此情况时跳过该电池并写入警告到 stderr，不中断记录流程。

---

## 日志格式

CSV 文件，UTF-8，表头**动态生成**（根据实际检测到的电池数量）：

```
timestamp,total_percent,status,total_now_mwh,total_full_mwh,BAT0_percent,BAT0_now_mwh,BAT0_full_mwh,BAT0_status,BAT1_percent,BAT1_now_mwh,BAT1_full_mwh,BAT1_status
```

示例行：

```
2026-06-06 14:03:00,78.72,Charging,48180.0,61200.0,80.00,48000.0,60000.0,Discharging,15.00,180.0,1200.0,Charging
2026-06-06 14:06:00,78.21,Charging,47880.0,61200.0,79.50,47700.0,60000.0,Discharging,15.00,180.0,1200.0,Charging
```

字段说明：

| 字段 | 说明 |
|---|---|
| `total_percent` | 两块电池合并后的加权百分比 |
| `status` | 合并状态（Charging / Discharging / Full） |
| `total_now_mwh` / `total_full_mwh` | 合并总电量，单位 mWh |
| `BATx_percent` | 该电池独立百分比 |
| `BATx_now_mwh` / `BATx_full_mwh` | 该电池当前/满电量，单位 mWh |
| `BATx_status` | 该电池独立状态 |

表头在首次创建日志文件时自动生成，列数与检测到的电池数一致，不需要手动配置。

### 日志轮转

超过 `BATTERY_LOG_MAX_LINES`（默认 10000 行）时，自动保留最新 10000 行。  
10000 行 × 3 分钟 ≈ 约 20 天的历史，文件大小约 800 KB。

---

## 可视化

```bash
# 自动选择可用工具，显示最近 48 条（约 2.4 小时）
bash plot.sh

# 显示最近 200 条（约 10 小时）
bash plot.sh -n 200

# 强制使用 gnuplot（终端折线图，推荐）
bash plot.sh -m

# 强制使用 termgraph（ASCII 柱状图）
bash plot.sh -t
```

工具选择优先级（自动模式）：`gnuplot` > `termgraph` > 内置 ASCII 图

### 安装可选依赖

```bash
# gnuplot（推荐，折线图更直观）
pacman -S gnuplot

# termgraph（Python，柱状图风格）
pip install termgraph
```

---

## systemd 管理

```bash
# 查看 timer 下次触发时间
systemctl --user status battery-monitor.timer

# 立即手动运行一次（测试用）
systemctl --user start battery-monitor.service

# 查看运行日志（包含警告信息）
journalctl --user -u battery-monitor.service -n 30

# 停止自动记录
systemctl --user disable --now battery-monitor.timer

# 重新启动
systemctl --user enable --now battery-monitor.timer
```

### `Persistent=true` 的作用

Timer 配置了 `Persistent=true`：若系统挂起期间错过了触发点，恢复后会立即补跑一次，不留数据空洞。

---

## 环境变量配置

无需修改脚本，通过环境变量覆盖默认值：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `BATTERY_LOG_DIR` | `~/.local/share/battery_monitor` | 日志目录 |
| `BATTERY_LOG_MAX_LINES` | `10000` | 日志最大行数 |

在 service 文件中修改：

```ini
[Service]
Environment=BATTERY_LOG_DIR=/var/log/battery_monitor
Environment=BATTERY_LOG_MAX_LINES=5000
```

---

## 依赖

| 工具 | 用途 | 是否必须 |
|---|---|---|
| `bash` ≥ 4.0 | 脚本运行环境 | ✅ 必须 |
| `bc` | 浮点百分比计算 | ✅ 必须 |
| `systemd` | 定时触发 | ✅ 必须 |
| `gnuplot` | 终端折线图 | 可选 |
| `termgraph` | ASCII 柱状图 | 可选 |

`bc` 在 Arch 上通常已预装，否则：`pacman -S bc`

---

## 故障排查

**日志文件为空或只有表头**

```bash
# 手动运行脚本，查看 stderr 输出
bash ~/scripts/battery_monitor.sh
```

**`energy_full = 0` 警告频繁出现**

检查内核是否正确识别电池：

```bash
ls /sys/class/power_supply/
cat /sys/class/power_supply/BAT1/energy_full
```

**图表显示乱码**

确认终端支持 UTF-8，或改用纯 ASCII 模式（`plot.sh` 不加参数，自动降级）。

**systemd timer 不触发**

```bash
systemctl --user daemon-reload
systemctl --user restart battery-monitor.timer
journalctl --user -u battery-monitor.timer
```
