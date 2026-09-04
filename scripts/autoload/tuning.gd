extends Node
## Tuning · 全局可调参数中心
##
## 所有影响手感与节奏的数值都在这里，调试面板直接读写本节点。
## 修改立即生效，无需重启。默认值可从 res://data/tuning.json 覆盖。

signal value_changed(key: String, value: Variant)

# ── 移动 3C ──────────────────────────────────────────────
## 单位：像素/秒。1 米约等于 32 像素。
var walk_speed: float = 150.0
var sprint_speed: float = 290.0
var crouch_speed: float = 78.0
## 加速度 / 刹车（像素/秒²）。越大越"贴手"，越小越"滑"。
var accel: float = 1400.0
var decel: float = 1800.0
## 冲刺时的转向惩罚：1.0 = 无惩罚，0.5 = 转身速度腰斩
var sprint_turn_penalty: float = 0.55

# ── 体力 ────────────────────────────────────────────────
var stamina_max: float = 100.0
var stamina_drain_sprint: float = 22.0   ## 每秒
var stamina_regen: float = 16.0          ## 每秒
var stamina_regen_delay: float = 0.8     ## 停止冲刺后多久开始回
var stamina_sprint_threshold: float = 12.0 ## 低于此值不能起跑（防抽搐式点跑）

# ── 视野 ────────────────────────────────────────────────
## 扇形半角（度）。总视野角 = fov_half_angle * 2
var fov_half_angle: float = 50.0
var vision_range: float = 460.0
## 蹲下视野变化：范围略缩、角度略增（贴地观察）
var crouch_vision_range_mul: float = 0.86
var crouch_fov_bonus: float = 8.0
## 冲刺时视野收窄（管道视觉）
var sprint_fov_penalty: float = 12.0
## 近身圆形视野半径（像素）。在扇形之外，以自身为圆心额外点亮一圈 360° 视野，
## 消除身后盲区（也让你贴脸时总能看见附近的敌人/物品）。设 0 = 只保留扇形。
var proximity_radius: float = 160.0
## 扇形边缘羽化宽度（像素），做柔和过渡而非硬边
var vision_edge_feather: float = 46.0
## 视野射线条数——越多越精细越吃性能
var vision_ray_count: int = 120
## 视野外的静态地形亮度（0 = 全黑，1 = 全亮）
## 【小皮假设】纯 2D 俯视全黑会让玩家找不到路，故地形压暗常亮、动态实体严格遮蔽
var terrain_memory_brightness: float = 0.45

# ── 搜刮 ────────────────────────────────────────────────
## 逐格搜刮：每格基础耗时（秒），实际 = base * 容器档位系数
var search_time_per_slot: float = 1.1
var search_time_mul_l1: float = 0.8
var search_time_mul_l2: float = 1.0
var search_time_mul_l3: float = 1.35
var search_time_mul_l4: float = 1.9
## L4 免保柜的额外破解前置读条（秒）
var l4_crack_time: float = 6.0
## AI 搜刮相对玩家的耗时倍率（>1 更慢）。破解/逐格揭示都乘这个
var ai_search_time_mul: float = 1.2
## AI 每件装进背包的额外时间（玩家点取是瞬间，AI 额外慢一截）
var ai_take_time_per_item: float = 0.55
## 搜刮时移动是否中断
var search_break_on_move: bool = true
## 搜刮时移速倍率（若不中断）
var search_move_speed_mul: float = 0.0
## 交互距离（像素）
var interact_range: float = 58.0
## 搜刮中的角色是否被减速的转向锁定
var search_lock_rotation: bool = false

# ── 背包 ────────────────────────────────────────────────
var backpack_cols: int = 10
var backpack_rows: int = 6
## 网络存储箱 / 寄存预览（开局 8×5；之后每开一波新提交点再加一块 8×5）
var stash_cols: int = 8
var stash_rows: int = 5

# ── 枪械（本版 M4）─────────────────────────────────────
## 详细枪械数值在 data/weapons.json，这里只放需要边跑边调的运行时项。
## 后坐视觉抖动强度倍率（作用于准星与相机微抖）
var recoil_visual_mul: float = 1.0
## 准星大小随扩散放大的倍率（可读性调节）
var crosshair_scale: float = 1.0

