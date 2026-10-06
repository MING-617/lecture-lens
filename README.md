# Lecture Lens

原生 macOS 英文实时字幕软件。用于线下听英文课：直接点击“开始”，看英文字幕；遇到已有词表中的专业词时，自动提示中文释义和课件出处。无需选择课程或章节。

当前版本：**0.5.5 / build 13**。英文识别使用 Nemotron English 0.6B 560ms int8 和固定的 sherpa-onnx 源码提交 `3df7ada`，全部在本机处理，无需 API key。Silero VAD 只用于收音状态提示，不裁掉识别音频。

## 使用

- “开始”启动，“停止”请求确认。回车默认继续听课；确认停止才关闭收音并保存。运行中关闭主窗口或退出也需要确认。
- 完整英文字幕自动保存到 `~/Documents/Lecture Lens 字幕/`，每次开始创建新文件。不保存音频录音。上课时先写在本机不同步的 `~/Library/Application Support/LectureLens/Recording/`，点“停止”后整份移入字幕文件夹，避免 iCloud 在上课期间反复上传；若软件意外退出，下次打开或开始时自动移入并注明。
- 画面最多保留最近 300 行；“字幕文件”定位完整文件，“导出字幕”另存本次全文。
- “回看”冻结画面，后台继续听；“回到实时”追赶最新字幕。字号可调整，“窗口置顶”方便同时看课件。
- “悬浮字幕”切换为约 560×240 的小窗，显示最新英文和简短术语提示，自动置顶。顶部空白区域可拖动，边缘可缩放。“返回主界面”恢复之前的窗口尺寸和置顶设置，整个过程共用收音和字幕文件。
- “专业词增强”默认开启，自动使用六门课词表及自备英文词条，无需选课。开关在“术语表”中，停止后才能调整，下次开始生效。关闭中文或标记词条已掌握不会关闭英文识别增强。增强资源失败时显示提示并使用普通识别。
- `⌘R` 开始／请求停止，`⌘空格` 回看／回到实时。首次使用需手动允许麦克风权限。
- 输入中断、设备配置变化、系统睡眠或音频积压会停止并保留已收到的字幕。检查后手动重新开始。

## 从源码构建

要求 Apple Silicon Mac、macOS 26 或更新版本、Xcode Command Line Tools（Swift 编译器）及 Python 3.9 或更新版本。Python 仅用于构建工具，安装后的 app 不依赖 Python。

```sh
python3 Scripts/fetch-dependencies.py --cache "$HOME/Library/Caches/LectureLens/build-0.5.5"
./build.sh
# 安装到“应用程序”可使用：
./build.sh --install
```

