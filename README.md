# Alacritty 0.17.0 / CentOS 7 单文件构建

本项目在 CentOS 7 容器中编译官方 Alacritty `v0.17.0`，然后将程序、普通
X11/字体动态库、Fontconfig 配置、DejaVu Sans Mono 和 terminfo 打包进一个
**外层完全静态**的 ELF 启动器。

```bash
./build-static-alacritty.sh
```

产物默认位于：

```text
build/static-alacritty/alacritty-onefile-0.17.0-x86_64
```

第一次运行时，启动器会校验内嵌 payload 的 SHA-256，并将它解压到
`$XDG_CACHE_HOME/alacritty/onefile`（未设置时使用用户缓存目录）。可通过
`ALACRITTY_ONEFILE_CACHE_DIR` 改变位置。

## 验证

```bash
file build/static-alacritty/alacritty-onefile-0.17.0-x86_64
ldd build/static-alacritty/alacritty-onefile-0.17.0-x86_64
readelf -lW build/static-alacritty/alacritty-onefile-0.17.0-x86_64 | grep INTERP
readelf -dW build/static-alacritty/alacritty-onefile-0.17.0-x86_64 | grep NEEDED
build/static-alacritty/alacritty-onefile-0.17.0-x86_64 --version
```

`file` 应显示 `statically linked`，两个 `readelf` 命令应无输出，版本必须为
`alacritty 0.17.0 (94e7c88)`。多数发行版的 `ldd` 会显示
`not a dynamic executable`；少数版本的 `ldd` 会尝试执行静态 Go ELF 并返回
非零状态，因此是否存在 `PT_INTERP`/`DT_NEEDED` 以 `readelf` 结果为准。

如果默认 CentOS Vault 在当前网络较慢，可指定镜像：

```bash
./build-static-alacritty.sh \
  --vault-url https://mirrors.aliyun.com/centos-vault/7.9.2009
```

## 必须说明的边界

Linux 版 Alacritty 0.17.0 不能做成“内部 Alacritty 本身完全静态、且无需任何
运行环境”的可用 GUI 程序。它的 `winit`/`x11-dl`/`xkbcommon-dl` 在启动时调用
`dlopen(3)` 加载 X11 和键盘库，`glutin` 同样动态加载 `libGL.so`/`libEGL.so`；
静态 musl 不支持这条加载路径。因此仅给 Cargo 加 `crt-static` 虽然可能让
`ldd` 看起来干净，实际启动会报无法加载 Xlib/EGL。

本构建没有伪装这个限制：

- 外层启动器是真静态 ELF，文件本身没有 `PT_INTERP` 或 `DT_NEEDED`；
- 内层 Alacritty 由 CentOS 7 构建，普通依赖和字体已随 payload 携带；
- 目标仍须是 Linux x86_64，提供 glibc 2.17+、X Server 和可工作的 OpenGL
  GLX/EGL 驱动；
- 构建仅启用 X11，不包含 Wayland，以匹配 CentOS 7 的典型桌面环境。

X Server 是窗口显示服务，OpenGL 用户态库必须与目标机器的显卡驱动匹配；将
构建机的 Mesa/NVIDIA 驱动硬塞进文件既不是真正的静态链接，也常常会让另一台
机器无法启动。若要求连这两项也不存在，Alacritty 作为 GPU 图形终端本身就不
满足需求，需要改用 framebuffer/纯文本程序，而不是改变链接参数。