# ── 生命与伤害 ─────────────────────────────────────────
var player_hp_max: float = 100.0
## 脱战回血：距上次开火/受击满 ooc_regen_delay 秒后，开始每秒回复
var ooc_regen_delay: float = 10.0
var ooc_regen_per_sec: float = 8.0
## 大锤指定：怪物血量与伤害都按系数**远低于**玩家（体型/移速与玩家相同）
var enemy_hp_mul: float = 0.45      ## 小兵血量 = 玩家 × 系数
var enemy_damage_mul: float = 0.18  ## 小兵伤害 = 同口径武器 × 系数（对真人玩家）
var monster_vs_ai_mul: float = 0.0  ## 小兵打 AI 玩家的伤害倍率（0 = 无伤）
var ai_vs_monster_damage: float = 100.0  ## AI 玩家打小兵：每发固定伤害
## 命中部位/护甲留空，本版只做整体伤害

# ── 怪物 AI ─────────────────────────────────────────────
## 小兵视野（照鸭科夫：比玩家略短，但一旦发现会持续追）
var enemy_fov_half_angle: float = 55.0
var enemy_vision_range: float = 400.0
## 察觉延迟：进入视野后需持续这么久才确认发现（给玩家反应窗口）
var enemy_notice_time: float = 0.35
## 追击：脱离视野后仍追多久 / 追出多远就放弃
var enemy_chase_lose_time: float = 4.0
var enemy_chase_max_range: float = 1100.0   ## 超出此距离直接放弃
var enemy_leash_from_post: float = 1500.0    ## 离原岗位超过此距离则返回
## 交战距离：太近会后退，太远会推进
var enemy_engage_range: float = 320.0
var enemy_engage_min: float = 120.0
## 交战微移动（照鸭科夫：边打边挪，不站桩）
var enemy_strafe_interval_min: float = 0.7
var enemy_strafe_interval_max: float = 1.8
var enemy_strafe_chance: float = 0.65
## 巡逻
var enemy_patrol_speed_mul: float = 1.0      ## 巡逻倍率（1=与玩家走速一致）
var enemy_patrol_wait_min: float = 1.0
var enemy_patrol_wait_max: float = 3.0
## 听觉：枪声吸引半径（听到就去查看）
var enemy_hearing_range: float = 900.0
## 每个 POI 刷几个小兵（按 tier 缩放）
var enemies_per_poi_base: int = 6   ## 大锤要求：每个 POI 至少 6+
var enemy_spawn_tier_bonus: int = 2          ## 每高一 tier 多刷几个（tier4 = 12 个）

# ── 载具（照 COD-DMZ）────────────────────────────────────
var vehicle_hp_max: float = 420.0
## 驾驶手感：四轮模型，静止不能转向
var vehicle_max_speed: float = 620.0        ## 前进极速（≈77 米/秒，约为跑速的 2.1 倍）
var vehicle_reverse_speed: float = 210.0
var vehicle_accel: float = 340.0
var vehicle_brake: float = 780.0
var vehicle_coast: float = 150.0            ## 松油门的自然减速
var vehicle_turn_rate: float = 210.0        ## 度/秒（低速时的转向速率）
var vehicle_highspeed_turn_mul: float = 0.68 ## 高速转向衰减（防原地打转）
## 损坏
var vehicle_smoke_threshold: float = 0.55   ## 血量低于此比例开始冒烟
var vehicle_wreck_power_mul: float = 0.45   ## 空血时的动力倍率（残血跑不快）
var vehicle_crash_min_speed: float = 150.0  ## 撞墙掉血的最低速度
var vehicle_crash_damage: float = 42.0      ## 满速撞墙的伤害
## 爆炸
var vehicle_fuse_time: float = 3.2          ## 血量归零 → 爆炸的引信（跳车窗口）
var vehicle_explosion_radius: float = 190.0
var vehicle_explosion_damage: float = 85.0  ## 实测 160 时满血必死，跳车窗口就没意义了
## 投放密度（大锤要求先刷一版再调）
var vehicles_near_spawn: int = 3            ## 出生点附近
var vehicles_per_poi_outside: float = 0.55  ## 每个 POI 外部的期望数量
var vehicles_open_field: int = 14           ## 大地图空旷区

