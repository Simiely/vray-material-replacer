# 开发参考（DEV.md）

> 本文件记录开发 `vray_material_replacer.ms` 过程中的**关键技术决策、踩过的坑、已验证的解决方案与查证来源**。
> 目的：以后遇到类似问题（MaxScript 材质操作、V-Ray 属性名、MD→HTML 报告等）能直接查、少走弯路。

---

## 1. 技术选型为什么是 MaxScript（而不是 C++ SDK）

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| **MaxScript** | 内置、零依赖、复制粘贴即跑、改完立刻见效、稳定性高 | 性能不如 C++、语法古老 | ✅ 选它，符合「越简单越稳定」 |
| C++ SDK / Max 插件 | 性能好、能做复杂 UI | 需编译、需 VS 环境、部署麻烦、易踩 ABI 坑 | ❌ 过度工程，否决 |

**结论**：对「批量替换材质」这种场景，MaxScript + `getClassInstances` / `replaceInstances` 已足够且最稳。

---

## 2. 关键问题与解决方案（核心参考）

> ⚠️ 以下属性名**都曾写错并导致运行时报错 / 静默失效**，均已通过官方文档 + 论坛交叉验证。

| # | 问题点 | ❌ 错误写法 | ✅ 正确写法 | 查证来源 |
|---|--------|------------|------------|----------|
| 1 | 标准材质「启用贴图」开关 | `useDiffuseMap` | **`diffuseMapEnable`**（`bumpMapEnable` / `opacityMapEnable` / `selfIllumMapEnable` 同理） | Autodesk 官方 MAXScript 帮助 |
| 2 | VRayBitmap / VRayHDRI 的文件名 | `.bitmap` | **`.HDRIMapName`** | Chaos 官方论坛（`.bitmap` 某些版本只是字符串，取不到真实路径） |
| 3 | 包裹类材质的子材质属性 | `.baseMaterial` / `.frontMtl` | **`.baseMtl`** / **`.frontmtl`**（全小写） | Chaos 官方文档 |
| 4 | 收集场景「全部」材质 | 遍历 `objects` 逐个取 `.material` | **`getClassInstances Material`**（一次性捞所有材质：多维/嵌套/编辑器槽位/环境） | Autodesk 3ds Max 编程论坛（denisT.MaxDoctor 等） |
| 5 | 全局替换所有引用 | 逐物体 `obj.material = newMtl` | **`replaceInstances oldMtl newMtl`**（一次性替换所有引用，不漏嵌套） | Autodesk 论坛成熟写法 |
| 6 | Physical 材质贴图槽名 | 只写 `base_color_map` | **两种命名都试**：`base_color_map` 与 `base_color_map_map`（跨 Max 版本槽名不同） | 跨版本实测差异 |
| 7 | VRayMtl 的贴图槽位 | 猜槽名 | **`texmap_diffuse` / `texmap_bump` / `texmap_opacity`**（含对应 `_on` 开关） | Chaos 论坛实测脚本 |
| 8 | 子材质枚举 | `m.materialList` 手写 | **`getNumSubMtls` / `getSubMtl` / `getSubMtlSlotName`** | Autodesk MAXScript Help |
| 9 | 贴图槽位枚举 | 手动遍历属性 | **`getNumSubTexmaps` / `getSubTexmap` / `getSubTexmapSlotName`** | Autodesk MAXScript Help + Swordslayer 论坛回复 |
| 10 | MaxScript 无「分隔符拼接数组」 | `("," join arr)` | **自写 `joinStr arr sep`** 循环拼接 | 自身规避（该语法不存在） |
| 11 | 结构体重复定义报错 | 放在 `exportDoc` 函数内 | **`struct MatInfo (...)` 提到外部作用域只定义一次** | 自身规避（重复点导出会触发「已定义」） |
| 12 | 异常信息获取不稳 | `getCurrentException()` | **改用固定中文提示文案**（兼容性更好） | 自身规避（旧版 Max 可能无此函数） |

### 2.1 复用代码片段

```maxscript
-- 分隔符拼接（MaxScript 无内置）
fn joinStr arr sep = (
    local s = ""
    for i = 1 to arr.count do ( s += (arr[i] as string); if i < arr.count do s += sep )
    s
)

-- 任一属性安全读取（避免某版本缺属性直接崩）
try ( if (hasProperty src "texmap_diffuse") and src.texmap_diffuse != undefined do ... ) catch ()

-- Physical 贴图槽名跨版本兼容
fn setPhysMap pmtl baseName val = (
    try ( pmtl.(baseName + "_map") = val ) catch (
        try ( pmtl.(baseName + "_map_map") = val ) catch ()
    )
)
```

---

## 3. 查证与交叉验证来源

所有属性名都经过**多源交叉验证**，不要凭记忆改：

