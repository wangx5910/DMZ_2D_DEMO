extends Node
## RaidLog · 埋点与日志导出
##
## 每局自动记录关键事件，跑测结束后导出成可读文本 + CSV，用于回看数据改数值。
## 导出位置：user://logs/（Godot 里 项目 → 打开用户数据文件夹 可直达）

signal event_logged(entry: Dictionary)

var _events: Array[Dictionary] = []
var _raid_start_msec: int = 0
var _session_id: String = ""

## 汇总统计
var stats := {}

func _ready() -> void:
	_session_id = Time.get_datetime_string_from_system().replace(":", "-").replace(" ", "_")

func start_raid() -> void:
	_events.clear()
	stats = {
		"containers_opened": 0,
		"slots_searched": 0,
		"slots_empty": 0,
		"items_taken": 0,
		"value_taken": 0,
		"value_left_behind": 0,   ## 关闭面板时容器里还剩多少钱没拿（取舍强度指标）
		"searches_aborted": 0,
		"shots_fired": 0,
		"shots_hit": 0,
		"reloads": 0,
		"enemies_killed": 0,
		"vehicle_boards": 0,
		"vehicles_destroyed": 0,
		"damage_taken": 0.0,
		"distance_walked": 0.0,
		"time_sprinting": 0.0,
		"time_crouching": 0.0,
		"time_searching": 0.0,
		"time_aiming": 0.0,
	}
	_raid_start_msec = Time.get_ticks_msec()
	log_event("raid_start", {"tuning": Tuning.snapshot()})

func t() -> float:
	return (Time.get_ticks_msec() - _raid_start_msec) / 1000.0

func log_event(kind: String, data: Dictionary = {}) -> void:
	var entry := {"t": snappedf(t(), 0.01), "kind": kind, "data": data}
	_events.append(entry)
	event_logged.emit(entry)

func bump(key: String, amount: Variant = 1) -> void:
	if stats.has(key):
		stats[key] += amount

func end_raid(reason: String = "manual") -> String:
	log_event("raid_end", {"reason": reason, "stats": stats.duplicate()})
	return export_logs()

func export_logs() -> String:
	DirAccess.make_dir_recursive_absolute("user://logs")
	var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace(" ", "_")
	var base := "user://logs/raid_%s" % stamp

	# 1) 人读的摘要
	var txt := PackedStringArray()
	txt.append("=== 海湾城 2D Demo · 跑测记录 ===")
	txt.append("会话: %s" % _session_id)
	txt.append("总时长: %.1f 秒" % t())
	txt.append("")
	txt.append("--- 汇总 ---")
	for k in stats:
		var v = stats[k]
		txt.append("%-20s %s" % [k, ("%.1f" % v) if v is float else str(v)])
	txt.append("")
	txt.append("--- 关键参数 ---")
	for k in Tuning.snapshot():
		txt.append("%-28s %s" % [k, str(Tuning.get(k))])
	txt.append("")
	txt.append("--- 事件流 ---")
	for e in _events:
		txt.append("[%7.2fs] %-18s %s" % [e["t"], e["kind"], JSON.stringify(e["data"])])
	var f := FileAccess.open(base + ".txt", FileAccess.WRITE)
	if f:
		f.store_string("\n".join(txt))
		f.close()

	# 2) 机读 CSV（事件流）
	var csv := PackedStringArray(["t,kind,payload"])
	for e in _events:
		csv.append("%.2f,%s,\"%s\"" % [e["t"], e["kind"], JSON.stringify(e["data"]).replace("\"", "'")])
	var f2 := FileAccess.open(base + ".csv", FileAccess.WRITE)
	if f2:
		f2.store_string("\n".join(csv))
		f2.close()

	return ProjectSettings.globalize_path(base + ".txt")
