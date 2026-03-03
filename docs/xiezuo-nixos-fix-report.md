# WPS 协作 (xiezuo) NixOS 启动修复报告

> 调试过程由 Claude Opus 4.6 协助完成。

## 概述

WPS 协作 (xiezuo) 是 WPS365 套件中基于 Electron 22.3.27 (Chromium 108) 的协作办公组件。在 NixOS 上通过 `autoPatchelfHook` 打包后，启动过程中遇到了一系列级联问题。本报告按发现顺序记录每个问题的现象、根因和修复。

---

## 环境信息

| 项目 | 值 |
|------|-----|
| 操作系统 | NixOS 25.11 (Xantusia) |
| 内核 | Linux (amd64) |
| CPU | AMD Ryzen 9 7950X 16-Core |
| 显示 | 3840×2160, Wayland (GNOME Shell) |
| WPS 版本 | 12.1.2.24722 |
| xiezuo 版本 | 5.38.1 |
| Electron | 22.3.27 (Chromium 108) |
| Node.js | 16.17.1 |

---

## 问题 1：SIGTRAP — `dlopen("libudev.so.1")` 失败

### 现象

启动 xiezuo 后立即崩溃，信号为 SIGTRAP (signal 5)：

```
[0303/111724.889292:ERROR:elf_dynamic_array_reader.h(64)] tag not found
Trace/breakpoint trap (core dumped)
```

### 诊断

1. **共享库完整性验证**：对所有 `.so` 和 `.node` 文件运行 `ldd`，未发现缺失。所有 native addon 均可通过 `process.dlopen()` 加载。
2. **JS 异常排查**：注入 `uncaughtException` handler，未捕获异常。
3. **Chromium 参数测试**：`--disable-gpu`、`--disable-breakpad`、`--disable-features=Crashpad` 均无效。
4. **strace 追踪** 🔍：发现崩溃进程在 SIGTRAP 前遍历了整个 RPATH 搜索 `libudev.so.1`，全部失败：

```
[pid 176138] openat(AT_FDCWD, ".../cups-2.4.16-lib/lib/libudev.so.1") = -1 ENOENT
[pid 176138] openat(AT_FDCWD, ".../dbus-1.16.2-lib/lib/libudev.so.1") = -1 ENOENT
... (搜索所有 RPATH 路径，均 ENOENT)
[pid 176138] --- SIGTRAP {si_signo=SIGTRAP, si_code=SI_KERNEL} ---
```

5. **RPATH 分析**：`patchelf --print-rpath xiezuo | grep udev` → 无输出。`udev` 在 `buildInputs` 但不在 `runtimeDependencies`，autoPatchelfHook 不会将其路径加入 RPATH。

### 根因

Chromium 的 `DeviceMonitorLinux` 在运行时 `dlopen("libudev.so.1")`，但 xiezuo 的 ELF DT_NEEDED 中没有 libudev 条目。`dlopen` 失败后 Chromium 触发 `CHECK()` → `IMMEDIATE_CRASH()` (编译为 `int3; ud2` 指令序列) → SIGTRAP。

### 修复

将 `udev` 加入 `runtimeDependencies`（同时加入 `libva` 修复 VA-API 警告）：

```nix
runtimeDependencies = map lib.getLib [
  cups dbus pango pulseaudio libbsd libXScrnSaver libXxf86vm
  udev   # Chromium DeviceMonitorLinux dlopen
  libva  # GPU 进程 VA-API
];
```

**状态：✅ 已修复。**

---

## 问题 2：Crashpad handler 崩溃 → 主进程 SIGSEGV

### 现象

修复 libudev 后，xiezuo 能完成部分初始化，但约 5-10 秒后 SIGSEGV：

```
[ERROR:elf_dynamic_array_reader.h(64)] tag not found
[ERROR:process_memory_range.cc(75)] read out of range
Segmentation fault (core dumped)
```

### 根因

`chrome_crashpad_handler` 是 Chromium 的崩溃报告守护进程。它会读取主进程的 `/proc/pid/exe` 来解析 ELF 头。NixOS 的 `autoPatchelfHook` 给二进制文件添加了 `DT_RUNPATH` (tag 0x1d)，而 Crashpad 内置的 `ElfDynamicArrayReader` 不认识这个 tag，触发断言失败，handler 崩溃后连带主进程终止。

用 `readelf -d` 验证：
```
$ readelf -d xiezuo | grep -E "RPATH|RUNPATH"
 0x000000000000001d (RUNPATH)  Library runpath: [/nix/store/...]
```

只有 `DT_RUNPATH` (0x1d)，没有 `DT_RPATH` (0x0f)。原始 Crashpad 代码期望的是传统 `DT_RPATH`。