首次恢复会下载约数百 MB 的模型，并在本机构建原生运行库。上面的版本缓存位于 Documents 同步目录之外，避免大量临时构建文件触发同步与索引；旧补丁缓存请改用新的缓存路径。上游源码固定为 [NeMo 热词支持提交](https://github.com/k2-fsa/sherpa-onnx/commit/3df7adacc0d5f140e4e81b746dac0fbeeac16fab)，模型、源码下载包和修订补丁的 SHA-256 固定在 `Resources/StreamingEnglish/model-manifest.json` 与 `Vendor/SherpaOnnx/checksums.json`。构建工具 CMake 固定为 3.31.6，仅安装在任务缓存；运行库使用上游锁定的 ONNX Runtime 1.28.2。

`Vendor/SherpaOnnx/bounded-revisions.patch` 在连续解码中约束较早词片的改写，修订窗口为 1.6 秒；模型不会按段重置，延迟读数也不会截断。这能避免很久之后反复改写，但已经固定的早期误听也可能保留。同一补丁会把已固定的词片移出识别路径，并提供只读取未固定部分的接口，因此课程再长，每一步的处理量也不变。增强默认使用两条路径、权重 0.5，配置在 `Resources/recognition-settings.json`。

0.5.2 在保留等待休眠和较慢音量指示刷新的基础上，让初始化和识别队列使用 background QoS，并防止调用方提高音频工作优先级。模型仍使用两个 CPU 线程，英文识别、专业词增强和完整保存继续工作；无需选择节能档位。串行测试的识别进程 CPU 能耗降低约 44–49%，准确率不变、未出现超过 3 秒的字幕延迟。这个结果不等于整机续航提升比例，CPU 百分比本身也可能更高。可选 `Resources/StreamingEnglish/cpu-runtime.conf` 缺失或损坏时，安全回退原 CPU 等待设置。

0.5.3 进一步让原生模型辅助线程请求 background QoS，在短暂积压时提高工作项优先级以追赶；字幕及延迟历史只更新改动的末尾。串行同输入对照的识别进程 CPU 能量进一步降低约 58–71%，独立真人及完整词表的最终英文与 0.5.2 一致。这是 CPU 能量，不能换算整机电池续航；两小时及交付检查见下方记录。

0.5.4 修正了课越长越费电的问题：0.5.3 每一步都会重新处理整节课的识别结果，连续 60 分钟后每步解码慢 52%，取结果慢约 20 倍；0.5.4 全程不变，最终英文完全相同。模型改用标准 MLAS 内核，常驻内存从约 1.4 GB 降到约 0.8 GB，CPU 能量和字幕不变。字幕持续变化时跳过仅用于状态提示的静音检测；音量、状态等界面更新合并为每秒约 4 次。

0.5.5 上课时把字幕写在本机不同步的文件夹，停止后再整份移入“文稿 / Lecture Lens 字幕”，所以 iCloud 只上传一次完成的文件，不再在上课期间每几秒上传一次。识别和字幕内容不变。

下载和恢复会检查源码／模型／补丁及头文件校验和；每个本地构建另存二进制校验收据。运行库的参考二进制哈希来自此设备，其他构建位置生成的 Mach-O 哈希可能不同。依赖及缓存不提交到 Git。第三方许可证保存在 `Resources/Licenses/`。

构建结果默认位于 `~/LectureLensLocal/installers/Lecture Lens.zip`，不放在可能同步到 iCloud 的“文稿”里。可通过 `LECTURELENS_ARCHIVE` 指定其他 zip 路径。当前是本机临时签名的个人应用，未经过 Apple 公证；更新签名后 macOS 可能再次请求麦克风授权。

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

此命令还以独立完整重建核对 1,200 次字幕修改和回退，并验证短暂工作中断后完整恢复输入。它检查术语匹配、首次及修订延迟、拆词／合词／增删词、保存和导出同步、会话停止、旧回调隔离、普通及增强输入积压保护，以及增强词表和可选 CPU 配置损坏时的降级。测试启用 Swift 断言，生成的文字留在被忽略的 `.cache/tests/`。

词汇对比测试使用自写句子和 macOS 合成语音，包含独立句子、全词表、普通词、15dB 噪声、长停顿和纯静音；音频和原始事件报告留在本地缓存：

```sh
python3 Scripts/validate-vocabulary.py
# 按真实语速走应用生产路径，例如：
'/Applications/Lecture Lens.app/Contents/MacOS/LectureLens' --benchmark \
  --input .cache/vocabulary-validation/holdout.wav --enhance \
  --report .cache/vocabulary-validation/paced-holdout.json
python3 Scripts/vocabulary-metrics.py Tests/Fixtures/caption-corpus/holdout.txt \
  .cache/vocabulary-validation/paced-holdout.json
```

快速参数测试的模拟时序不作为真实输入延迟的证明。对照文本检查遗漏和误词；正确拼写的延迟单独计算，不能用先出现的错误字幕替代。0.5.0 的验收记录见 [新版验证记录](docs/VALIDATION-0.5.md)。

0.5.4 的长课程开销与内存见 [验证记录](docs/VALIDATION-0.5.4.md)和[数值记录](docs/energy-results-0.5.4.json)。0.5.3 的原生线程、长字幕开销和两小时连续验证见 [验证记录](docs/VALIDATION-0.5.3.md)和[数值记录](docs/energy-results-0.5.3.json)。`Scripts/compare-helper-qos.py --help` 提供串行原生辅助线程对照；失败或字幕不同的组只保留原始数值，不计算节能比例。历史 0.5.2 的 CPU 能耗、准确率与延迟见 [调度验证](docs/VALIDATION-0.5.2.md)和[数值记录](docs/energy-results-0.5.2.json)。`--benchmark` 记录从模型就绪到完成释放的进程 CPU 用时、系统归因的 CPU 能量、性能核心时间占比，以及实际经过时间；旧报告仍可读取。`Scripts/compare-scheduling.py --help` 提供串行配置对照入口，原配置为 `baseline`，生产配置为 `two_background`；可重复指定顺序，例如 `--profiles baseline two_background two_background baseline`。`--threads`、`--qos` 和 `--provider` 只用于命令行诊断，不改变界面偏好；请求 Core ML 不代表实际 ANE 加速。CPU 能量不包含整机完整功耗，不能换算成电池续航提升比例。0.5.1 的等待休眠对照另见 [原记录](docs/VALIDATION-0.5.1.md)。

历史验证包括两小时实时节奏输入和实际扬声器到麦克风测试，见 [验证记录](docs/VALIDATION.md)。目标是持续跟上并控制在 2–3 秒以内；测得延迟基于模型词片时间戳估计，遗漏词不计入，未测量屏幕绘制。真实教室后排、回声、老师口音和多人讲话仍需现场检查，不能保证所有单词正确或每个词都在 3 秒内出现。
