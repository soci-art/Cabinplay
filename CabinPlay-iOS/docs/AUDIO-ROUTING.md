# 音频输出与路由（本次改动说明）

## 结论先说

- **CarLink 没有音频通道。** `oxp-clink` 的输出只送视频/触控/按键；中继那边也没有把声音塞进 CarLink。
  所以「音乐进车机」只能走**车机蓝牙（A2DP）**，或者等 CarLink 侧真的支持音频（协议层的事）。
- **音乐流 102 的短命是 iOS 侧行为**：建流 → 一个探路包 → 被拆。App 发认领也没放行。
  这一层不改协议拿不到音乐包；本次先把「拿到了也出不去」的那一半修掉。
- **上一版真正把音乐钉在手机扬声器上的，是路由策略本身**：只要路由里有 `carAudio` 口又没有 A2DP，
  代码就 `playAndRecord + defaultToSpeaker` 钉扬声器（为了避开 CarPlay 回路）。
  这个判断一旦成立，蓝牙连上也不会被重新评估——音乐永远出不了车机。

## 这次改了什么

1. **新增 `AudioOutputPolicy`**（`CabinPlay-iOS/CabinPlay/AudioOutputPolicy.swift`）
   - `automatic`（默认）：有 A2DP 就走蓝牙，没有才钉扬声器避回路；
   - `bluetooth`：只要 A2DP 在线绝不钉扬声器，不在线也如实写日志、不抢回扬声器；
   - `speaker`：始终钉扬声器（排查回路用）。
2. **音乐流不再被强制双工**（`LocalCarPlay/CarPlayAudio.swift`）
   - `needsDuplexCategory` 只看「麦克风流是否真的在跑」，不再被 `hasSpeakerOverride` 或
     「有 carAudio 没 A2DP」带进 `playAndRecord + defaultToSpeaker`。
   - 音乐一律 `.playback`，蓝牙才有候选资格。
3. **中断恢复**：新增 `interruptionNotification` 监听，来电/系统抢占结束后重新激活会话、
   重估路由并把输出接回去；旧实现被中断一次就整场静音。
4. **日志**：起播、路由变化、中断恢复都带当前路由、模式、A2DP 在线状态，方便一轮日志定性。
5. **设置页新增「声音」区**：三种模式 + 当前路由显示（`SettingsView.swift`）。

## 怎么测（一轮就能定性）

1. 系统蓝牙里先连上这台车（确认「媒体音频」是开的），**不要**先开 CarLink。
2. 启动本机 CarPlay，放歌 60 秒，看日志：
   - `音频输出路由：…（模式 automatic，A2DP 在线）` → 车机应该出声；
   - `音频输出路由：… A2DP 不在线` → 蓝牙没连上媒体音频，去系统蓝牙里补。
3. 再开 CarLink 出画，重复第 2 步：看路由会不会被 `carAudio` 抢回去。
4. 若出现回路/啸叫，把「声音输出」切到 `iPhone 扬声器`，确认是回路而不是解码问题。
5. 若日志里 102 流只有 1 个包就停（`音频流 102 接收实例已停，本实例累计收到 1 个包`），
   说明还是 iOS 拆流，这一轮只能听手机；需要按现状总结里的「选项 A」抓对照日志再决定改认领报文。

## 打电话 / 微信语音

- 通话流是 PCM 单声道 + 麦克风口，`microphone != nil`，所以仍然走
  `playAndRecord + defaultToSpeaker`：**声音和麦克风都在手机上**，车机屏只显示通话界面。
- 通话开始（`beginTelephony`）：把正在放的音乐暂停、清空队列，避免类别切换时
  A2DP 上的音乐来回跳；通话结束（`endTelephony`）：类别恢复成
  `.playback + allowBluetoothA2DP`，重估路由，再把音乐接回去。
- 音乐包在通话期间直接丢弃（已经过期，攒着只会在通话结束后砸一波）。
- 不支持把通话路由到车机免提：那需要 `.allowBluetoothHFP`（SCO 窄带），
  并且与 CarPlay 语音/媒体抢占，属于另一套取舍；CarLink 没有麦克风通道是根因。

## 没动的部分

- CarLink 视频/触控/按键链路；
- MFi 身份与配对；
- CarPlay 会话建立与占位画面；
- `oxp-clink` 与 Rust 核心（本次只改 iOS 侧音频路由）。
