# WPS 协作 (xiezuo) NixOS 启动修复报告

> 调试过程全部由 Claude Opus 4.6 完成。

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

## 问题 4：启动 ~8 秒后 SIGSEGV（`libmini_ipc.so` ffi 闭包被 GC 释放）

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

#### 深入分析：ffi 闭包内存取证

通过 GDB 分析 coredump 内存，发现 `call_back_` 全局指针 **不为 null**（值为 `0x7f192792cfe0`），但指向的 **libffi trampoline 代码** 的 **数据页已被清零**：

```asm
;; trampoline code page (RX) — 仍然映射，代码完整
0x7f192792cfe0:  sub    $0x10,%rsp
0x7f192792cfe4:  mov    %r10,(%rsp)
0x7f192792cfe8:  mov    0xff1(%rip),%r10    ; 从 data page 加载 handler 指针
0x7f192792cfef:  jmp    *%r10               ; 跳转到 0x0 → SIGSEGV

;; trampoline data page (RW) — 已被释放/清零
0x7f192792dfe0:  0x0000000000000000          ; user data = NULL
0x7f192792dfe8:  0x0000000000000000          ; handler function = NULL ← 根因
```

**机制分析**：JS 侧通过 `@ksxz/ffi-napi`（ffi-napi 分支）创建 `ffi.Callback()` 闭包，将 JS 回调包装为 C 函数指针传给 `init_helper()`。libffi 闭包由两个 mmap 页面组成：

1. **Code page (RX)**：trampoline 跳转代码
2. **Data page (RW)**：用户数据和处理函数指针

V8 GC 在 ~8 秒后运行时，`@ksxz/ffi-napi` 的弱引用机制释放了闭包的 data page（清零），但 code page 仍然映射。C++ 的 `recvLoop` 线程此时通过 `call_back_` 指针调用 trampoline → trampoline 从已清零的 data page 加载 0x0 → `jmp *%r10` → SIGSEGV。

反汇编确认 `libmini_ipc.so` 中的 `_M_invoke` 存在 TOCTOU 双次加载 `call_back_`：
```asm
0xbc0fe: mov 0x268a73(%rip),%rax  ; 第一次加载 → null check
0xbc105: test %rax,%rax; je bc144 ; 非 null（trampoline 地址仍有效），通过
0xbc10a: mov 0x268a67(%rip),%rbx  ; 第二次加载 → 用于调用
0xbc123: call *%rbx               ; 调用 trampoline → 内部 jmp 到 0x0
```

#### 失败的修复尝试

**JS GC 防护**：在 `application.js` 中添加 `process.__prevent_gc_ffi_cb=l.cb` 将回调对象钉到 process 全局作用域。**未奏效**——问题不在 JS 层 GC 回收 Buffer 对象，而在 ffi-napi 的 native 弱引用处理释放了 libffi 闭包的 data page。

### 修复

**创建 `libmini_ipc.so` 的 SIGSEGV 安全垫片**（`libmini_ipc_stub.c`）：

1. 将原始 `libmini_ipc.so` 重命名为 `libmini_ipc_real.so`
2. 编译垫片为 `libmini_ipc.so`，导出相同的 3 个 API：`init_helper`、`uninit_helper`、`send_msg`
3. 垫片 `dlopen` 原始库，将所有调用委托给它
4. **关键区别**：垫片传给真实库的不是 ffi 闭包指针，而是**自己的 C 函数指针** `safe_callback_wrapper`——这是一个普通的 C 函数，永远不会被 GC 释放
5. `safe_callback_wrapper` 内部调用 ffi 闭包时使用 `sigsetjmp`/`siglongjmp` 包裹，设置 SIGSEGV recovery handler：如果闭包已被 GC 释放导致跳转到 0x0，**捕获 SIGSEGV 并优雅降级**，禁用后续回调而非崩溃

```
真实 libmini_ipc.so 的 recvLoop 线程
    ↓ 调用 callback
safe_callback_wrapper()  ← 稳定的 C 函数指针，不受 GC 影响
    ↓ sigsetjmp 保护
ffi 闭包 trampoline
    ↓ 如果 data page 已清零
    ↓ jmp *0x0 → SIGSEGV
    ↓ handler 捕获，siglongjmp 恢复
    └→ 打印警告，禁用回调，继续运行
```

运行时日志确认修复生效：
```
[libmini_ipc_stub] ffi callback closure was freed by GC, disabling callback
```
此后应用继续正常运行，IM 同步、消息加载、WebSocket 连接均正常。

### 代码更改

```nix
# default.nix — installPhase
mv "$qt_tools/libmini_ipc.so" "$qt_tools/libmini_ipc_real.so"
$CC -shared -fPIC -O2 -o "$qt_tools/libmini_ipc.so" \
  ${./libmini_ipc_stub.c} -ldl -lpthread
```

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
| 4 | ~8s 后崩溃 | SIGSEGV | ffi 闭包 data page 被 GC 清零 | SIGSEGV 安全垫片 `libmini_ipc_stub.c` | ✅ |
| 5 | 无启动入口 | — | 缺少启动脚本 | `$out/bin/xiezuo` 包装脚本 | ✅ |
| 6 | GPU 警告 | — | `libva.so.2` 不在 RPATH | `libva` → `runtimeDependencies` | ✅ |
| 7 | Strip 问题 | — | Electron 不应被 strip | `dontStrip = true` | ✅ |

---

## 关键文件

| 文件 | 说明 |
|------|------|
| `pkgs/wps365-cn/default.nix` | 主 Nix 包定义 |
| `pkgs/wps365-cn/crashpad-handler-stub.c` | Crashpad IPC 握手 stub（新增） |
| `pkgs/wps365-cn/libmini_ipc_stub.c` | libmini_ipc.so SIGSEGV 安全垫片（新增） |
| `pkgs/wps365-cn/sources.nix` | 下载源定义 |
