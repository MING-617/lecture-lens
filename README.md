# Lecture Lens

原生 macOS 英文实时字幕软件。用于线下听英文课：直接点击“开始”，看英文字幕；遇到已有词表中的专业词时，自动提示中文释义和课件出处。无需选择课程或章节。

当前版本：**0.4.0 / build 7**。英文识别使用 Nemotron English 0.6B 560ms int8 和 sherpa-onnx 1.13.8，全部在本机处理，无需 API key。Silero VAD 只用于收音状态提示，不裁掉识别音频。

## 使用

- “开始”启动，“停止”请求确认。回车默认继续听课；确认停止才关闭收音并保存。运行中关闭主窗口或退出也需要确认。
- 完整英文字幕自动保存到 `~/Documents/Lecture Lens 字幕/`，每次开始创建新文件。不保存音频录音。
- 画面最多保留最近 300 行；“字幕文件”定位完整文件，“导出字幕”另存本次全文。
- “回看”冻结画面，后台继续听；“回到实时”追赶最新字幕。字号可调整，“窗口置顶”方便同时看课件。
- `⌘R` 开始／请求停止，`⌘空格` 回看／回到实时。首次使用需手动允许麦克风权限。
- 输入中断、设备配置变化、系统睡眠或音频积压会停止并保留已收到的字幕。检查后手动重新开始。

## 从源码构建

要求 Apple Silicon Mac、macOS 26 或更新版本、Xcode Command Line Tools（Swift 编译器）及 Python 3.9 或更新版本。Python 仅用于构建工具，安装后的 app 不依赖 Python。

```sh
python3 Scripts/fetch-dependencies.py
./build.sh
# 安装到“应用程序”可使用：
./build.sh --install
```

首次恢复会从官方 GitHub 发布下载约数百 MB 的模型和原生运行库。版本、下载包 SHA-256 和文件 SHA-256 固定在 `Resources/StreamingEnglish/model-manifest.json` 与 `Vendor/SherpaOnnx/checksums.json`；每次下载与恢复都会校验。依赖及缓存不提交到 Git。第三方许可证保存在 `Resources/Licenses/`。

构建结果默认位于仓库上一级的 `Lecture Lens.zip`。可通过 `LECTURELENS_ARCHIVE` 指定其他 zip 路径。当前是本机临时签名的个人应用，未经过 Apple 公证；更新签名后 macOS 可能再次请求麦克风授权。

## 课程词表与资料路径

`Resources/coursepack.portable.json` 保留六门课程、321 个词条／英文写法和 1,076 条出处引用。词条数含缩写与同义写法，不等于不同概念数。中文是辅助释义，不能覆盖所有难词或未来尚未上传的课件，也不会自动同步 Moodle。

仓库只包含生成的术语和出处元数据，不包含 PDF、PPT、录音、课堂字幕、个人偏好或本机绝对路径。默认构建会把课件引用定位到当前用户的 `~/Desktop/Moodle课程资料/`。资料存放在其他位置时：

```sh
LECTURELENS_MOODLE_DIR='/path/to/Moodle课程资料' ./build.sh
```

原课件缺失时仍可显示字幕和术语；“打开课件”需要相应原文件。`Resources/coursepack.json` 是不提交的本机覆盖文件，存在时构建优先使用它。

## 验证与限制

```sh
./Scripts/test.sh
```

此命令检查术语匹配、延迟统计、会话停止和保存、旧回调隔离及输入积压保护。测试启用 Swift 断言，生成的文字留在被忽略的 `.cache/tests/`。

历史验证包括两小时实时节奏输入和实际扬声器到麦克风测试，见 [验证记录](docs/VALIDATION.md)。目标是持续跟上并控制在 2–3 秒以内；测得延迟基于模型词片时间戳估计，遗漏词不计入，未测量屏幕绘制。真实教室后排、回声、老师口音和多人讲话仍需现场检查，不能保证所有单词正确或每个词都在 3 秒内出现。
