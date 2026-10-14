# 敌人增援倒计时 HUD（绝地潜兵 2）

在任务中把**敌人增援冷却**显示成屏幕上的倒计时：还能拉烟时显示 `READY`，
冷却中显示 `MM:SS` 并按剩余时间变色。
只读、不改游戏内存、不影响其他玩家。

> 本模组是 [Reinforcement Radar](https://github.com/superSizzzz/Reinforcement-Radar)（MIT，
> superSizzzz）的衍生作品。偏移、签名与状态机来自原项目的实测结果；
> 本项目把实现改为单资源明文、补齐离线测试与中文文档。详见
> [THIRD_PARTY.md](THIRD_PARTY.md)。

---

## 一、依赖

| 需要 | 说明 |
| --- | --- |
| **Bingus Shared Loader** | v15 或更新（API 1）。必须一起启用，只开本模组不起作用 |
| 游戏构建 | Steam 25480438 / EXE 1.8.46015.0 |

## 二、安装

1. 关闭游戏
2. 用 Arsenal（或 HD2 Mod Manager）导入
   `build/Reinforcement-Countdown-HUD-1.0.0.zip`
3. 启用本模组，同时启用 Bingus Shared Loader

按 Arsenal 默认优先级，把 Bingus Shared Loader 放在列表最下面
（如果你开了"优先第一个"，则放最上面）。

## 三、显示规则

面板固定在屏幕右侧偏上的位置，没有背景板，文字直接画在画面上。

状态 | 显示 | 颜色 
--- | --- | --- 
可以拉烟（冷却清零） | `READY` | 绿 
冷却中，剩余 > 2 分钟 | `MM:SS` | 绿 
冷却中，剩余 1–2 分钟 | `MM:SS` | 橙 
冷却中，剩余 < 1 分钟 | `MM:SS` | 红 
增援进行中（冷却被冻结） | **不显示** | — 
不在任务中 | **不显示** | — |
客机（前约 4 秒） | **不显示** | — 

三条"不显示"都是刻意的，不是缺陷：

- **增援进行中**：游戏会在增援期间冻结共享冷却，那一刻的"剩余时间"是停住的
  数字，显示它只会误导。
- **不在任务中**：在飞船上，或任务已结束。
- **客机前约 4 秒**：客机只收到归一化比例，需要先测出它的下降率才能换算成
  秒数。这 4 秒内不显示数字——宁可晚几秒，也不显示一个会读错的秒数。
  恒定网络延迟不影响换算（它只是一个固定偏移），抖动的处理见
  [原理说明](docs/01-原理与偏移.md)。

想改位置/大小，改 `src/hud.lua` 顶部的 `LAYOUT` 表即可（按分辨率自动缩放）。
启动时日志会记录一次实际布局，方便按自己的分辨率核对：

```
# HUD layout: screen=2560x1334 scale=1.235 panel=212x49 at 2317,724
```

## 四、日志与排查

```
%LOCALAPPDATA%\CowboyBingus\Helldivers2\Logs\ReinforcementRadar.log
```

取不到时会依次回退到 `C:\ReinforcementRadar.log`，最后是游戏工作目录。

日志结构：

- 开头是环境信息（loader 版本、Lua 版本）与**构建校验结果**
- 之后是状态变化时写下的 `SAMPLE` 块，以及冷却递减期间的 `HEARTBEAT`

一个正常的块长这样：

```
SAMPLE  status=COOLDOWN  authoritative=true  seconds=171  raw_remaining=164.014862
        rate=0.963457  fraction=0.500000  pending=0  blockers=0  derived=171
```

排查对照表：

| 日志里出现 | 含义 | 怎么办 |
| --- | --- | --- |
| `不支持的游戏构建` | 游戏构建与模组不符 | 运行`tools/check_build.py` 确认；等模组更新 |
| `N/M 条守卫失败` | 游戏更新了，原生代码变了 | 需要重新适配（见下） |
| 完全没有日志文件 | 加载器没发现这个 addon | 确认 loader 已启用且版本 ≥ v15；确认 Deploy 成功 |
| `loader api=0` 或 `拒绝：加载器 API ... 过旧` | loader 太旧 | 升级 Bingus Shared Loader |
| `reason=非权威端：仍在测量冷却速率` | 你刚进任务或刚换段 | 等约 4 秒即可出数字 |

## 五、安全边界

- **只读。** 源码里只声明四个 Windows API：`GetModuleHandleA`、
  `GetCurrentProcess`、`ReadProcessMemory`、`GetTickCount64`。没有写入、
  改页保护、分配内存、加载代码或联网的调用。
- 这一点是**构建期强制**的：`tools/build.py` 在剥离注释后的代码上做黑名单
  扫描，命中任何一个词条就拒绝打包，并且自带变异测试确保这套检查真的会失败。
- 反作弊是 **nProtect GameGuard**。所有读取都在游戏进程内、通过游戏自己的
  LuaJIT 完成，**没有**从外部进程 `OpenProcess` + `ReadProcessMemory`
  ——那是最容易被抓的动作。本模组不含任何外部程序。
- 全部改动只在读取侧，禁用模组即完全还原。

> 关于多人游戏：这是纯客户端读取，不修改任何游戏状态，因此不会与其他玩家
> 不一致。但请自行了解你所在区域与平台对模组的态度。

## 六、文档

- [原理说明](docs/01-原理与偏移.md) 
- [游戏更新后的维护](docs/02-游戏更新后的维护.md) 
- [构建与测试](docs/03-构建与测试.md) 
- [开发记录](docs/04-开发记录.md) 
- [THIRD_PARTY.md](THIRD_PARTY.md)
- **没有以上这些东西，开发都是找deepseekv4.1写的，测试就是拿d老师写出来的东西丢游戏里面然后开一把**，

## 七、许可

本移植版同样以 **MIT** 发布（见 [LICENSE](LICENSE)），并保留原项目的版权声明
（见 [LICENSE-Reinforcement-Radar](LICENSE-Reinforcement-Radar)）。