# ── 玩法流程（公共撤离点 + 飞船）──────────────────────────
## 公共撤离点：地图上几个谁都能撤的点，进入范围并停留即撤离。
var extraction_radius: float = 90.0      ## 撤离点触发半径（像素）
var extraction_hold: float = 6.0         ## 在撤离点停留多久算成功（秒）
## 飞船：开局 N 秒后刷出，地图内悬浮巡航；船内即 POI 可搜刮。
var spaceship_spawn_time: float = 180.0  ## 刷出时间（秒，约 3 分钟）
var spaceship_speed: float = 150.0       ## 巡航 / 驾驶速度（像素/秒）
var spaceship_loot_upgrade: int = 1      ## 飞船 POI 容器富度提升档数（1 = 整体升一档）
var spaceship_pillar_radius: float = 48.0   ## 传送门判定半径（≥玩家半径3倍）
var spaceship_lift_time: float = 1.0        ## 传送门读条时长（秒）
var spaceship_control_radius: float = 120.0 ## 操控室驻留判定半径（像素）
var spaceship_hijack_dwell: float = 1.2     ## 操控室驻留多久触发劫持（秒）
var spaceship_crack_hold: float = 30.0      ## 靠近破解点后的自动破解时长（秒）
var spaceship_crack_range: float = 420.0    ## 进入破解的距离（像素）
var spaceship_crack_points: int = 3         ## 破解点数量
var hijack_intel_radius: float = 1200.0     ## 劫持后附近敌人弱信息显示半径（像素）
var spaceship_orbit_radius: float = 450.0   ## 盘旋半径：飞船在玩家头顶盘旋的半径（像素），保证飞行中光柱始终在玩家视野内
var spaceship_orbit_speed: float = 0.6      ## 盘旋角速度（弧度/秒）
var enable_extraction: bool = true
var enable_spaceship: bool = true
var enable_spaceship_hijack: bool = true    ## 飞船劫持 / 破解点机制总开关
var enable_contracts: bool = true           ## 动态合约
var contract_spawn_time: float = 0.0        ## 人质任务刷出时间（已改为开局即刷，此项不再延迟）
var contract_hostage_time: float = 360.0    ## 救援人质时限（秒，接取后倒计时）
var contract_hostage_guards: int = 12       ## 人质附近驻守怪物数（越近越密）
var contract_hostage_chests: int = 5        ## 人质房紫色箱数量（另有 1 个免保级金箱）
var contract_extract_m: float = 600.0       ## 人质撤离点距离（米）
var contract_extract_radius: float = 90.0   ## 人质撤离圈半径（像素）
var contract_extract_hold: float = 8.0      ## 人质撤离驻守时长（秒）
var contract_upload_hold: float = 25.0      ## 静默上传读条（秒）
var contract_tower_hold: float = 20.0       ## 塔台劫持读条（秒）
var contract_intel_time: float = 28.0       ## 塔台成功：全图人形可见时长
var contract_fail_ping_time: float = 16.0   ## 塔台失败：反 ping 自己的时长
var contract_hit_interrupt: float = 0.55    ## 上传/占塔：受击后多久内算打断
var hostage_hp: float = 80.0
var carry_hostage_speed_mul: float = 0.82   ## 背人质时移速
var enable_phone_contracts: bool = false    ## 电话合约（搅动普通合约）· 暂时关闭「抢回人质」
var phone_contract_window: float = 10.0     ## 来电未接自动取消（秒）
var phone_contract_hold: float = 1.2        ## 长按 E 接听时长（秒）
var phone_ping_interval: float = 3.0        ## 抢回人质：小地图坐标刷新间隔
var depot_call_time: float = 40.0           ## 呼叫后多少秒提交点才出现
var depot_call_broadcast_m: float = 100.0   ## 呼叫后向附近多少米内玩家广播
var depot_ai_rush_m: float = 700.0          ## AI 赶去抢点的感知距离（米）


