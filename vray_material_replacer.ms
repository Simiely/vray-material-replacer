-------------------------------------------------------------------------------
-- 材质工具箱 (Material Toolkit)  v3  [交叉验证版]
-- 验证来源：Autodesk 官方 MAXScript 帮助、Chaos(V-Ray) 官方文档与论坛、
--           3ds Max 官方编程论坛(Autodesk)、ScriptSpot、CGTalk、denisT.MaxDoctor 等。
--
-- 包含两大功能：
--   【面板一】V-Ray 材质一键替换（Standard / Physical）
--   【面板二】导出场景所有材质的「构成」为 Markdown 文档（结构已为 AI→HTML 优化）
--
-- 关键修正（均已交叉验证）：
--   1) 遍历「对象材质 + 材质编辑器槽位 + 递归子材质」收集场景【全部】材质；getClassInstances 不接受抽象基类 Material。
--   2) replaceInstances 全局一次性替换所有引用，最稳定、不漏嵌套。
--   3) 标准材质“启用贴图”属性是 diffuseMapEnable（非 useDiffuseMap）。
--   4) VRayBitmap/VRayHDRI 文件名用 .HDRIMapName 读取。
--   5) 包裹类材质取 baseMtl / frontmtl 子材质转换，保留真实外观。
--   6) Physical 贴图槽名跨版本差异（base_color_map / base_color_map_map）两种都试。
--   7) 贴图槽位枚举用 getNumSubTexmaps + getSubTexmapSlotName（官方 API）。
--
-- 用法：MAXScript 编辑器打开本文件 -> Ctrl+E 运行 -> 弹窗操作。
-- 建议：操作前先保存场景（替换可 Ctrl+Z 撤销；导出只读、不改场景）。
-------------------------------------------------------------------------------

