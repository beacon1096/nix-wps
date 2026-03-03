-------------------------
note: Produced by Claude Opus 4.6. Impressive.

-------------------------
# WPS 协作 (xiezuo) NixOS 启动崩溃修复报告

## 概述

WPS 协作 (xiezuo) 是 WPS365 套件中基于 Electron 22.3.27 (Node 16.17.1) 的协作办公组件，版本 5.38.1。在 NixOS 上通过 `autoPatchelfHook` 打包后，`xiezuo` 可执行文件注册成功，但启动时立即崩溃。

本报告记录了完整的诊断过程、根因分析和修复措施。

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
| Electron | 22.3.27 |
| Node.js | 16.17.1 |
| V8 | 10.8.168.25-electron.0 |

---

## 崩溃现象

### 崩溃 1：SIGTRAP (Signal 5, Exit Code 133)

启动 xiezuo 后，应用在打印 `AppInitialized` 日志后立即崩溃，所有子进程 (GPU 进程、渲染进程、zygote 等) 均被 SIGTRAP 杀死：

```
03-03 11:17:24.832|info: AppInitialized
[0303/111724.889292:ERROR:elf_dynamic_array_reader.h(64)] tag not found
[0303/111724.902288:ERROR:elf_dynamic_array_reader.h(64)] tag not found
[0303/111724.903155:ERROR:process_memory_range.cc(75)] read out of range
Trace/breakpoint trap (core dumped)
```

`coredumpctl` 显示信号为 `SIGTRAP`，`si_code=SI_KERNEL`，`si_addr=NULL`。

---

## 诊断过程

### 1. 共享库完整性验证 ✅

对 xiezuo 目录下所有 `.so` 和 `.node` 文件运行 `ldd`，**未发现缺失的共享库**。所有 native addon（ksoframework、clipboard-files、ffi-napi、node-xlog、ref-napi、wns-addon、better-sqlite3、memory-optimizer、sharp、native-machine-id、bufferutil、utf-8-validate）均通过 `process.dlopen()` 测试加载成功。

### 2. JavaScript 异常排查 ✅

使用 `--require` 注入 `process.on('uncaughtException')` 预加载脚本，**未捕获任何 JS 异常**。`NODE_DEBUG=module` 追踪显示最后加载的模块为 `@ksxz/node-xlog`，之后进入原生代码执行。

### 3. Electron/Chromium 参数测试 ✅

以下参数均无法阻止崩溃：
- `--disable-gpu --disable-software-rasterizer --in-process-gpu`
- `--disable-breakpad --disable-crash-reporter`
- `--disable-features=Crashpad`
- `ELECTRON_ENABLE_LOGGING=1 --enable-logging --v=1`

### 4. strace 系统调用追踪 🔍 **关键发现**

使用 `strace -f` 追踪崩溃进程的系统调用，发现**崩溃进程 (renderer) 在收到 SIGTRAP 前最后的操作**是尝试 `dlopen("libudev.so.1")`：

```
[pid 176138] openat(AT_FDCWD, ".../cups-2.4.16-lib/lib/libudev.so.1", ...) = -1 ENOENT
[pid 176138] openat(AT_FDCWD, ".../dbus-1.16.2-lib/lib/libudev.so.1", ...) = -1 ENOENT
[pid 176138] openat(AT_FDCWD, ".../pango-1.57.0/lib/libudev.so.1", ...) = -1 ENOENT
... (搜索整个 RPATH，全部失败)
[pid 176138] openat(AT_FDCWD, ".../glibc-2.42-51/lib/libudev.so.0", ...) = -1 ENOENT
[pid 176138] --- SIGTRAP {si_signo=SIGTRAP, si_code=SI_KERNEL, si_addr=NULL} ---
[pid 176138] +++ killed by SIGTRAP (core dumped) +++
```

进程遍历了 RPATH 中所有路径，**均未找到 `libudev.so.1`**，随后触发 Chromium 的 `CHECK()` 断言失败 → `IMMEDIATE_CRASH()` (编译为 `int3; ud2` 指令序列)。

### 5. RPATH 分析

检查 xiezuo 二进制文件的 RPATH：

```
$ patchelf --print-rpath result/opt/xiezuo/xiezuo | tr ':' '\n' | grep udev
(无输出)
```