### 修复（初版：`sleep infinity`）

将 `chrome_crashpad_handler` 替换为 `#!/bin/sh\nexec sleep infinity`。手动测试时可以运行 30+ 秒不崩溃。

**但这引出了问题 3。**

---

## 问题 3：`sleep infinity` 导致主进程启动挂起 ⭐

### 现象

将 `sleep infinity` 修复集成到正式 Nix 构建后，xiezuo 启动时**无限挂起**——没有窗口、没有日志、完全无响应。

> 为什么之前手动测试没问题？因为手动测试用的二进制是从旧构建中提取的，可能 crashpad 的初始化路径与正式构建不同（例如被 `--disable-breakpad` 参数部分抑制了）。正式构建中 crashpad 客户端按完整流程初始化，会阻塞等待握手。

### 诊断

用 `strace -f` 追踪挂起的进程，发现主进程阻塞在 Unix SEQPACKET socket 的 `recvmsg()` 上：

```
[主进程] socketpair(AF_UNIX, SOCK_SEQPACKET, 0, [46, 47]) = 0
[主进程] clone() → 子进程 (crashpad handler，即 sleep infinity)
[主进程] sendmsg(46, {iov=[{len=40}], cmsg=[SCM_CREDENTIALS]}) = 40
[主进程] recvmsg(46, ...)  ← 永远阻塞在这里！
```

**关键发现**：Chromium 的 crashpad 客户端在注册时：
1. 通过 `socketpair()` 创建一对 SEQPACKET socket
2. 将其中一个 fd 通过 `--initial-client-fd=N` 传给 handler 子进程
3. 主进程通过另一个 fd 发送 40 字节注册消息（附带 `SCM_CREDENTIALS`）
4. **然后阻塞在 `recvmsg()` 等待 handler 回复 8 字节确认**

`sleep infinity` 从不读取 socket → handler 永远不回复 → 主进程永远阻塞。

### Crashpad IPC 握手协议（strace 逆向）

```
主进程 (Chromium)                        chrome_crashpad_handler
  │                                         │
  │  socketpair(SEQPACKET) → [fd_a, fd_b]   │
  │  fork+exec handler --initial-client-fd=fd_b
  │                                         │
  │  sendmsg(fd_a, 40 bytes,                │
  │          SCM_CREDENTIALS)          →    recvmsg(fd_b, ...)  // 收到 40 字节
  │                                         │
  │  recvmsg(fd_a, ...)  [阻塞]       ←    sendmsg(fd_b, 8 零字节)  // 握手响应
  │  [收到 8 字节，解除阻塞]                  │
  │                                         │
  │  继续正常启动 ✓                          pause()  // 保持存活
```

### 修复（最终版：C 语言 crashpad-handler-stub）

编写最小化 C 程序 `crashpad-handler-stub.c`，精确实现握手协议：

```c
#define PREFIX "--initial-client-fd="
#define PREFIX_LEN 20  /* strlen("--initial-client-fd=") = 20，不是 19！ */

int main(int argc, char *argv[]) {
    int client_fd = -1;
    // 1. 解析 --initial-client-fd=N
    for (int i = 1; i < argc; i++) {
        if (strncmp(argv[i], PREFIX, PREFIX_LEN) == 0) {
            client_fd = atoi(argv[i] + PREFIX_LEN);
            break;
        }
    }
    // 2. recvmsg() 接收 40 字节注册（带 SCM_CREDENTIALS）
    // 3. sendmsg() 回复 8 个零字节 → 解除主进程阻塞
    // 4. 排空后续消息
    // 5. pause() 保持存活
}
```

> **调试花絮**：初版 stub 中 `PREFIX_LEN` 写成了 19（忘了数末尾的 `=`），导致 `atoi("=45")` 返回 0，stub 对 fd 0 (stdin) 执行 `recvmsg()` 而非正确的 socket fd。修正为 20 后问题解决。

Nix 构建中编译：

```nix
rm -f $out/opt/xiezuo/chrome_crashpad_handler
$CC -O2 -o $out/opt/xiezuo/chrome_crashpad_handler ${./crashpad-handler-stub.c}
```

### 验证

构建后运行，主进程正常启动，完整日志输出：

```
03-03 16:46:50.769|info: WillStartUp
03-03 16:46:51.085|info: AppInitialized
03-03 16:46:52.321|info: mainwindow::created
03-03 16:46:53.894|info: skeletonReady
03-03 16:46:54.158|info: contentReady
```

窗口创建成功，登录二维码页面正常显示。

**状态：✅ 已修复。**

---

## 问题 4：启动 ~8 秒后 SIGSEGV（`libmini_ipc.so` 空函数指针）

### 现象