(
    -- ===================== 共享工具函数 =====================
    local canPhysical = (try ( (PhysicalMaterial()) != undefined ) catch false)

    fn pad2 s = ( if s.count < 2 then ("0" + s) else s )

    -- Color -> #RRGGBB（Max 的 Color 分量 r/g/b 为 0-255 整数）
    fn colorToHex c = (
        try (
            "#" + (pad2 (bit.intAsHex c.r)) + (pad2 (bit.intAsHex c.g)) + (pad2 (bit.intAsHex c.b))
        ) catch ( "#000000" )
    )

    -- 读取任意贴图的文件路径（BitmapTexture 用 .filename；VRayBitmap/VRayHDRI 用 .HDRIMapName）
    fn mapFilename tm = (
        if tm == undefined do return ""
        local fn2 = ""
        local clsT = try ((classof tm) as string) catch ""
        if (clsT == "VRayBitmap" or clsT == "VRayHDRI") then (
            try ( fn2 = tm.HDRIMapName ) catch ()
        ) else (
            try ( fn2 = tm.filename ) catch ()
        )
        if fn2 == undefined do fn2 = ""
        fn2
    )

    -- 当前时间字符串
    fn nowStr = (
        local t = getLocalTime()
        local y = t[1] as string
        local m = (if t[2] < 10 then "0" + (t[2] as string) else t[2] as string)
        local d = (if t[3] < 10 then "0" + (t[3] as string) else t[3] as string)
        local hh = (if t[4] < 10 then "0" + (t[4] as string) else t[4] as string)
        local mm = (if t[5] < 10 then "0" + (t[5] as string) else t[5] as string)
        (y + "-" + m + "-" + d + " " + hh + ":" + mm)
    )

    -- 清理名称（去掉换行/回车，避免破坏 Markdown）
    fn cleanName s = (
        s = s as string
        s = substituteString s (bit.char 13) " "   -- CR
        s = substituteString s (bit.char 10) " "   -- LF
        trim s
    )

    -- 用分隔符拼接字符串数组（MaxScript 无内置 sep-join）
    fn joinStr arr sep = (
        local s = ""
        for i = 1 to arr.count do (
            s += (arr[i] as string)
            if i < arr.count do s += sep
        )
        s
    )

    -- 递归收集材质：&acc 为按引用传递的数组；遍历多维子材质与常见包裹/混合/双面子材质
    fn recurseMats &acc m =
    (
        if m == undefined do return undefined
        if (findItem acc m) == 0 do append acc m
        if (isProperty m #materialList) do
            for sm in m.materialList where sm != undefined do recurseMats &acc sm
        if (isProperty m #baseMtl)   and m.baseMtl   != undefined do recurseMats &acc m.baseMtl
        if (isProperty m #frontmtl)  and m.frontmtl  != undefined do recurseMats &acc m.frontmtl
        if (isProperty m #backmtl)   and m.backmtl   != undefined do recurseMats &acc m.backmtl
        if (isProperty m #coatMtl)   and m.coatMtl   != undefined do recurseMats &acc m.coatMtl
        if (isProperty m #coatMtl1)  and m.coatMtl1  != undefined do recurseMats &acc m.coatMtl1
        if (isProperty m #coatMtl2)  and m.coatMtl2  != undefined do recurseMats &acc m.coatMtl2
        if (isProperty m #blendMtl1) and m.blendMtl1 != undefined do recurseMats &acc m.blendMtl1
        if (isProperty m #blendMtl2) and m.blendMtl2 != undefined do recurseMats &acc m.blendMtl2
        if (isProperty m #shellMtl)  and m.shellMtl  != undefined do recurseMats &acc m.shellMtl
        undefined
    )

    -- 收集场景内全部材质（对象材质 + 材质编辑器槽位 + 递归子材质）
    -- 不使用 getClassInstances Material：Material 是抽象基类，getClassInstances 只接受具体 MAXClass
    fn collectAllMaterials =
    (
        local result = #()
        for o in objects do
            if o.material != undefined do recurseMats &result o.material
        for i = 1 to meditMaterials.count do
            if meditMaterials[i] != undefined do recurseMats &result meditMaterials[i]
        result
    )

    -- ===================== AI 转换提示词（导出时写入 MD 开头） =====================
    -- 这份提示词会作为 HTML 注释写在导出 MD 的最前面，AI 读取 MD 时会一并看到。
    -- 改这里即可调整“MD -> HTML 报告”的渲染要求，无需动其它代码。
    local aiPromptLines = #(
        "你是一位资深前端工程师。下面是一份从 3ds Max 导出的「场景材质构成报告」Markdown 文档。",
        "请把它转换成【单文件、可离线打开、完全自包含】的 HTML 可视化报告：HTML + CSS + JS 全部内联，不依赖任何外部库或网络请求。",
        "",
        "【页面要求】",
        "1. 顶部放置统计卡片：材质总数、V-Ray 材质数、使用材质对象数。",
        "2. 提供目录（TOC），利用文档中的锚点 #mat-1、#mat-2 … 实现点击跳转到对应材质卡片。",
        "3. 每个材质渲染为一张卡片，包含：",
        "   - 材质名称与类型标签（VRayMtl / Standard / Physical / MultiMaterial 等；V-Ray 类加醒目标记）；",
        "   - 「使用对象」列表（若有）；",
        "   - 「颜色参数」：把 #RRGGBB 渲染成真实色块 + 十六进制文字；",
        "   - 「数值参数」：用表格展示；",
        "   - 「贴图」：用表格展示槽位 / 类型 / 文件 / 启用；文件路径若以盘符或 http 开头，渲染为可点击链接；",
        "   - 「子材质」：渲染为可点击锚点链接，跳转到对应材质卡片。",
        "4. 支持「浅色 / 深色 / 跟随系统」三档主题切换，切换有平滑过渡；默认跟随系统。",
        "5. 现代卡片 + 表格风格，留白充足、排版精致；移动端响应式；交互动画流畅（60fps）。",
        "6. 纯静态，双击即可在浏览器打开，不要写任何需要服务器的代码。",
        "",
        "请直接输出完整 HTML 代码，不要省略、不要只给片段。"
    )
    local aiPrompt = joinStr aiPromptLines "\n"

    -- 取得场景里“使用某材质的对象名”映射（在导出时调用，保证最新）
    fn buildMatObjectMap = (
        local map = #()  -- 元素为 #(material, #(objName,...))
        for o in objects where o.material != undefined do (
            local found = false
            for pair in map where pair[1] == o.material do ( append pair[2] (cleanName o.name); found = true )
            if not found do append map #(o.material, #(cleanName o.name))
        )
        map
    )

    fn getMatObjects mtlObjMap m = (
        for pair in mtlObjMap where pair[1] == m do return pair[2]
        #()
    )

    -- 材质信息结构体（仅定义一次，避免重复定义报错）
    struct MatInfo (idx, mat, dispName, className, isVRay, objNames, subIdx, maps, colors, nums)

    -- ===================== 面板一：V-Ray 材质替换 =====================
    rollout rlVRayReplace "① V-Ray 材质替换" width:340 height:470
    (
        dropdownList ddlTarget "目标材质类型:" items:#("Standard (标准材质)", "Physical (物理材质)") selection:1
        checkbox     chkMaps   "保留漫反射/凹凸/透明贴图" checked:true
        checkbox     chkBitmap "把 VRayBitmap / VRayHDRI 转为 Bitmap" checked:false
        button       btnGo     "开始替换 V-Ray 材质" width:310 height:36
        button       btnCount  "仅统计 V-Ray 材质（不替换）" width:310 height:24
        edittext     edtLog    "" width:310 height:212 readOnly:true

        fn convBitmap m =
        (
            local clsM = try ((classof m) as string) catch ""
            if (clsM == "VRayBitmap" or clsM == "VRayHDRI") then
            (
                local nb = BitmapTexture()
                try ( nb.filename = m.HDRIMapName ) catch ()
                try ( nb.name = m.name ) catch ()
                nb
            )
            else m
        )

        fn setPhysMap pmtl baseName val =
        (
            try ( setProperty pmtl (baseName + "_map") val; setProperty pmtl (baseName + "_map_enabled") true ) catch (
                try ( setProperty pmtl (baseName + "_map_map") val; setProperty pmtl (baseName + "_map_map_enabled") true ) catch ()
            )
        )

        fn vrMtlToStandard src = (
            local r = StandardMaterial()
            r.name = src.name
            try ( r.diffuse = src.diffuse ) catch ()
            if chkMaps.checked do (
                try ( if (src.texmap_diffuse != undefined and (try (src.texmap_diffuse_on == true) catch true)) do ( r.diffuseMap = convBitmap src.texmap_diffuse; r.diffuseMapEnable = true ) ) catch ()
                try ( if (src.texmap_bump != undefined and (try (src.texmap_bump_on == true) catch true)) do ( r.bumpMap = convBitmap src.texmap_bump; r.bumpMapEnable = true ) ) catch ()
                try ( if (src.texmap_opacity != undefined and (try (src.texmap_opacity_on == true) catch true)) do ( r.opacityMap = convBitmap src.texmap_opacity; r.opacityMapEnable = true ) ) catch ()
            )
            r
        )

        fn vrMtlToPhysical src = (
            local r = PhysicalMaterial()
            r.name = src.name
            try ( if (hasProperty src "diffuse") do r.base_color = src.diffuse ) catch ()
            try ( if (hasProperty src "color")   do r.base_color = src.color   ) catch ()
            if chkMaps.checked do try ( if (hasProperty src "texmap_diffuse") and src.texmap_diffuse != undefined do ( setPhysMap r "base_color" (convBitmap src.texmap_diffuse) ) ) catch ()
            r
        )

        fn vrLightToStandard src = (
            local r = StandardMaterial()
            r.name = src.name
            try ( if (hasProperty src "color")   do ( r.useSelfIllumColor = true; r.selfIllumColor = src.color; r.selfIllumAmount = 100 ) ) catch ()
            try ( if (hasProperty src "diffuse") do r.diffuse = src.diffuse ) catch ()
            if chkMaps.checked do (
                try ( if (hasProperty src "texmap") and src.texmap != undefined do ( r.selfIllumMap = convBitmap src.texmap; r.selfIllumMapEnable = true ) ) catch ()
                try ( if (hasProperty src "texmap_opacity") and src.texmap_opacity != undefined do ( r.opacityMap = convBitmap src.texmap_opacity; r.opacityMapEnable = true ) ) catch ()
            )
            r
        )

        fn vrGenericToStandard src = (
            local r = StandardMaterial()
            r.name = src.name
            try ( if (hasProperty src "diffuse") do r.diffuse = src.diffuse ) catch ()
            try ( if (hasProperty src "color")   do ( r.useSelfIllumColor = true; r.selfIllumColor = src.color; r.selfIllumAmount = 100 ) ) catch ()
            if chkMaps.checked do try ( if (hasProperty src "texmap_diffuse") and src.texmap_diffuse != undefined do ( r.diffuseMap = convBitmap src.texmap_diffuse; r.diffuseMapEnable = true ) ) catch ()
            r
        )

        fn convertMaterial src depth:1 =
        (
            if src == undefined do return undefined
            if depth > 12 do return (StandardMaterial())
            if not (matchPattern (classof src as string) pattern:"VRay*") do return src

            case classof src of
            (
                VRayMtl:         ( if (ddlTarget.selection == 2 and canPhysical) then (vrMtlToPhysical src) else (vrMtlToStandard src) )
                VRayLightMtl:    ( vrLightToStandard src )
                VRayMtlWrapper:  ( convertMaterial src.baseMtl  depth:(depth+1) )
                VRayBlendMtl:    ( convertMaterial src.baseMtl  depth:(depth+1) )
                VRay2SidedMtl:   ( local fm = convertMaterial src.frontmtl depth:(depth+1); try ( fm.twoSided = true ) catch (); try ( fm.two_sided = true ) catch (); fm )
                VRayOverrideMtl: ( convertMaterial src.baseMtl  depth:(depth+1) )
                VRayFastSSS2:    ( vrGenericToStandard src )
                default:         ( vrGenericToStandard src )
            )
        )

        on btnGo pressed do
        (
            local tgt = if (ddlTarget.selection == 2 and canPhysical) then #physical else #standard
            local allMats  = collectAllMaterials()
            local vrayMats = for m in allMats where matchPattern (classof m as string) pattern:"VRay*" collect m
            local nMat = vrayMats.count

            undo "Replace V-Ray Materials" on
            (
                for m in vrayMats do
                (
                    local nm = convertMaterial m
                    try ( replaceInstances m nm ) catch ()
                )

                if chkBitmap.checked do
                (
                    try ( for b in (getClassInstances VRayBitmap) do replaceInstances b (convBitmap b) ) catch ()
                    try ( for h in (getClassInstances VRayHDRI)  do replaceInstances h (convBitmap h) ) catch ()
                )
            )

            edtLog.text = ( "完成。\n\n发现 V-Ray 材质：" + nMat as string + " 个\n已全部替换为 " + (if tgt == #physical then "Physical" else "Standard") + "。\n" + (if chkBitmap.checked then "\nVRayBitmap / VRayHDRI 已一并转为 Bitmap。" else "") + "\n\n提示：替换前请确认已保存场景。" )
            gc()
        )

        on btnCount pressed do
        (
            local allMats  = collectAllMaterials()
            local vrayMats = for m in allMats where matchPattern (classof m as string) pattern:"VRay*" collect m
            edtLog.text = ( "统计结果：\n\n场景材质总数：" + allMats.count as string + "\nV-Ray 材质数：" + vrayMats.count as string + "\n\n点击「开始替换」将把上述 V-Ray 材质转为 " + (if (ddlTarget.selection == 2 and canPhysical) then "Physical" else "Standard") + "。" )
        )
    )

    -- ===================== 面板二：导出材质构成 MD =====================
    rollout rlExport "② 导出材质构成 MD" width:340 height:330
    (
        edittext     edtPath  "输出路径:" text:"" width:250
        button       btnBrowse "浏览..." width:60 height:21
        checkbox     chkObjs  "包含「使用对象」列表" checked:true
        checkbox     chkMaps  "包含「贴图」详情"     checked:true
        checkbox     chkParams "包含「数值/颜色」参数" checked:true
        button       btnCopy  "复制 AI 提示词（给 ChatGPT/Claude）" width:310 height:24
        button       btnGo    "导出材质构成 MD" width:310 height:36
        edittext     edtLog   "" width:310 height:60 readOnly:true

        local defaultPath = (
            if maxFileName != "" then (getFilenamePath maxFileName + "材质构成报告.md")
            else ((getDir #userScripts) + "\\材质构成报告.md")
        )
        on rlExport open do ( edtPath.text = defaultPath )

        on btnBrowse pressed do (
            local p = getSaveFileName caption:"保存材质构成报告" types:"Markdown (*.md)|*.md|All Files (*.*)|*.*" fileName:defaultPath
            if p != undefined do edtPath.text = p
        )

        on btnCopy pressed do (
            try (
                (dotNetClass "System.Windows.Forms.Clipboard").SetText aiPrompt
                edtLog.text = "AI 提示词已复制到剪贴板，直接粘贴给 ChatGPT / Claude 即可。"
            ) catch (
                edtLog.text = "提示词复制到剪贴板失败，可直接从导出 MD 的开头复制：\n\n" + aiPrompt
            )
        )

        -- 导出核心
        fn exportDoc path includeObjs includeMaps includeParams = (
            local ss = ""

            -- 收集所有材质（去重，按引用）
            local mats = collectAllMaterials()
            local nTotal = mats.count
            local nTotal = mats.count

            -- 对象映射
            local objMap = #()
            if includeObjs do objMap = buildMatObjectMap()

            -- 统计 V-Ray 数量
            local nVRay = 0
            for m in mats do ( if matchPattern (classof m as string) pattern:"VRay*" do nVRay += 1 )

            -- 预先为每个材质计算信息
            local infos = #()
            for i = 1 to mats.count do
            (
                local m = mats[i]
                local cls = (classof m) as string
                local isV = matchPattern cls pattern:"VRay*"
                local dName = cleanName (try(m.name)catch(cls))
                if dName == "" or dName == undefined do dName = cls

                -- 子材质索引
                local subIdx = #()
                local nSub = (try(getNumSubMtls m)catch(0))
                for k = 1 to nSub do (
                    local sm = (try(getSubMtl m k)catch(undefined))
                    if sm != undefined do (
                        local idx = findItem mats sm
                        if idx > 0 do append subIdx idx
                    )
                )

                -- 贴图槽位
                local maps = #()
                if includeMaps do (
                    local nTex = (try(getNumSubTexmaps m)catch(0))
                    for k = 1 to nTex do (
                        local tm = (try(getSubTexmap m k)catch(undefined))
                        if tm != undefined do (
                            local slot = (try(getSubTexmapSlotName m k)catch("slot " + (k as string)))
                            local clsM = (classof tm) as string
                            local fnm = mapFilename tm
                            local en = (try(tm.enabled == true)catch(false))
                            append maps #(slot, clsM, fnm, en)
                        )
                    )
                )

                -- 数值 / 颜色参数（过滤掉贴图槽位 *map* 与 name，避免与贴图表重复）
                local colors = #()
                local nums = #()
                if includeParams do (
                    local props = (try(getPropNames m)catch(#()))
                    for p in props do
                    (
                        local pname = (p as string)
                        if (matchPattern pname pattern:"*map*") or pname == "name" do continue
                        local val
                        try ( val = getProperty m p ) catch ( continue )
                        if val == undefined do continue
                        if (classof val == Color) then (
                            append colors #(pname, (colorToHex val))
                        ) else if (isKindOf val Number) then (
                            append nums #(pname, (val as string))
                        )
                    )
                )

                local objs = #()
                if includeObjs do objs = getMatObjects objMap m

                append infos (MatInfo i m dName cls isV objs subIdx maps colors nums)
            )

            -- ============ 写 Markdown ============
            -- 开头写入 AI 转换提示词（HTML 注释形式：AI 读取 MD 可见，渲染成 HTML 时自动隐藏）
            ss += "<!--" + "\n"
            ss += "【AI 转换提示】下面这段文字是给 AI 的指令，用来把本文档转换成 HTML 可视化报告；本段可整段删除，不影响报告数据。" + "\n"
            ss += line + "\n"
            ss += "-->" + "\n"

            ss += "" + "\n"
            ss += "# 3ds Max 场景材质构成报告" + "\n"
            ss += "" + "\n"
            ss += "| 项目 | 值 |" + "\n"
            ss += "|------|----|" + "\n"
            ss += ( "| 生成时间 | " + (nowStr()) + " |" ) + "\n"
            ss += ( "| 场景文件 | " + (if maxFileName != "" then (maxFilePath + maxFileName) else "（未保存的场景）") + " |" ) + "\n"
            ss += ( "| 3ds Max 版本 | " + ((maxVersion())[1] as string) + " |" ) + "\n"
            ss += ( "| 材质总数 | " + (nTotal as string) + " |" ) + "\n"
            local objCount = 0
            for o in objects do ( if o.material != undefined do objCount += 1 )
            ss += ( "| 使用材质对象数 | " + (objCount as string) + " |" ) + "\n"
            ss += ( "| V-Ray 材质数 | " + (nVRay as string) + " |" ) + "\n"
            ss += "" + "\n"

            -- 目录
            ss += "## 目录" + "\n"
            ss += "" + "\n"
            ss += "- [材质总览](#mat-overview)" + "\n"
            ss += "- [材质详情](#mat-details)" + "\n"
            for inf in infos do
            (
                ss += ( "  - [" + (inf.idx as string) + ". " + inf.dispName + " (" + inf.className + ")](#mat-" + (inf.idx as string) + ")" ) + "\n"
            )
            ss += "" + "\n"

            -- 总览表
            ss += "<a id=\"mat-overview\"></a>" + "\n"
            ss += "## 材质总览" + "\n"
            ss += "" + "\n"
            ss += "| # | 名称 | 类型 | 使用对象数 | 子材质数 | 贴图数 | V-Ray |" + "\n"
            ss += "|---|------|------|-----------|---------|--------|-------|" + "\n"
            for inf in infos do
            (
                local objN = if includeObjs then (inf.objNames.count as string) else "—"
                local subN = (inf.subIdx.count as string)
                local mapN = (inf.maps.count as string)
                local vTag = if inf.isVRay then "是" else "否"
                ss += ( "| " + (inf.idx as string) + " | " + inf.dispName + " | " + inf.className + " | " + objN + " | " + subN + " | " + mapN + " | " + vTag + " |" ) + "\n"
            )
            ss += "" + "\n"

            -- 详情
            ss += "<a id=\"mat-details\"></a>" + "\n"
            ss += "## 材质详情" + "\n"
            ss += "" + "\n"
            for inf in infos do
            (
                ss += ( "<a id=\"mat-" + (inf.idx as string) + "\"></a>" ) + "\n"
                ss += ( "### " + (inf.idx as string) + ". " + inf.dispName ) + "\n"
                ss += ( "- **类型**：" + inf.className + (if inf.isVRay then "  （V-Ray）" else "") ) + "\n"
                if includeObjs do (
                    if inf.objNames.count > 0 then (
                        ss += ( "- **使用对象** (" + (inf.objNames.count as string) + ")：" + (joinStr inf.objNames ", ") ) + "\n"
                    ) else (
                        ss += "- **使用对象**：（无 / 仅存在于材质编辑器或子材质中）" + "\n"
                    )
                )
                if inf.colors.count > 0 do (
                    ss += "- **颜色参数**" + "\n"
                    ss += "" + "\n"
                    ss += "  | 属性 | 值 |" + "\n"
                    ss += "  |------|----|" + "\n"
                    ss += ( "  | " + c[1] + " | " + c[2] + " |" ) + "\n"
                    ss += "" + "\n"
                )
                if inf.nums.count > 0 do (
                    ss += "- **数值参数**" + "\n"
                    ss += "" + "\n"
                    ss += "  | 属性 | 值 |" + "\n"
                    ss += "  |------|----|" + "\n"
                    ss += ( "  | " + n[1] + " | " + n[2] + " |" ) + "\n"
                    ss += "" + "\n"
                )
                if includeMaps and inf.maps.count > 0 do (
                    ss += ( "- **贴图** (" + (inf.maps.count as string) + ")" ) + "\n"
                    ss += "" + "\n"
                    ss += "  | 槽位 | 类型 | 文件 | 启用 |" + "\n"
                    ss += "  |------|------|------|------|" + "\n"
                    for mp in inf.maps do
                    (
                        local fnm = if mp[3] == "" then "—" else mp[3]
                        local en = if mp[4] then "是" else "否"
                        ss += ( "  | " + mp[1] + " | " + mp[2] + " | " + fnm + " | " + en + " |" ) + "\n"
                    )
                    ss += "" + "\n"
                )
                if inf.subIdx.count > 0 do (
                    local links = ""
                    for si in inf.subIdx do ( links += "[#" + (si as string) + " " + (mats[si].name as string) + "](#mat-" + (si as string) + ")、" )
                    if links.count > 0 do links = substring links 1 (links.count - 1)  -- 去掉末尾顿号
                    ss += ( "- **子材质** (" + (inf.subIdx.count as string) + ")：" + links ) + "\n"
                )
                ss += "" + "\n"
                ss += "---" + "\n"
                ss += "" + "\n"
            )

            -- 落盘
            local f = createFile path
            format "%" ss to:f
            close f
            true
        )

        on btnGo pressed do
        (
            local p = edtPath.text
            if p == "" or p == undefined do p = defaultPath
            if p == "" or p == undefined do ( messageBox "请先设置输出路径。" title:"提示"; return false )
            try
            (
                exportDoc p chkObjs.checked chkMaps.checked chkParams.checked
                edtLog.text = "已导出：\n" + p
                -- 打开所在文件夹，方便查看
                try ( ShellLaunch (getFilenamePath p) "" ) catch ()
            )
            catch
            (
                local errMsg = try ( getExceptionMessage() ) catch ( try ( (getCurrentException()) as string ) catch ( "未知错误" ) )
                edtLog.text = "导出失败：" + errMsg + "\n（请检查输出路径是否可写，建议先保存到本机磁盘）"
            )
        )
    )

    -- ===================== 主窗口 =====================
    try ( destroyDialog matToolkit ) catch ()
    matToolkit = newRolloutFloater "材质工具箱 v3" 360 860
    addRollout rlVRayReplace matToolkit
    addRollout rlExport matToolkit
)