**`udev` 虽然在 `buildInputs` 中（供 autoPatchelfHook 解析 DT_NEEDED），但不在 `runtimeDependencies` 中，因此其 lib 路径未被加入 RPATH。** 而 Chromium 的设备枚举模块 (`DeviceMonitorLinux`) 是在运行时通过 `dlopen()` 加载 libudev 的，不是通过 ELF 的 DT_NEEDED 链接。

---

## 根因 1：`libudev.so.1` 运行时加载失败

### 原因

Chromium 内部的 `DeviceMonitorLinux` 组件在运行时调用 `dlopen("libudev.so.1")` 枚举输入设备。在 NixOS 上，`libudev.so.1` 由 `systemd-minimal-libs` 提供，路径为 `/nix/store/...-systemd-minimal-libs-.../lib/libudev.so.1`。

由于 `udev` 仅在 `buildInputs` 中（用于 autoPatchelfHook 解析已有的 DT_NEEDED 引用），而 xiezuo 二进制文件的 ELF 头中并没有 `libudev.so.1` 的 DT_NEEDED 条目，autoPatchelfHook 不会将 udev 的路径加入 RPATH。

当 Chromium 尝试 `dlopen("libudev.so.1")` 时，动态链接器在 RPATH 中的所有路径里都找不到该库。随后 Chromium 触发 `CHECK()` 断言（release build 中编译为 `int3` 指令），进程收到 `SIGTRAP` 信号终止。

### 修复

将 `udev` 添加到 `runtimeDependencies`。`runtimeDependencies` 机制会通过 `patchelf --add-rpath` 将 udev 的 lib 路径加入二进制文件的 RPATH，使 `dlopen()` 能找到 `libudev.so.1`。

同时添加 `libva`，修复 GPU 进程初始化时 `dlopen(libva.so.2) failed` 的警告。

```nix
runtimeDependencies = map lib.getLib [
  cups dbus pango pulseaudio libbsd libXScrnSaver libXxf86vm
  udev   # 新增：Chromium DeviceMonitorLinux dlopen
  libva  # 新增：GPU 进程 VA-API 支持
];
```

---

## 根因 2：`chrome_crashpad_handler` 导致进程崩溃

### 现象

修复 libudev 问题后，xiezuo 能正常完成初始化（创建窗口、启动 helper、注册事件），但约 5-10 秒后仍然崩溃，信号变为 **SIGSEGV (Signal 11)**：

```
[0303/112301.543060:ERROR:elf_dynamic_array_reader.h(64)] tag not found
[0303/112301.543357:ERROR:elf_dynamic_array_reader.h(64)] tag not found
[0303/112301.544334:ERROR:process_memory_range.cc(75)] read out of range
Segmentation fault (core dumped)
```

`coredumpctl` 显示崩溃发生在 V8 引擎的字节码编译器中：

```
#0  v8::internal::interpreter::BytecodeArrayWriter::Write(BytecodeNode*)
#1  v8::internal::interpreter::BytecodeArrayBuilder::PushContext(Register)
```

### 原因

Chromium 的 Crashpad 崩溃报告处理程序 (`chrome_crashpad_handler`) 在启动时会 `ptrace` 主进程并读取其 ELF 头信息。在 NixOS 上，autoPatchelfHook 修改了 ELF 二进制的动态段（interpreter 指向 nix store 中的 glibc，RPATH 包含大量 nix store 路径），这导致 Crashpad 的 `ElfDynamicArrayReader` 无法正确解析 ELF 头：

```
elf_dynamic_array_reader.h(64): tag not found
process_memory_range.cc(75): read out of range
scoped_ptrace_attach.cc: ptrace: Operation not permitted
```

Crashpad handler 在解析失败后崩溃，通过信号机制导致主进程也被终止。

### 验证

将 `chrome_crashpad_handler` 替换为一个空操作的 shell 脚本后，xiezuo 进程可以稳定运行超过 20 秒不崩溃：

```bash
# 替换后
$ cat chrome_crashpad_handler
#!/bin/sh
exec sleep infinity

# 进程稳定运行
$ ps aux | grep xiezuo
beacon  188644  1.4  0.1 ... /tmp/xiezuo_test/xiezuo --no-sandbox  # 运行 30+ 秒
```

### 修复

在 `installPhase` 中将 `chrome_crashpad_handler` 替换为无操作脚本：