# ── 相机 ────────────────────────────────────────────────
var camera_zoom: float = 1.75           ## 默认拉近，人物更大
var camera_zoom_min: float = 0.65
var camera_zoom_max: float = 2.85
## 相机向鼠标方向前瞻的比例（0 = 完全锁角色）
var camera_look_ahead: float = 0.22
var camera_look_ahead_max: float = 190.0
var camera_smooth: float = 8.0

# ── 机制开关（A/B 对比用）──────────────────────────────
var enable_vision_cone: bool = true      ## 关掉 = 全图可见，用于对照
var enable_wall_occlusion: bool = true   ## 关掉 = 扇形不被墙挡
var enable_stamina: bool = true
var enable_search_progress: bool = true  ## 关掉 = 即时开箱，用于对照
var enable_grid_backpack: bool = true    ## 关掉 = 无限容量，用于对照
var enable_shooting: bool = true          ## 关掉 = 不能开火（纯搜刮跑测用）
var infinite_ammo: bool = true             ## 无限备弹（跑测默认开，弹匣与换弹流程照常）
var auto_reload_on_empty: bool = true      ## 空仓自动换弹
var show_debug_overlay: bool = false     ## 显示碰撞体/射线/交互范围
## 关卡模式：true = 2km 分区大地图；false = 单栈手工小图（快速验证 3C 用）
var use_world_map: bool = true
## 怪物开关
var enable_enemies: bool = true
var enable_vehicles: bool = true
var enemy_can_shoot: bool = true
var show_enemy_debug: bool = false   ## 头顶显示 AI 状态与视野扇形
var god_mode: bool = false           ## 玩家无敌（专心验证 AI 行为时用）
var enable_player_ai: bool = true    ## 伪玩家 AI（功利搜刮路线）
var show_enemy_players: bool = false ## 调试：强制显示敌方玩家AI（默认关=真实对战视野）
var player_ai_count: int = 2         ## 兼容旧项：优先用 squad_* 计算
## 小队：同队友善；默认 22 支 × 3 人（含玩家所在小队）
var squad_count: int = 22
var squad_size: int = 3

# ── 地表网格 / 小地图 ───────────────────────────────────
## 地表网格线：开阔地里的移动参照系（纯色地面完全感知不到位移）
var show_ground_grid: bool = true
var show_grid_labels: bool = true
var grid_fine_m: float = 50.0      ## 细格边长（米）
var grid_coarse_m: float = 250.0   ## 粗格边长（米）
## 小地图
var show_minimap: bool = true
var minimap_size: float = 260.0    ## 小地图边长（像素）
var minimap_range_m: float = 700.0 ## 小地图显示半径（米）
var minimap_rotate: bool = false   ## true = 随朝向旋转；false = 北固定（推荐，大图更易读）
## 出生点距目标免保的直线距离（米）。玩家与 AI 从不同方向同距接近，比拼抢免保。
var spawn_to_safe_m: float = 180.0
## 兼容旧调试项：若面板仍显示，映射为 spawn_to_safe_m 的别名说明
var spawn_offset_m: float = 180.0

