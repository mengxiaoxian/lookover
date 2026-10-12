# 展示组件契约

业务桥接 → 对话窗口 → 可选 ConversationSkin。业务桥接不引用皮肤；PlainSkin 是完整可用的无皮肤基线。主题只提供展示数据，不能控制模型、任务、会话、子进程管道或凭据。

## 目录与字段

内置目录 `skins/<主题目录>/skin.json`，最多读取 20 个目录，重复 id 忽略。`none` 保留给默认界面。最小示例：

```json
{"id":"example","title":"示例","assistantName":"助手","background":"#FCF8F4","foreground":"#30292B","accent":"#A13C48","avatar":"avatar.png","launcher":"launcher.png","fontSize":14,"cornerRadius":22}
```

必填 id、background、foreground；颜色为 #RRGGBB。可选 title、assistantName、muted、accent、inputBackground、userBackground、avatar、launcher、fontSize、cornerRadius。字号限定 12–20，圆角 0–32；明暗控件外观由背景亮度推导。默认主题跟随系统动态颜色。

JSON 最大 32 KB，读取前检查大小。图片仅允许同主题目录内相对 PNG／JPEG 路径；拒绝绝对路径、.. 及符号链接越界。单图不超过 8 MB，以 ImageIO 缩略到最长边 512。非法或缺失图片使用默认图标；非法 JSON 跳过该主题，外部初始主题无效则回退默认，聊天仍可使用。

## 切换与边界

右上角外观菜单即时应用，更新消息展示与悬浮入口，不重建任务或会话，不清空草稿。NSUserDefaults 只记录所选主题 id；下次启动找不到该 id 时恢复默认。外部 skinPath 配置在助手启动时读取，需重新启用插件；配置未设置时恢复上次菜单选择。

默认入口 56×56；有 launcher 图片的角色入口 80×92。两种入口都使用相同点击恢复与窗口协调逻辑。发送、停止、新对话、会话选择、收起及主窗口切换属于基础界面，不能交给主题实现。

当前只支持静态角色图片和颜色排版，不执行脚本；动画、独立市场皮肤包发现／安装／升级、可变窗口布局仍待设计。随插件安装的主题目录属于插件包，不能依靠直接改已安装 node_modules 文件实现长期皮肤管理。
