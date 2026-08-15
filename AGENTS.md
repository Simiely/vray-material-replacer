# AGENTS.md · 项目规则

> 📌 **文档基线**：2026-08-15（commit `e8b3e6e`）3.3.0：路径跟随工程 + 一键刷新 + 灯光色值/贴图双接 + 模块化解耦
> **更新文档/代码后，请更新此行**（日期 + 新 commit hash），并在 CHANGELOG 追加版本

## 技术栈
- 3ds Max 2026（中文界面，用户配置目录 `AppData\Local\Autodesk\3dsMax\2026 - 64bit\CHS\`）+ MaxScript（单文件 `.ms`，零依赖）
- 本机安装位置：Startup 目录 `...\CHS\scripts\Startup\vray_material_replacer.ms`（启动自启）
- 语法速查见 knowledge-base 速查表（占位）

## 关键坑（改代码前必读）
- **MAXScript 无闭包**：函数体内禁止嵌套 `fn` 引用外层局部变量（报「此处不允许使用外部局部变量引用」）；跨函数传数据一律用参数/返回值，辅助函数放顶层块
- **没有 `local fn` 组合语法**：块内 `fn` 天然局部，加 `local` 前缀报「需要 name」
- **想当然的函数名必炸**：`bit.char` 不存在（用 `bit.intAsChar 13/10`）；`trim` 不存在（用 `trimLeft`/`trimRight`）；`->` 不存在（用 `=`）
- **核心接口不要实例化**：`SceneConverter.OverwriteFromMaterialLibrary path`（直接点号调用，`SceneConverter()` 是解析期语法错误）
- **路径变量**：`maxFileName` 只含文件名，路径用 `maxFilePath`（含尾斜杠）；完整 = `maxFilePath + maxFileName`
- **跨 rollout 访问必须先预声明 local**：rollout A 的事件引用后定义的 rollout B，B 会被隐式声明为局部 undefined（报「未知属性 xxx 位于 undefined」）；在 A 定义前写 `local rlB, rlC` 预声明（Autodesk 官方推荐模式）
- **默认路径必须动态计算**：rollout 定义时求值的 `local defaultPath` 在 Startup 加载瞬间定死（场景未加载）；用顶层 `sceneBaseDir()` 每次实时读 `maxFilePath`，open/btnGo 时再取
- **VRayLightMtl 没有 `diffuse` 属性**：参数只有 Color/Multiplier/Opacity/Texture；转换到 Standard 时灯光颜色 `color` 要**双接**（diffuse + selfIllumColor），贴图 `texmap` 也双接（diffuseMap + selfIllumMap）
- **Physical 贴图槽名跨版本漂移**：`base_color_map` / `base_color_map_map` 两种都试（`setPhysMap` 已封装）
- **BitmapTexture 无 `enabled` 属性**：报告读取启用状态要反查材质槽位属性（`<slot>MapEnable` / `<slot>_map_enabled`）
- **`for...where...` 嵌套过滤**：内层 where 引用外层循环变量会 undefined，统一用朴素 `for + if`
- **程序贴图收集必须防环**：`collectProcMaps` 入栈前检查 `findItem seen`，否则循环贴图树死循环
- **颜色值有三类**：`Color` / `AColor` / `Point3`，判断用 `isKindOf val Color or classof val == Point3`；`colorToHex` 兼容 0-1 浮点（×255）

## 约定
- UI 标签用中文；注释用中文；单文件交付；`try/catch` 兜底所有属性访问
- 3ds Max 启动脚本只在启动时加载一次，改代码后需重启 Max 才生效
- 本机工作副本：`D:\workbuddy\2026-08-14-22-01-24\vray-material-replacer\`（开发）+ Startup 目录（安装副本，改完同步）

## 常用命令
- 手动运行：MAXScript → 新建脚本 → 打开 `.ms` → Ctrl+E；或直接拖进视口
- 安装同步：`cp vray_material_replacer.ms "...\CHS\scripts\Startup\"` + `md5sum` 校验
- 语法自查：Node 括号配平脚本（跳过注释/字符串）+ 全文 grep 残留（`local fn` / `bit.char` / 独立 `trim` / `SceneConverter()` / `getFilenamePath maxFileName`）

## 详细规则（按需 @引用）
- 内容超阈值时拆出 `rules/` 目录（如 `rules/MAXScript语法坑.md`、`rules/材质属性映射.md`），当前核心坑已在本文件内，暂不拆分