# ── 元信息：参数分组与范围，供调试面板自动生成 UI ─────────
const SPEC := {
	"移动": [
		["walk_speed", 40.0, 400.0],
		["sprint_speed", 60.0, 600.0],
		["crouch_speed", 20.0, 250.0],
		["accel", 200.0, 5000.0],
		["decel", 200.0, 6000.0],
		["sprint_turn_penalty", 0.1, 1.0],
	],
	"体力": [
		["stamina_max", 20.0, 300.0],
		["stamina_drain_sprint", 0.0, 80.0],
		["stamina_regen", 0.0, 80.0],
		["stamina_regen_delay", 0.0, 4.0],
		["stamina_sprint_threshold", 0.0, 60.0],
	],
	"视野": [
		["fov_half_angle", 15.0, 180.0],
		["vision_range", 120.0, 1200.0],
		["crouch_vision_range_mul", 0.4, 1.4],
		["crouch_fov_bonus", -20.0, 40.0],
		["sprint_fov_penalty", -10.0, 40.0],
		["proximity_radius", 0.0, 200.0],
		["vision_edge_feather", 0.0, 160.0],
		["terrain_memory_brightness", 0.0, 1.0],
	],
	"搜刮": [
		["search_time_per_slot", 0.1, 5.0],
		["search_time_mul_l1", 0.2, 3.0],
		["search_time_mul_l2", 0.2, 3.0],
		["search_time_mul_l3", 0.2, 4.0],
		["search_time_mul_l4", 0.2, 5.0],
		["l4_crack_time", 0.0, 20.0],
		["ai_search_time_mul", 1.0, 3.0],
		["ai_take_time_per_item", 0.0, 3.0],
		["search_move_speed_mul", 0.0, 1.0],
		["interact_range", 20.0, 200.0],
	],
	"枪械": [
		["recoil_visual_mul", 0.0, 3.0],
		["crosshair_scale", 0.3, 3.0],
	],
	"生命与伤害": [
		["player_hp_max", 20.0, 300.0],
		["ooc_regen_delay", 0.0, 30.0],
		["ooc_regen_per_sec", 0.0, 40.0],
		["enemy_hp_mul", 0.05, 2.0],
		["enemy_damage_mul", 0.02, 2.0],
	],
	"怪物 AI": [
		["enemy_fov_half_angle", 15.0, 180.0],
		["enemy_vision_range", 100.0, 1200.0],
		["enemy_notice_time", 0.0, 2.0],
		["enemy_chase_lose_time", 0.5, 15.0],
		["enemy_chase_max_range", 200.0, 3000.0],
		["enemy_leash_from_post", 300.0, 4000.0],
		["enemy_engage_range", 80.0, 800.0],
		["enemy_engage_min", 20.0, 400.0],
		["enemy_strafe_chance", 0.0, 1.0],
		["enemy_hearing_range", 0.0, 2500.0],
		["enemies_per_poi_base", 0.0, 20.0],
	],
	"载具": [
		["vehicle_hp_max", 50.0, 1500.0],
		["vehicle_max_speed", 150.0, 1400.0],
		["vehicle_accel", 60.0, 1200.0],
		["vehicle_turn_rate", 30.0, 400.0],
		["vehicle_highspeed_turn_mul", 0.2, 1.0],
		["vehicle_crash_damage", 0.0, 200.0],
		["vehicle_fuse_time", 0.0, 12.0],
		["vehicle_explosion_radius", 40.0, 500.0],
		["vehicle_explosion_damage", 0.0, 500.0],
		["vehicles_near_spawn", 0.0, 10.0],
		["vehicles_per_poi_outside", 0.0, 3.0],
		["vehicles_open_field", 0.0, 60.0],
	],
	"网格与地图": [
		["grid_fine_m", 10.0, 200.0],
		["grid_coarse_m", 100.0, 1000.0],
		["minimap_size", 140.0, 460.0],
		["minimap_range_m", 150.0, 2500.0],
		["spawn_offset_m", 5.0, 600.0],
		["spawn_to_safe_m", 50.0, 600.0],
	],
	"玩法流程": [
		["extraction_radius", 30.0, 300.0],
		["extraction_hold", 2.0, 20.0],
		["player_ai_count", 0.0, 6.0],
		["squad_count", 1.0, 40.0],
		["squad_size", 1.0, 6.0],
		["spaceship_spawn_time", 60.0, 1200.0],
		["contract_spawn_time", 0.0, 900.0],
		["spaceship_speed", 40.0, 400.0],
		["spaceship_pillar_radius", 30.0, 160.0],
		["spaceship_lift_time", 0.3, 6.0],
		["spaceship_control_radius", 40.0, 300.0],
		["spaceship_hijack_dwell", 0.3, 6.0],
		["spaceship_crack_hold", 10.0, 600.0],
		["spaceship_crack_range", 120.0, 900.0],
		["contract_hostage_time", 60.0, 900.0],
		["contract_hostage_guards", 0.0, 24.0],
		["contract_hostage_chests", 2.0, 10.0],
		["contract_extract_m", 200.0, 1500.0],
		["contract_extract_hold", 2.0, 30.0],
		["contract_upload_hold", 8.0, 60.0],
		["contract_tower_hold", 8.0, 60.0],
		["contract_intel_time", 8.0, 60.0],
		["contract_fail_ping_time", 4.0, 40.0],
		["hostage_hp", 20.0, 200.0],
		["carry_hostage_speed_mul", 0.4, 1.0],
		["phone_contract_window", 3.0, 30.0],
		["phone_contract_hold", 0.4, 4.0],
		["phone_ping_interval", 1.0, 8.0],
		["depot_call_time", 10.0, 180.0],
		["depot_call_broadcast_m", 40.0, 400.0],
		["depot_ai_rush_m", 80.0, 800.0],
	],
	"相机": [
		["camera_zoom", 0.55, 3.2],
		["camera_zoom_min", 0.4, 1.2],
		["camera_zoom_max", 1.4, 3.6],
		["camera_look_ahead", 0.0, 0.8],
		["camera_look_ahead_max", 0.0, 500.0],
		["camera_smooth", 1.0, 30.0],
	],
}