```nix
rm -f $out/opt/xiezuo/chrome_crashpad_handler
cat > $out/opt/xiezuo/chrome_crashpad_handler <<'CRASHPAD_EOF'
#!/bin/sh
exec sleep infinity
CRASHPAD_EOF
chmod +x $out/opt/xiezuo/chrome_crashpad_handler
```

---

## 附加修复

### 3. xiezuo 启动包装脚本

xiezuo 在 .deb 包中没有独立的启动脚本。添加 `$out/bin/xiezuo` 包装脚本：

- 创建 `~/.config/xiezuo` 配置目录和初始 `config.json`
- `cd` 到 xiezuo 安装目录（Electron 需要从自身所在目录运行以找到 `resources/`）
- 传递 `--no-sandbox` 参数（NixOS 不支持 Chromium 沙盒，缺少 SUID `chrome-sandbox`）

### 4. 禁用 strip

将 `stripAllList = [ "opt" ]` 改为 `dontStrip = true`。Electron 和 V8 的二进制文件不应被 strip，否则可能破坏内置的快照数据和 JIT 相关结构。

---

## 完整 diff

```diff
diff --git a/pkgs/wps365-cn/default.nix b/pkgs/wps365-cn/default.nix
index fd01657..3af18cd 100644
--- a/pkgs/wps365-cn/default.nix
+++ b/pkgs/wps365-cn/default.nix
@@ -30,6 +30,7 @@
   libbsd,
   libXScrnSaver,
   libXxf86vm,
+  libva,
 }:

@@ -96,7 +97,7 @@ stdenv.mkDerivation {
   dontWrapQtApps = true;

-  stripAllList = [ "opt" ];
+  dontStrip = true;

   runtimeDependencies = map lib.getLib [
     cups
@@ -106,6 +107,8 @@ stdenv.mkDerivation {
     libbsd
     libXScrnSaver
     libXxf86vm
+    udev
+    libva
   ];

@@ -130,6 +133,16 @@ stdenv.mkDerivation {
     cp -r opt $out
     cp -r usr/{bin,share} $out

+    # Replace chrome_crashpad_handler with a no-op script.
+    rm -f $out/opt/xiezuo/chrome_crashpad_handler
+    cat > $out/opt/xiezuo/chrome_crashpad_handler <<'CRASHPAD_EOF'
+    #!/bin/sh
+    exec sleep infinity
+    CRASHPAD_EOF
+    chmod +x $out/opt/xiezuo/chrome_crashpad_handler

@@ -140,6 +153,22 @@ stdenv.mkDerivation {
         --replace /usr/bin $out/bin
     done

+    mkdir -p $out/bin
+    cat > $out/bin/xiezuo <<'EOF'
+    #!${stdenv.shell}
+    set -euo pipefail
+    config_dir="''${XDG_CONFIG_HOME:-$HOME/.config}/xiezuo"
+    config_file="$config_dir/config.json"
+    mkdir -p "$config_dir"
+    if [ ! -f "$config_file" ]; then
+      echo '{}' > "$config_file"
+    fi
+    cd "@out@/opt/xiezuo"
+    exec "@out@/opt/xiezuo/xiezuo" --no-sandbox "$@"
+    EOF
+    substituteInPlace $out/bin/xiezuo --replace "@out@" "$out"
+    chmod +x $out/bin/xiezuo
```

---

## 修复总结

| # | 问题 | 信号 | 根因 | 修复 |
|---|------|------|------|------|
| 1 | 启动即崩溃 | SIGTRAP | `dlopen("libudev.so.1")` 失败，Chromium `CHECK()` 触发 `int3` | `udev` 加入 `runtimeDependencies` |
| 2 | 初始化后崩溃 | SIGSEGV | Crashpad handler 无法解析 NixOS 修改过的 ELF 头 | 替换 `chrome_crashpad_handler` 为 no-op |
| 3 | 无启动入口 | — | .deb 包无 xiezuo 启动脚本 | 添加 `$out/bin/xiezuo` 包装脚本 |
| 4 | GPU 警告 | — | `libva.so.2` 不在 RPATH 中 | `libva` 加入 `runtimeDependencies` |
| 5 | 潜在 strip 问题 | — | Electron 二进制不应被 strip | `dontStrip = true` |
