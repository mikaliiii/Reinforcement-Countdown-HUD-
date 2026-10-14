# 第三方来源与署名

本模组是 **Reinforcement Radar** 的衍生作品。原项目由 **superSizzzz** 以 MIT 许可发布：

- 仓库：https://github.com/superSizzzz/Reinforcement-Radar
- 许可：MIT License，Copyright (c) 2026 superSizzzz

MIT 许可允许使用、修改、再分发，条件是保留原版权声明与许可全文。本目录下的
`LICENSE-Reinforcement-Radar` 即为原许可全文，必须随本模组一并分发。

## 本项目沿用了什么

以下内容来自原项目，属于**实测得出、不可自行推导**的关键信息，本模组原样沿用：

| 内容 | 说明 |
| --- | --- |
| `game.dll + 0x3326020` | 指向增援管理器的全局指针 |
| `game.dll + 0x3325f18` | 指向 pacing 管理器的全局指针 |
| 管理器字段偏移 | `+0x94` 原生剩余秒数、`+0xad0` 归一化比例、`+0xa0` 队列长度、`+0xc4`/`+0x104` 队列项、`+0x80` 任务描述符、`+0x68` 实体映射表 |
| pacing 字段偏移 | `+0x924` 冷却速率、`+0x934` 阻塞计数 |
| 8 条原生代码签名 | RVA + 期望字节，用于构建校验（见 `src/reinforcement.lua`） |
| `game.dll` PE 指纹 | TimeDateStamp `1790161983`、SizeOfImage `74727424` |
| Stingray HUD 接口用法 | `World.create_screen_gui` / `Gui.text`、字体 `core/performance_hud/debug`、y 轴自下而上 |
| 状态机判定顺序 | UNAVAILABLE → PENDING → PAUSED → COOLDOWN → READY |

这些偏移与签名是在**特定游戏构建**（Steam 25480438 / EXE 1.8.46015.0）上实测确定的。
游戏更新后它们会失效——这正是模组内置构建校验、拒绝在未知构建上运行的原因。

## 本项目新增了什么

- 用官方 `BingusSharedRuntime` 的 `runtime.guard()` 取代手写 update 钩子
- 以**明文**实现交付，构建不依赖外部 LuaJIT 可执行文件，任何人都能复现
- 自带的离线测试：LuaJIT 语法闸门、哈希规范测试、状态机夹具测试、归档往返校验
- 中文文档：安装、原理、反作弊边界、游戏更新后的维护流程
- `tools/check_build.py`：无需启动游戏即可核对本机构建是否受支持

原项目的诊断构建（`--diag`）与 module-lookup 追踪未包含在本移植中；需要时请直接使用原仓库。

## 原项目作者的话

> 作者由于学业原因可能无法长期维护本项目，希望社区能够共同维护。

本移植版同样遵循该意愿：文档中「游戏更新后如何重新适配」一节写明了从定位签名到重新
发布的完整流程。