const TOGGLES := [
	["enable_vision_cone", "扇形视野"],
	["enable_wall_occlusion", "墙体遮断"],
	["enable_stamina", "体力系统"],
	["enable_search_progress", "搜刮读条"],
	["enable_grid_backpack", "网格背包容量"],
	["enable_shooting", "允许开火"],
	["infinite_ammo", "无限备弹"],
	["auto_reload_on_empty", "空仓自动换弹"],
	["search_break_on_move", "移动打断搜刮"],
	["search_lock_rotation", "搜刮锁定转向"],
	["show_debug_overlay", "调试可视化"],
	["use_world_map", "大地图模式（需 F5 重开生效）"],
	["enable_enemies", "启用怪物"],
	["enable_player_ai", "启用玩家AI"],
	["show_enemy_players", "显示敌方玩家AI"],
	["enable_vehicles", "启用载具"],
	["enemy_can_shoot", "怪物可开火"],
	["show_enemy_debug", "怪物 AI 状态可视化"],
	["god_mode", "玩家无敌"],
	["show_ground_grid", "地表网格线"],
	["show_grid_labels", "网格坐标标签"],
	["show_minimap", "小地图"],
	["minimap_rotate", "小地图随朝向旋转"],
	["enable_extraction", "公共撤离点"],
	["enable_spaceship", "飞船事件"],
	["enable_spaceship_hijack", "飞船劫持/破解点"],
	["enable_contracts", "动态合约"],
	["enable_phone_contracts", "电话合约"],
]

var _defaults := {}

func _ready() -> void:
	for group in SPEC.values():
		for entry in group:
			_defaults[entry[0]] = get(entry[0])
	for t in TOGGLES:
		_defaults[t[0]] = get(t[0])
	_load_overrides()

func set_value(key: String, value: Variant) -> void:
	if get(key) == value:
		return
	set(key, value)
	value_changed.emit(key, value)

func reset_all() -> void:
	for k in _defaults:
		set(k, _defaults[k])
		value_changed.emit(k, _defaults[k])

func snapshot() -> Dictionary:
	var out := {}
	for k in _defaults:
		out[k] = get(k)
	return out

## 把当前数值存回 user:// 方便下次跑测沿用
func save_overrides() -> void:
	var f := FileAccess.open("user://tuning_override.json", FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(snapshot(), "\t"))
		f.close()

func _load_overrides() -> void:
	for path in ["res://data/tuning.json", "user://tuning_override.json"]:
		if not FileAccess.file_exists(path):
			continue
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		var parsed = JSON.parse_string(f.get_as_text())
		f.close()
		if parsed is Dictionary:
			for k in parsed:
				if k in _defaults:
					set(k, parsed[k])