1. **Autodesk 官方 MAXScript 帮助** — Standard / Physical 材质属性表、`getClassInstances`、`getSub*Mtl`、`getSub*Texmap` 系列 API。
2. **Chaos（V-Ray）官方文档 + 官方论坛** — `VRayMtl` / `VRayLightMtl` / 各类包裹材质的参数与 MaxScript 属性名、`.HDRIMapName`。
3. **Autodesk 3ds Max 官方编程论坛** — `denisT.MaxDoctor`、`Swordslayer` 等关于 `getClassInstances` + `replaceInstances` 的成熟写法。
4. **ScriptSpot** — “V-Ray to Standard Converter” 实战脚本（双向印证槽位名）。
5. **CGTalk / 百度文库等论坛** — 实测片段补充。

> 🔑 经验：**V-Ray 属性名在不同大版本（3/4/5/6）基本一致，但 Physical 材质槽名随 Max 版本漂移**；凡涉及 Physical 一律「两种命名都试 + `try/catch` 兜底」。

---

## 4. 版本兼容性矩阵

| 维度 | 最低要求 | 备注 |
|------|----------|------|
| 3ds Max | 任意较新版本 | `getClassInstances` / `replaceInstances` 长期稳定 |
| Physical 材质 | 3ds Max 2017+ | 代码用 `canPhysical` 探测，老版本自动退回 Standard |
| V-Ray | 不强制安装 | 替换逻辑读的是场景已有材质数据；导出同理 |
| dotNet 剪贴板 | Max 默认带 | 精简环境可能无 → 已做回退到日志显示 |

---

## 5. AI 提示词（MD → HTML 报告）设计要点

提示词写在 `vray_material_replacer.ms` 顶部的 `aiPromptLines` 变量里（脚本自动拼成 `aiPrompt`），导出时作为 **HTML 注释**写在 MD 开头：

- **为什么用注释**：AI 读到指令；渲染成 HTML 时整段自动隐藏，不影响页面。
- **关键渲染要求**（供 AI 实现）：
  - 单文件、离线可开、HTML/CSS/JS 全内联、零外部依赖；
  - 顶部统计卡片（材质总数 / V-Ray 数 / 对象数）；
  - 目录 TOC 用 `#mat-1`、`#mat-2` 锚点跳转（**避开中文锚点在不同平台解析不一致的坑**）；
  - 每个材质一张卡片：类型标签、使用对象、颜色色块（`#RRGGBB` 真实渲染）、参数表、贴图表（路径可点击）、子材质锚点链接；
  - 浅色 / 深色 / 跟随系统 三档主题 + 平滑过渡，默认跟随系统；
  - 响应式、动画流畅（60fps）、纯静态。
- **改提示词只改一处**：直接编辑 `aiPromptLines`，不用动其它代码。

---

## 6. 测试与验证方法

- MaxScript **无法在 CI 里跑**（需真实 3ds Max GUI），只能**人工在 Max 内验证**：
  1. 准备含多种 V-Ray 材质的测试场景（含 `VRayMtl`、`VRayLightMtl`、包裹类、多维子材质、编辑器里未引用的材质）；
  2. 跑「替换」→ 检查材质编辑器与所有物体引用是否彻底无 V-Ray；
  3. 跑「导出 MD」→ 用假数据示例 `examples/材质构成报告_示例.md` 先验证结构，再在真实场景验证；
  4. 把导出 MD 丢给 ChatGPT/Claude 生成 HTML，检查色块、锚点跳转、主题切换。
- **语法层自查**：MaxScript 没有强类型编译器，靠反复通读 + 规避已知坑（见第 2 节 10/11/12）。

---

## 7. 已知限制与取舍（如实记录）

- **V-Ray 专属参数被丢弃**：反射 / 折射 / 光泽度 / Fresnel / SSS 在标准材质无对应项 → 直接丢弃。取舍是「能正常打开、无 V-Ray 依赖」而非「渲染一致」。
- **`VRayLightMtl` 强度**不精确映射标准自发光强度（无 HDR 级别），极亮灯可能不够亮。
- **V-Ray 贴图（`VRayDirt` / `VRayColor` 等）原样保留**：标准/物理下可能渲染成黑，但不影响稳定性。
- **替换单向**：无「还原 V-Ray」反向功能，靠 `Ctrl+Z` 回退本次操作。

---

## 8. 待办 / 后续可增强

- [ ] 增加「只统计、不替换」的预览按钮（先看会动多少个材质）。
- [ ] 把 `VRayDirt` / `VRayColor` 这类 V-Ray 贴图也一并转成普通贴图。
- [ ] 包成 `macroScript` 安装到工具栏（更像「正经插件」）。
- [ ] 针对具体 V-Ray 大版本（5 / 6）做一轮实测微调。
- [ ] 给 `VRayLightMtl` 的强度加一个映射系数，改善极亮灯表现。
- [ ] 可选：导出时顺手生成一个 HTML 预览（调用内嵌提示词本地渲染，需外部工具）。

---

## 9. 提交 / 发布记录

- **v3**：交叉验证版，修正 1–9 项属性名坑，新增导出 MD 功能。
- **v3.1**：AI 提示词内嵌插件并在导出时写入 MD 开头；面板加「复制 AI 提示词」按钮。
- 仓库发布：`Simiely/vray-material-replacer`（GitHub 公开仓库）。