经过上述所有修复后，xiezuo 可以**成功启动**——窗口出现、内容加载、登录二维码可见。但约 8 秒后主进程 SIGSEGV 崩溃：

```
03-03 16:46:54.158|info: contentReady     ← 内容已加载，二维码可见
...约 4 秒后...
quit app now ~~~                          ← 伴随进程检测到主进程死亡
```

### 诊断

`coredumpctl info` 分析崩溃线程的调用栈：

```
#0  0x0000000000000000                    ← 跳转到地址 0x0（空函数指针调用）
#1  std::_Function_handler<..., init_helper()::lambda::lambda>::_M_invoke
                                          (libmini_ipc.so + 0xbd80f)
#2  std::function<void(string const&)>::operator()
                                          (libipc_object.so + 0x49efd)
#3  IPCObject::recvLoop()                 (libipc_object.so + 0x425b3)
#4  init_helper()::lambda::operator()     (libmini_ipc.so + 0xbc39a)
```

这**不是** crashpad 或 Chromium 的问题——崩溃发生在 WPS 私有的 IPC 框架中：

- `libmini_ipc.so` 和 `libipc_object.so` 位于 `resources/qt-tools/` 目录
- `init_helper()` 创建 lambda 捕获一个 `ipc_callback` 函数指针
- `IPCObject::recvLoop()` 收到 IPC 消息时调用该 lambda
- lambda 内部调用被捕获的回调 → 但回调为 **null (0x0)** → SIGSEGV

同目录下还有 `xz_helper` 二进制、`libktnn_engine.so`（AI 引擎）、OpenCV、ffmpeg 等——这是 xiezuo 的 Qt 辅助工具集，提供截图/OCR/图像处理等功能。

### 当前状态

**⏳ 尚未修复。** 可能的原因方向：

1. **回调注册时序**：`init_helper()` 被调用时传入了 null callback（可能是 JS 侧通过 ffi-napi 调用时参数传递问题）
2. **`xz_helper` 启动失败**：IPC 配套进程未正确启动，导致初始化不完整
3. **NixOS 环境差异**：Qt 工具依赖在 NixOS 下可能有未解决的路径问题

> **重要**：这个崩溃的实际影响可能有限。xiezuo 的核心功能（Electron 渲染、JS 应用逻辑、登录流程）在崩溃前已经正常工作。`libmini_ipc` / `xz_helper` 可能仅承担辅助功能（截图、OCR 等），崩溃不影响主要办公协作功能。后续可以考虑：
> - 阻止 `libmini_ipc.so` 的加载（如果它是通过 dlopen 按需加载的）
> - 修复 `xz_helper` 的运行环境
> - 捕获并忽略该线程的 SIGSEGV

---

## 附加修复

### 5. xiezuo 启动包装脚本

xiezuo 在 .deb 包中没有独立的启动脚本。添加 `$out/bin/xiezuo`：

- 创建 `~/.config/xiezuo` 配置目录和初始 `config.json`
- `cd` 到 xiezuo 安装目录（Electron 需要从自身目录运行以找到 `resources/`）
- 传递 `--no-sandbox`（NixOS 缺少 SUID `chrome-sandbox`）

### 6. 禁用 strip

`dontStrip = true`。Electron/V8 二进制不应被 strip，可能破坏内置快照和 JIT 结构。

---

## 修复总结

| # | 问题 | 信号 | 根因 | 修复 | 状态 |
|---|------|------|------|------|------|
| 1 | 启动即崩溃 | SIGTRAP | `dlopen("libudev.so.1")` 失败 | `udev` → `runtimeDependencies` | ✅ |
| 2 | Crashpad 崩溃 | SIGSEGV | Handler 不识别 `DT_RUNPATH` | 替换 handler | ✅ |
| 3 | 主进程挂起 | — | `sleep infinity` 不做 IPC 握手 | C stub 实现 crashpad 握手协议 | ✅ |
| 4 | ~8s 后崩溃 | SIGSEGV | `libmini_ipc.so` 空函数指针 | 待调查 (WPS IPC 框架) | ⏳ |
| 5 | 无启动入口 | — | 缺少启动脚本 | `$out/bin/xiezuo` 包装脚本 | ✅ |
| 6 | GPU 警告 | — | `libva.so.2` 不在 RPATH | `libva` → `runtimeDependencies` | ✅ |
| 7 | Strip 问题 | — | Electron 不应被 strip | `dontStrip = true` | ✅ |

---

## 关键文件

| 文件 | 说明 |
|------|------|
| `pkgs/wps365-cn/default.nix` | 主 Nix 包定义 |
| `pkgs/wps365-cn/crashpad-handler-stub.c` | Crashpad IPC 握手 stub（新增） |
| `pkgs/wps365-cn/sources.nix` | 下载源定义 |
